import { describe, it, expect } from 'vitest'
import { eq, sql } from 'drizzle-orm'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createTestDb } from '../helpers/db'
import { djSessions, mixShares, mixShareSaves, user } from '../../src/db/schema'

const MIGRATION = fileURLToPath(new URL('../../drizzle/0050_mix_shares.sql', import.meta.url))
const JOURNAL = fileURLToPath(new URL('../../drizzle/meta/_journal.json', import.meta.url))
const SNAPSHOT = (n: string) => fileURLToPath(new URL(`../../drizzle/meta/${n}_snapshot.json`, import.meta.url))

async function insertUser(db: Awaited<ReturnType<typeof createTestDb>>, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

// Sharer u1 shares a mix; u2 saves it.
async function seed() {
  const db = await createTestDb()
  await insertUser(db, 'u1')
  await insertUser(db, 'u2')
  const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 'rainy drive' }).returning()
  const [share] = await db
    .insert(mixShares)
    .values({
      token: 'AbCdEfGhIjKlMnOpQrStUv',
      sessionId: session.id,
      sharerId: 'u1',
      queueVersion: 1,
      title: 'rainy drive',
      caseColor: 'teal',
      entries: [{ position: 0, trackId: '00000000-0000-0000-0000-000000000001' }],
    })
    .returning()
  await db.insert(mixShareSaves).values({ userId: 'u2', shareId: share.id })
  return { db, session, share }
}

// Migration 0050: shared mixes (spec 2026-11-13 shared-mixes, "Data").
describe('migration 0050 mix shares', () => {
  it('fills defaults: id, created_at, saved_at; revoked_at starts null', async () => {
    const { db, share } = await seed()
    expect(share.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(share.createdAt).toBeInstanceOf(Date)
    expect(share.revokedAt).toBeNull()
    const [save] = await db.select().from(mixShareSaves)
    expect(save.savedAt).toBeInstanceOf(Date)
  })

  it('deleting a dj_session removes its shares and their saves', async () => {
    const { db, session } = await seed()
    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    expect(await db.select().from(mixShares)).toHaveLength(0)
    expect(await db.select().from(mixShareSaves)).toHaveLength(0)
  })

  it('deleting the saver removes their saves but keeps the share', async () => {
    const { db } = await seed()
    await db.delete(user).where(eq(user.id, 'u2'))
    expect(await db.select().from(mixShareSaves)).toHaveLength(0)
    expect(await db.select().from(mixShares)).toHaveLength(1)
  })

  it('deleting the sharer removes their shares and the saves of them', async () => {
    const { db } = await seed()
    await db.delete(user).where(eq(user.id, 'u1'))
    expect(await db.select().from(mixShares)).toHaveLength(0)
    expect(await db.select().from(mixShareSaves)).toHaveLength(0)
  })

  it('rejects a duplicate token', async () => {
    const { db, session } = await seed()
    const err = await db
      .insert(mixShares)
      .values({ token: 'AbCdEfGhIjKlMnOpQrStUv', sessionId: session.id, sharerId: 'u1', queueVersion: 2, title: 't', caseColor: 'teal', entries: [] })
      .then(() => undefined, (e: unknown) => e as { cause?: { code?: string }; code?: string })
    expect(err?.cause?.code ?? err?.code).toBe('23505')
  })

  it('a user saves a share once', async () => {
    const { db, share } = await seed()
    const err = await db
      .insert(mixShareSaves)
      .values({ userId: 'u2', shareId: share.id })
      .then(() => undefined, (e: unknown) => e as { cause?: { code?: string }; code?: string })
    expect(err?.cause?.code ?? err?.code).toBe('23505')
  })

  it('rejects entries that are not an array', async () => {
    const { db, session } = await seed()
    const err = await db
      .execute(sql`INSERT INTO mix_shares (token, session_id, sharer_id, queue_version, title, case_color, entries)
        VALUES ('ZZZZZZZZZZZZZZZZZZZZZZ', ${session.id}, 'u1', 1, 't', 'teal', '{}'::jsonb)`)
      .then(() => undefined, (e: unknown) => e as { cause?: { constraint?: string }; constraint?: string })
    expect(err?.cause?.constraint ?? err?.constraint).toBe('mix_shares_entries_array')
  })

  it('has the partial index on (session_id, queue_version) for active shares', async () => {
    const { db } = await seed()
    const { rows } = await db.execute<{ indexdef: string }>(sql`
      SELECT indexdef FROM pg_indexes WHERE tablename = 'mix_shares' AND indexname = 'mix_shares_session_version_active_idx'
    `)
    expect(rows).toHaveLength(1)
    expect(rows[0].indexdef).toMatch(/\(session_id, queue_version\) WHERE \(revoked_at IS NULL\)/)
  })

  it('the migration only creates the two tables, their keys and indexes', async () => {
    const statements = (await readFile(MIGRATION, 'utf8'))
      .split('--> statement-breakpoint')
      .map((s) => s.trim())
      .filter((s) => s !== '')
    for (const s of statements) {
      expect(s).toMatch(
        /^(CREATE TABLE "(mix_shares|mix_share_saves)"|ALTER TABLE "(mix_shares|mix_share_saves)" ADD CONSTRAINT|CREATE (UNIQUE )?INDEX "mix_shares_)/,
      )
    }
    expect(statements.filter((s) => s.startsWith('CREATE TABLE'))).toHaveLength(2)
  })

  it('is journalled right after 0049, with a chained snapshot', async () => {
    const journal = JSON.parse(await readFile(JOURNAL, 'utf8')) as { entries: { idx: number; tag: string }[] }
    const at = journal.entries.findIndex((e) => e.idx === 50)
    expect(journal.entries[at]?.tag).toBe('0050_mix_shares')
    expect(journal.entries[at - 1]?.idx).toBe(49)
    const prev = JSON.parse(await readFile(SNAPSHOT('0049'), 'utf8')) as { id: string }
    const next = JSON.parse(await readFile(SNAPSHOT('0050'), 'utf8')) as { prevId: string; tables: Record<string, unknown> }
    expect(next.prevId).toBe(prev.id)
    expect(Object.keys(next.tables)).toEqual(expect.arrayContaining(['public.mix_shares', 'public.mix_share_saves']))
  })
})
