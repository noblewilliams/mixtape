import { describe, it, expect } from 'vitest'
import { eq, sql } from 'drizzle-orm'
import { PgDialect, getTableConfig } from 'drizzle-orm/pg-core'
import { createApp, type AuthLike } from '../../src/app'
import { funnelEvents } from '../../src/db/schema'
import {
  CLIENT_FUNNEL_EVENT_TYPES,
  FIRST_RUN_FUNNEL_EVENT_TYPES,
  FUNNEL_EVENT_TYPES,
  SERVER_FUNNEL_EVENT_TYPES,
  SPOTIFY_FUNNEL_EVENT_TYPES,
  funnelEventSchema,
} from '../../src/seeds/contracts'
import { createTestDb, type TestDb } from '../helpers/db'
import { seedUser } from '../helpers/listening-fixtures'

const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function post(db: TestDb, auth: AuthLike, body: unknown) {
  return createApp({ auth, db }).request('http://x/me/funnel-events', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

const FIRST_RUN_TYPES = [
  'first_run_opened', 'chose_make_mix', 'chose_add_music', 'chose_service', 'chose_method',
  'sync_done', 'first_mix_made', 'first_mix_refused', 'keep_sheet_shown', 'keep_sheet_signed_in',
  'keep_sheet_dismissed', 'cap_reached', 'account_linked_new', 'account_linked_existing',
]

// Client-postable steps of the add-your-music loop (spec 2026-11-09).
const MUSIC_NUDGE_TYPES = ['music_door_tapped', 'music_chip_tapped', 'music_added_from_mix', 'remake_tapped']
// Server-only types, in the order they were added.
const SERVER_TYPES = ['catalogue_filled', 'proposed_mix', 'music_chip_offered', 'remake_made']

// The quoted literals of a check's IN list, in the order they appear.
const literals = (text: string) => [...text.matchAll(/'([^']+)'/g)].map((m) => m[1])

describe('funnelEventSchema', () => {
  it('accepts the first-run funnel types (spec 2026-10-20) and keeps the earlier ones', () => {
    for (const type of FIRST_RUN_TYPES) {
      expect(funnelEventSchema.safeParse({ type, surface: 'web' }).success, type).toBe(true)
    }
    expect(FUNNEL_EVENT_TYPES).toEqual(expect.arrayContaining([
      'chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected',
      'import_completed', 'first_personal_mix', 'first_output', ...FIRST_RUN_TYPES,
    ]))
    expect(FUNNEL_EVENT_TYPES).toHaveLength(7 + FIRST_RUN_TYPES.length + MUSIC_NUDGE_TYPES.length + SERVER_TYPES.length)
  })

  it('accepts the music-nudge types (spec 2026-11-09), appended after the first-run group', () => {
    for (const type of MUSIC_NUDGE_TYPES) {
      expect(funnelEventSchema.safeParse({ type, surface: 'ios' }).success, type).toBe(true)
    }
    expect(CLIENT_FUNNEL_EVENT_TYPES).toEqual([
      ...SPOTIFY_FUNNEL_EVENT_TYPES, ...FIRST_RUN_FUNNEL_EVENT_TYPES, ...MUSIC_NUDGE_TYPES,
    ])
  })

  it('keeps every stored type in one order: client groups, then the server-only types', () => {
    expect(SERVER_FUNNEL_EVENT_TYPES).toEqual(SERVER_TYPES)
    expect(FUNNEL_EVENT_TYPES).toEqual([...CLIENT_FUNNEL_EVENT_TYPES, ...SERVER_FUNNEL_EVENT_TYPES])
    expect(funnelEvents.type.enumValues).toEqual(FUNNEL_EVENT_TYPES)
  })

  it('the schema check on funnel_events.type lists FUNNEL_EVENT_TYPES in the same order', () => {
    const check = getTableConfig(funnelEvents).checks.find((c) => c.name === 'funnel_events_type_check')
    expect(check).toBeDefined()
    expect(literals(new PgDialect().sqlToQuery(check!.value).sql)).toEqual(FUNNEL_EVENT_TYPES)
  })

  it('the migrated database check lists FUNNEL_EVENT_TYPES in the same order', async () => {
    const db = await createTestDb()
    const { rows } = await db.execute<{ def: string }>(
      sql`SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conname = 'funnel_events_type_check'`,
    )
    expect(rows).toHaveLength(1)
    expect(literals(rows[0].def)).toEqual(FUNNEL_EVENT_TYPES)
  })

  it('refuses the server-only catalogue_filled type from a client', () => {
    expect(FUNNEL_EVENT_TYPES).toContain('catalogue_filled')
    expect(funnelEventSchema.safeParse({ type: 'catalogue_filled', surface: 'web' }).success).toBe(false)
  })

  it('refuses the server-only proposed_mix type from a client', () => {
    expect(FUNNEL_EVENT_TYPES).toContain('proposed_mix')
    expect(funnelEventSchema.safeParse({ type: 'proposed_mix', surface: 'ios' }).success).toBe(false)
  })

  it('refuses the server-only music_chip_offered and remake_made types from a client', () => {
    for (const type of ['music_chip_offered', 'remake_made']) {
      expect(FUNNEL_EVENT_TYPES, type).toContain(type)
      expect(funnelEventSchema.safeParse({ type, surface: 'web' }).success, type).toBe(false)
    }
  })
})

describe('POST /me/funnel-events', () => {
  it('401s without a session', async () => {
    const db = await createTestDb()
    expect((await post(db, authFor(null), { type: 'chose_spotify', surface: 'ios' })).status).toBe(401)
  })

  it('inserts a row for the caller and answers 201 {ok: true}', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const response = await post(db, authFor('u1'), { type: 'marked_requested', surface: 'web' })
    expect(response.status).toBe(201)
    expect(await response.json()).toEqual({ ok: true })
    const rows = await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ type: 'marked_requested', surface: 'web' })
    expect(rows[0].createdAt).toBeInstanceOf(Date)
  })

  it('accepts every funnel step the schema knows', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect(FUNNEL_EVENT_TYPES).toEqual(funnelEvents.type.enumValues)
    for (const type of CLIENT_FUNNEL_EVENT_TYPES) {
      expect((await post(db, authFor('u1'), { type, surface: 'ios' })).status, type).toBe(201)
    }
    expect(await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))).toHaveLength(CLIENT_FUNNEL_EVENT_TYPES.length)
  })

  it('accepts each music-nudge type from a client and stores it', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const type of MUSIC_NUDGE_TYPES) {
      expect((await post(db, authFor('u1'), { type, surface: 'web' })).status, type).toBe(201)
    }
    const rows = await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))
    expect(rows.map((r) => r.type).sort()).toEqual([...MUSIC_NUDGE_TYPES].sort())
  })

  it('400s on the server-only music_chip_offered and remake_made types and stores nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const type of ['music_chip_offered', 'remake_made']) {
      expect((await post(db, authFor('u1'), { type, surface: 'ios' })).status, type).toBe(400)
    }
    expect(await db.select().from(funnelEvents)).toHaveLength(0)
  })

  it('400s on an unknown type, an unknown surface, a missing field, or an unknown key', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const body of [
      { type: 'signed_up', surface: 'ios' },
      { type: 'catalogue_filled', surface: 'ios' },
      { type: 'chose_spotify', surface: 'android' },
      { type: 'chose_spotify' },
      { type: 'chose_spotify', surface: 'ios', userId: 'u2' },
    ]) {
      expect((await post(db, authFor('u1'), body)).status, JSON.stringify(body)).toBe(400)
    }
    expect(await db.select().from(funnelEvents)).toHaveLength(0)
  })
})
