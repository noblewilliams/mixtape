import { describe, it, expect, afterEach } from 'vitest'
import { eq, sql } from 'drizzle-orm'
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import { vector } from '@electric-sql/pglite-pgvector'
import { drizzle } from 'drizzle-orm/pglite'
import { migrate } from 'drizzle-orm/pglite/migrator'
import { createTestDb } from '../helpers/db'
import { apnsProviderTokens, djSessions, djTurns, pushDevices, user } from '../../src/db/schema'

const MIGRATIONS_DIR = fileURLToPath(new URL('../../drizzle', import.meta.url))
const JOURNAL = join(MIGRATIONS_DIR, 'meta', '_journal.json')
const SNAPSHOT = (n: string) => join(MIGRATIONS_DIR, 'meta', `${n}_snapshot.json`)

type PgError = { cause?: { code?: string; constraint?: string }; code?: string; constraint?: string }
const caught = (p: Promise<unknown>) => p.then(() => undefined, (e: unknown) => e as PgError)
const constraintOf = (e: PgError | undefined) => e?.cause?.constraint ?? e?.constraint
const codeOf = (e: PgError | undefined) => e?.cause?.code ?? e?.code

const cleanupPaths: string[] = []
afterEach(async () => {
  await Promise.all(cleanupPaths.splice(0).map((p) => rm(p, { recursive: true, force: true })))
})

async function insertUser(db: Awaited<ReturnType<typeof createTestDb>>, id: string) {
  await db.insert(user).values({ id, name: id, email: `${id}@example.com`, emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
}

// u1 has a session with one turn pointed at by current_turn_id, and a phone.
async function seed() {
  const db = await createTestDb()
  await insertUser(db, 'u1')
  const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 'rainy drive' }).returning()
  const [turn] = await db.insert(djTurns).values({ sessionId: session.id, userId: 'u1', kind: 'create' }).returning()
  await db.update(djSessions).set({ currentTurnId: turn.id }).where(eq(djSessions.id, session.id))
  await db.insert(pushDevices).values({ userId: 'u1', provider: 'apns', platform: 'ios', token: 'ab'.repeat(32), environment: 'sandbox' })
  return { db, session, turn }
}

// Migration 0055: durable mix turns (spec 2026-11-21 durable-mix-turns,
// "Turn records", "Device registration", "APNs from Workers").
describe('migration 0055 durable turns', () => {
  it('applies on top of 0054 and leaves existing sessions without a current turn', async () => {
    const journal = JSON.parse(await readFile(JOURNAL, 'utf8')) as { entries: Array<{ idx: number; tag: string }> }
    const baselineDir = await mkdtemp(join(tmpdir(), 'mixtape-migrations-0054-'))
    cleanupPaths.push(baselineDir)
    await mkdir(join(baselineDir, 'meta'))
    const baseline = journal.entries.filter((e) => e.idx <= 54)
    await writeFile(join(baselineDir, 'meta', '_journal.json'), JSON.stringify({ ...journal, entries: baseline }))
    await Promise.all(baseline.map((e) => copyFile(join(MIGRATIONS_DIR, `${e.tag}.sql`), join(baselineDir, `${e.tag}.sql`))))

    const client = new PGlite({ extensions: { vector } })
    try {
      const db = drizzle(client)
      await migrate(db, { migrationsFolder: baselineDir })
      await client.exec(`
        INSERT INTO "user" ("id", "name", "email") VALUES ('old', 'Old', 'old@example.test');
        INSERT INTO "dj_sessions" ("id", "user_id", "title") VALUES ('00000000-0000-4000-8000-000000000003', 'old', 'Legacy');
      `)
      await migrate(db, { migrationsFolder: MIGRATIONS_DIR })
      const { rows } = await client.query<{ current_turn_id: string | null }>(`SELECT current_turn_id FROM dj_sessions`)
      expect(rows).toEqual([{ current_turn_id: null }])
    } finally {
      await client.close()
    }
  })

  it('fills turn defaults; a caller-supplied id (the idempotency key) is kept', async () => {
    const { db, session, turn } = await seed()
    expect(turn.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(turn).toMatchObject({ status: 'queued', attempt: 0, watchedResult: false, step: null, writes: null, notifyOutcome: null, startedAt: null, finishedAt: null })
    expect(turn.createdAt).toBeInstanceOf(Date)
    const key = '11111111-1111-4111-8111-111111111111'
    const [own] = await db.insert(djTurns).values({ id: key, sessionId: session.id, userId: 'u1', kind: 'message' }).returning()
    expect(own.id).toBe(key)
    expect(codeOf(await caught(db.insert(djTurns).values({ id: key, sessionId: session.id, userId: 'u1', kind: 'message' })))).toBe('23505')
  })

  it('fills device defaults', async () => {
    const { db } = await seed()
    const [device] = await db.select().from(pushDevices)
    expect(device.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(device.createdAt).toBeInstanceOf(Date)
    expect(device.lastSeenAt).toBeInstanceOf(Date)
    expect(device).toMatchObject({ disabledAt: null, keys: null, appVersion: null })
  })

  it('deleting a session removes its turns', async () => {
    const { db, session } = await seed()
    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    expect(await db.select().from(djTurns)).toHaveLength(0)
  })

  it('deleting a user removes their turns and devices', async () => {
    const { db } = await seed()
    await db.delete(user).where(eq(user.id, 'u1'))
    expect(await db.select().from(djTurns)).toHaveLength(0)
    expect(await db.select().from(pushDevices)).toHaveLength(0)
  })

  it('deleting a turn nulls the session pointer and keeps the session', async () => {
    const { db, session, turn } = await seed()
    await db.delete(djTurns).where(eq(djTurns.id, turn.id))
    const [row] = await db.select().from(djSessions).where(eq(djSessions.id, session.id))
    expect(row.currentTurnId).toBeNull()
  })

  it('current_turn_id must name a real turn', async () => {
    const { db, session } = await seed()
    const err = await caught(db.update(djSessions).set({ currentTurnId: '22222222-2222-4222-8222-222222222222' }).where(eq(djSessions.id, session.id)))
    expect(codeOf(err)).toBe('23503')
  })

  it('refuses a duplicate (provider, token), even for another user', async () => {
    const { db } = await seed()
    await insertUser(db, 'u2')
    const err = await caught(db.insert(pushDevices).values({ userId: 'u2', provider: 'apns', platform: 'ios', token: 'ab'.repeat(32), environment: 'production' }))
    expect(codeOf(err)).toBe('23505')
    // The same token under another provider is a different device.
    await db.insert(pushDevices).values({ userId: 'u2', provider: 'fcm', platform: 'android', token: 'ab'.repeat(32) })
  })

  it.each([
    ['dj_turns', 'kind', `INSERT INTO dj_turns (session_id, user_id, kind) VALUES ($S, 'u1', 'bogus')`, 'dj_turns_kind_check'],
    ['dj_turns', 'status', `INSERT INTO dj_turns (session_id, user_id, kind, status) VALUES ($S, 'u1', 'create', 'bogus')`, 'dj_turns_status_check'],
    ['dj_turns', 'notify_outcome', `INSERT INTO dj_turns (session_id, user_id, kind, notify_outcome) VALUES ($S, 'u1', 'create', 'bogus')`, 'dj_turns_notify_outcome_check'],
    ['push_devices', 'provider', `INSERT INTO push_devices (user_id, provider, platform, token) VALUES ('u1', 'bogus', 'ios', 't1')`, 'push_devices_provider_check'],
    ['push_devices', 'platform', `INSERT INTO push_devices (user_id, provider, platform, token) VALUES ('u1', 'apns', 'bogus', 't2')`, 'push_devices_platform_check'],
    ['push_devices', 'environment', `INSERT INTO push_devices (user_id, provider, platform, token, environment) VALUES ('u1', 'apns', 'ios', 't3', 'bogus')`, 'push_devices_environment_check'],
  ])('%s.%s rejects an unknown value', async (_table, _column, insert, constraint) => {
    const { db, session } = await seed()
    const err = await caught(db.$client.query(insert.replace('$S', `'${session.id}'`)))
    expect(constraintOf(err)).toBe(constraint)
  })

  it('check constraints admit every spec value', async () => {
    const { db, session } = await seed()
    for (const kind of ['create', 'message', 'remake'] as const) {
      for (const status of ['queued', 'running', 'done', 'failed', 'stopped'] as const) {
        await db.insert(djTurns).values({ sessionId: session.id, userId: 'u1', kind, status })
      }
    }
    for (const notifyOutcome of ['sent', 'seen', 'no_device', 'off', 'failed'] as const) {
      await db.insert(djTurns).values({ sessionId: session.id, userId: 'u1', kind: 'create', notifyOutcome })
    }
    const devices = [
      { provider: 'apns', platform: 'ios', environment: 'production' },
      { provider: 'fcm', platform: 'android', environment: null },
      { provider: 'webpush', platform: 'web', environment: null, keys: { p256dh: 'p', auth: 'a' } },
    ] as const
    for (const [i, d] of devices.entries()) {
      await db.insert(pushDevices).values({ userId: 'u1', token: `tok-${i}`, ...d })
    }
    expect(await db.select().from(pushDevices)).toHaveLength(4)
  })

  it('apns_provider_tokens holds one signed token per key id', async () => {
    const { db } = await seed()
    const issuedAt = new Date('2026-11-22T12:00:00Z')
    await db.insert(apnsProviderTokens).values({ keyId: 'ABC123DEFG', token: 'jwt', issuedAt })
    expect(await db.select().from(apnsProviderTokens)).toEqual([{ keyId: 'ABC123DEFG', token: 'jwt', issuedAt }])
    expect(codeOf(await caught(db.insert(apnsProviderTokens).values({ keyId: 'ABC123DEFG', token: 'jwt2', issuedAt })))).toBe('23505')
  })

  it('has the session-history index and the partial index on live turns', async () => {
    const { db } = await seed()
    const { rows } = await db.execute<{ indexname: string; indexdef: string }>(sql`
      SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'dj_turns' ORDER BY indexname
    `)
    const defs = Object.fromEntries(rows.map((r) => [r.indexname, r.indexdef]))
    expect(defs.dj_turns_session_created_idx).toMatch(/\(session_id, created_at DESC( NULLS LAST)?\)/)
    expect(defs.dj_turns_live_heartbeat_idx).toMatch(/\(status, heartbeat_at\) WHERE \(status = ANY \(ARRAY\['queued'::text, 'running'::text\]\)\)/)
  })

  it('is journalled right after 0054, with a chained snapshot', async () => {
    const journal = JSON.parse(await readFile(JOURNAL, 'utf8')) as { entries: { idx: number; tag: string }[] }
    const at = journal.entries.findIndex((e) => e.idx === 55)
    expect(journal.entries[at]?.tag).toMatch(/^0055_/)
    expect(journal.entries[at - 1]?.idx).toBe(54)
    const prev = JSON.parse(await readFile(SNAPSHOT('0054'), 'utf8')) as { id: string }
    const next = JSON.parse(await readFile(SNAPSHOT('0055'), 'utf8')) as { prevId: string; tables: Record<string, unknown> }
    expect(next.prevId).toBe(prev.id)
    expect(Object.keys(next.tables)).toEqual(expect.arrayContaining(['public.dj_turns', 'public.push_devices', 'public.apns_provider_tokens']))
  })
})
