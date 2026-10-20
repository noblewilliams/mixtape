import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createApp, type AuthLike } from '../../src/app'
import { funnelEvents } from '../../src/db/schema'
import { FUNNEL_EVENT_TYPES, funnelEventSchema } from '../../src/seeds/contracts'
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

describe('funnelEventSchema', () => {
  it('accepts the first-run funnel types (spec 2026-10-20) and keeps the earlier ones', () => {
    for (const type of FIRST_RUN_TYPES) {
      expect(funnelEventSchema.safeParse({ type, surface: 'web' }).success, type).toBe(true)
    }
    expect(FUNNEL_EVENT_TYPES).toEqual(expect.arrayContaining([
      'chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected',
      'import_completed', 'first_personal_mix', 'first_output', ...FIRST_RUN_TYPES,
    ]))
    expect(FUNNEL_EVENT_TYPES).toHaveLength(7 + FIRST_RUN_TYPES.length)
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
    for (const type of FUNNEL_EVENT_TYPES) {
      expect((await post(db, authFor('u1'), { type, surface: 'ios' })).status, type).toBe(201)
    }
    expect(await db.select().from(funnelEvents).where(eq(funnelEvents.userId, 'u1'))).toHaveLength(FUNNEL_EVENT_TYPES.length)
  })

  it('400s on an unknown type, an unknown surface, a missing field, or an unknown key', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    for (const body of [
      { type: 'signed_up', surface: 'ios' },
      { type: 'chose_spotify', surface: 'android' },
      { type: 'chose_spotify' },
      { type: 'chose_spotify', surface: 'ios', userId: 'u2' },
    ]) {
      expect((await post(db, authFor('u1'), body)).status, JSON.stringify(body)).toBe(400)
    }
    expect(await db.select().from(funnelEvents)).toHaveLength(0)
  })
})
