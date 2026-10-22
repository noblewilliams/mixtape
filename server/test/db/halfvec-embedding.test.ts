import { describe, it, expect } from 'vitest'
import { PGlite } from '@electric-sql/pglite'
import { vector } from '@electric-sql/pglite-pgvector'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { sql } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { tracks, trackMeanings } from '../../src/db/schema'

// Migration 0043 (spec 2026-10-21 everyone-gets-a-mix, step 3 storage,
// decision 3): track_meanings.embedding vector(1024) -> halfvec(1024), HNSW
// index rebuilt on halfvec_cosine_ops, existing rows cast in place.
const DRIZZLE_DIR = fileURLToPath(new URL('../../drizzle', import.meta.url))
const MIGRATION_TAG = '0043_halfvec_embeddings'
const DIMS = 1024
const ROWS = 200

type Journal = { entries: Array<{ idx: number; tag: string }> }

async function statementsOf(tag: string): Promise<string[]> {
  return (await readFile(`${DRIZZLE_DIR}/${tag}.sql`, 'utf8'))
    .split('--> statement-breakpoint')
    .map((s) => s.trim())
    .filter((s) => s !== '')
}

// A database migrated through 0042 only, so 0043 can run against real rows.
async function dbBefore0043(): Promise<PGlite> {
  const journal = JSON.parse(await readFile(`${DRIZZLE_DIR}/meta/_journal.json`, 'utf8')) as Journal
  const db = new PGlite({ extensions: { vector } })
  for (const entry of journal.entries.filter((e) => e.idx < 43)) {
    for (const statement of await statementsOf(entry.tag)) await db.exec(statement)
  }
  return db
}

// Deterministic PRNG (mulberry32) so the random embeddings are the same run to run.
function rng(seed: number) {
  let a = seed
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomEmbedding(next: () => number): number[] {
  return Array.from({ length: DIMS }, () => next() * 2 - 1)
}

const literal = (v: number[]) => `[${v.join(',')}]`

async function sizes(db: PGlite) {
  const { rows } = await db.query<{ total: number; index: number }>(`
    SELECT pg_total_relation_size('track_meanings')::int AS total,
           pg_relation_size('track_meanings_embedding_hnsw_idx')::int AS index`)
  return rows[0]
}

async function nearest(db: PGlite, query: number[], cast: string): Promise<string[]> {
  // Exact order (no index), so this compares the cast, not two HNSW builds.
  await db.exec('SET enable_indexscan = off')
  const { rows } = await db.query<{ track_id: string }>(
    `SELECT track_id FROM track_meanings ORDER BY embedding <=> $1::${cast}, track_id LIMIT 10`,
    [literal(query)],
  )
  await db.exec('RESET enable_indexscan')
  return rows.map((r) => r.track_id)
}

describe('migration 0043: halfvec embeddings', () => {
  it('casts existing rows, rebuilds the index, keeps nearest-neighbour order and about halves the bytes', async () => {
    const db = await dbBefore0043()
    try {
      const next = rng(43)
      // One multi-row INSERT per table: 200 round trips would blow the time budget.
      const { rows: trackRows } = await db.query<{ id: string }>(
        `INSERT INTO tracks (title, artist) SELECT 'Song ' || i, 'Artist' FROM generate_series(1, $1::int) i RETURNING id`,
        [ROWS])
      const embeddings = trackRows.map(() => literal(randomEmbedding(next)))
      await db.query(
        `INSERT INTO track_meanings (track_id, embedding, lyrics_source)
         SELECT id, e::vector, 'lrclib' FROM unnest($1::uuid[], $2::text[]) AS u(id, e)`,
        [trackRows.map((r) => r.id), embeddings])
      const query = randomEmbedding(next)
      const before = await sizes(db)
      const orderBefore = await nearest(db, query, 'vector')

      for (const statement of await statementsOf(MIGRATION_TAG)) await db.exec(statement)

      const after = await sizes(db)
      const orderAfter = await nearest(db, query, 'halfvec(1024)')
      console.log(
        `track_meanings, ${ROWS} rows of ${DIMS}-dim embeddings: ` +
        `vector ${before.total} bytes (hnsw index ${before.index}), ` +
        `halfvec ${after.total} bytes (hnsw index ${after.index}), ratio ${(after.total / before.total).toFixed(3)}`,
      )

      const { rows: [col] } = await db.query<{ type: string }>(`
        SELECT format_type(atttypid, atttypmod) AS type FROM pg_attribute
        WHERE attrelid = 'track_meanings'::regclass AND attname = 'embedding'`)
      expect(col.type).toBe('halfvec(1024)')
      const { rows: [idx] } = await db.query<{ def: string }>(
        `SELECT indexdef AS def FROM pg_indexes WHERE indexname = 'track_meanings_embedding_hnsw_idx'`)
      expect(idx.def).toMatch(/USING hnsw \(embedding halfvec_cosine_ops\)/)
      expect((await db.query(`SELECT 1 FROM track_meanings WHERE embedding IS NOT NULL`)).rows).toHaveLength(ROWS)

      expect(orderAfter).toEqual(orderBefore)
      expect(after.total).toBeLessThan(before.total * 0.65)
    } finally {
      await db.close()
    }
  }, 120_000) // replays 42 migrations on a fresh pglite

  it('sets a lock timeout, drops the index before the cast and recreates it after, in one migration', async () => {
    const statements = await statementsOf(MIGRATION_TAG)
    expect(statements).toHaveLength(4)
    // Fail fast behind a running pool query (retry later) rather than queue every read behind the DROP.
    expect(statements[0]).toMatch(/^SET LOCAL lock_timeout = '5s';?$/)
    expect(statements[1]).toMatch(/^DROP INDEX "track_meanings_embedding_hnsw_idx";?$/)
    expect(statements[2]).toMatch(
      /^ALTER TABLE "track_meanings" ALTER COLUMN "embedding" (SET DATA )?TYPE halfvec\(1024\) USING "?embedding"?::halfvec\(1024\);?$/)
    expect(statements[3]).toMatch(
      /^CREATE INDEX "track_meanings_embedding_hnsw_idx" ON "track_meanings" USING hnsw \("embedding" halfvec_cosine_ops\);?$/)
  })

  it('round-trips a drizzle insert and select through the halfvec column', async () => {
    const db = await createTestDb()
    const [t] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    const embedding = Array.from({ length: DIMS }, (_, i) => (i % 4) * 0.25 - 0.5) // fp16-exact values
    await db.insert(trackMeanings).values({ trackId: t.id, embedding, lyricsSource: 'lrclib' })
    const [row] = await db.select().from(trackMeanings)
    expect(row.embedding).toEqual(embedding)
    const res = await db.execute(sql`SELECT vector_dims(embedding) AS dims FROM track_meanings`)
    expect((res as unknown as { rows: Array<{ dims: number }> }).rows[0].dims).toBe(DIMS)
  })
})
