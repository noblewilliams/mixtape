import { describe, it, expect } from 'vitest'
import { eq, sql } from 'drizzle-orm'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createTestDb } from '../helpers/db'
import { djSessions, funnelEvents, user } from '../../src/db/schema'

const MIGRATION = fileURLToPath(new URL('../../drizzle/0048_music_nudges.sql', import.meta.url))
const JOURNAL = fileURLToPath(new URL('../../drizzle/meta/_journal.json', import.meta.url))
const SNAPSHOT = (n: string) => fileURLToPath(new URL(`../../drizzle/meta/${n}_snapshot.json`, import.meta.url))

const NEW_TYPES = [
  'music_door_tapped',
  'music_chip_tapped',
  'music_added_from_mix',
  'remake_tapped',
  'music_chip_offered',
  'remake_made',
] as const

async function dbWithUser() {
  const db = await createTestDb()
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  return db
}

// Migration 0048: funnel_events.type admits the add-your-music loop's types,
// and dj_sessions gains music_chip_at, the once-per-conversation guard for the
// "Add my listening history" pill (spec 2026-11-09 add-your-music-loop,
// decision 5).
describe('migration 0048 music nudges', () => {
  it('funnel_events.type accepts each new type next to the existing ones', async () => {
    const db = await dbWithUser()
    for (const type of NEW_TYPES) {
      await db.insert(funnelEvents).values({ userId: 'u1', type, surface: 'ios' })
    }
    await db.insert(funnelEvents).values({ userId: 'u1', type: 'proposed_mix', surface: 'web' })
    expect(await db.select().from(funnelEvents)).toHaveLength(NEW_TYPES.length + 1)
  })

  it('funnel_events.type still rejects an unknown type', async () => {
    const db = await dbWithUser()
    const err = await db
      .execute(sql`INSERT INTO funnel_events (user_id, type, surface) VALUES ('u1', 'bogus', 'web')`)
      .then(() => undefined, (e: unknown) => e as { cause?: { constraint?: string }; constraint?: string })
    expect(err?.cause?.constraint ?? err?.constraint).toBe('funnel_events_type_check')
  })

  it('dj_sessions.music_chip_at is a nullable timestamptz with no default', async () => {
    const db = await dbWithUser()
    const { rows } = await db.execute<{ data_type: string; is_nullable: string; column_default: string | null }>(sql`
      SELECT data_type, is_nullable, column_default FROM information_schema.columns
      WHERE table_name = 'dj_sessions' AND column_name = 'music_chip_at'
    `)
    expect(rows).toEqual([{ data_type: 'timestamp with time zone', is_nullable: 'YES', column_default: null }])

    const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 'rainy drive' }).returning()
    expect(session.musicChipAt).toBeNull()
    const at = new Date('2026-11-09T12:00:00Z')
    await db.update(djSessions).set({ musicChipAt: at }).where(eq(djSessions.id, session.id))
    const [read] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
    expect(read.musicChipAt).toEqual(at)
  })

  it('the migration only swaps the funnel check and adds the column', async () => {
    const statements = (await readFile(MIGRATION, 'utf8'))
      .split('--> statement-breakpoint')
      .map((s) => s.trim())
      .filter((s) => s !== '')
    expect(statements).toHaveLength(3)
    const drop = statements.findIndex((s) => /^ALTER TABLE "funnel_events" DROP CONSTRAINT "funnel_events_type_check";?$/.test(s))
    const add = statements.findIndex((s) => /^ALTER TABLE "funnel_events" ADD CONSTRAINT "funnel_events_type_check" CHECK/.test(s))
    const column = statements.findIndex((s) =>
      /^ALTER TABLE "dj_sessions" ADD COLUMN "music_chip_at" timestamp with time zone;?$/.test(s),
    )
    expect(drop).toBeGreaterThanOrEqual(0)
    expect(add).toBeGreaterThan(drop)
    expect(column).toBeGreaterThanOrEqual(0)
    for (const type of [...NEW_TYPES, 'catalogue_filled', 'proposed_mix', 'chose_spotify']) {
      expect(statements[add], type).toContain(`'${type}'`)
    }
  })

  it('is journalled as the latest entry after 0047, with a chained snapshot', async () => {
    const journal = JSON.parse(await readFile(JOURNAL, 'utf8')) as { entries: { idx: number; tag: string }[] }
    expect(journal.entries.find((e) => e.idx === 48)?.tag).toBe('0048_music_nudges')
    expect(journal.entries.at(-1)?.idx).toBe(48)
    const prev = JSON.parse(await readFile(SNAPSHOT('0047'), 'utf8')) as { id: string }
    const next = JSON.parse(await readFile(SNAPSHOT('0048'), 'utf8')) as {
      prevId: string
      tables: Record<string, { columns: Record<string, { type: string; notNull: boolean; default?: unknown }> }>
    }
    expect(next.prevId).toBe(prev.id)
    const column = next.tables['public.dj_sessions'].columns.music_chip_at
    expect(column).toMatchObject({ type: 'timestamp with time zone', notNull: false })
    expect(column.default).toBeUndefined()
  })
})
