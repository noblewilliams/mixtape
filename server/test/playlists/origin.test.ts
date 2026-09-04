import { describe, expect, it } from 'vitest'
import { createApp } from '../../src/app'
import { eq } from 'drizzle-orm'
import { djSessions, user, userMusicProfiles, userPlaylists } from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

function request(db: TestDb, owner: string | null, path: string, body?: unknown, method = 'POST') {
  return createApp({ db, auth: { handler: () => new Response('ok'), api: {
    getSession: async () => owner ? { user: { id: owner } } : null,
  } } }).request(`http://x/playlists${path}`, body === undefined ? undefined : {
    method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  })
}
async function seed(db: TestDb) {
  await db.insert(user).values({ id: 'u1', name: 'User', email: 'u1@example.com' })
  await db.insert(userMusicProfiles).values({ userId: 'u1' })
  const [session] = await db.insert(djSessions).values({ userId: 'u1', title: 'Mix' }).returning()
  return session
}
async function playlist(db: TestDb, libraryId = 'p.created') {
  const [row] = await db.insert(userPlaylists).values({ userId: 'u1', appleLibraryId: libraryId,
    name: 'Playlist', kind: 'user', sourceFingerprint: 'a'.repeat(64) }).returning()
  return row
}

describe('playlist origin', () => {
  it('defaults to unknown; confirmation is explicit, reversible and cannot override a creation receipt', async () => {
    const db = await createTestDb()
    const session = await seed(db)
    const row = await playlist(db)
    const origin = async () => (await (await request(db, 'u1', `/${row.id}`)).json() as
      { playlist: { origin: string } }).playlist.origin
    expect(await origin()).toBe('unknown')
    const confirm = (confirmed: boolean) => request(db, 'u1', `/${row.id}/taste-confirmation`, { confirmed }, 'PUT')
    expect((await confirm(true)).status).toBe(200)
    expect(await origin()).toBe('user_confirmed')
    expect((await confirm(false)).status).toBe(200)
    expect(await origin()).toBe('unknown')
    await confirm(true)
    await request(db, 'u1', '/creation-receipts', { sessionId: session.id, appleLibraryId: row.appleLibraryId })
    expect((await confirm(true)).status).toBe(409)
    expect((await confirm(false)).status).toBe(200)
    expect(await origin()).toBe('mixtape')
  })

  it('rejects cross-user writes, unauthenticated requests, malformed IDs and automatic playlists', async () => {
    const db = await createTestDb()
    const session = await seed(db)
    await db.insert(user).values({ id: 'u2', name: 'Other', email: 'u2@example.com' })
    const row = await playlist(db)
    const receipt = { sessionId: session.id, appleLibraryId: row.appleLibraryId }
    expect((await request(db, null, '/creation-receipts', receipt)).status).toBe(401)
    expect((await request(db, 'u2', '/creation-receipts', receipt)).status).toBe(404)
    expect((await request(db, 'u2', `/${row.id}/taste-confirmation`, { confirmed: true }, 'PUT')).status).toBe(404)
    expect((await request(db, 'u1', '/creation-receipts', { ...receipt, appleLibraryId: 'bad/id' })).status).toBe(400)
    for (const kind of ['editorial', 'replay', 'personal_mix'] as const) {
      await db.update(userPlaylists).set({ kind }).where(eq(userPlaylists.id, row.id))
      expect((await request(db, 'u1', `/${row.id}/taste-confirmation`, { confirmed: true }, 'PUT')).status).toBe(409)
    }
    await db.update(userPlaylists).set({ kind: 'user', inLibrary: false }).where(eq(userPlaylists.id, row.id))
    expect((await request(db, 'u1', `/${row.id}/taste-confirmation`, { confirmed: true }, 'PUT')).status).toBe(409)
  })

  it('keeps an exact creation receipt before sync and exposes it on later browse', async () => {
    const db = await createTestDb()
    const session = await seed(db)
    const receipt = { sessionId: session.id, appleLibraryId: 'p.created' }
    expect((await request(db, 'u1', '/creation-receipts', receipt)).status).toBe(200)
    expect((await request(db, 'u1', '/creation-receipts', receipt)).status).toBe(200)
    const row = await playlist(db)
    const response = await request(db, 'u1', `/${row.id}`)
    expect(await response.json()).toMatchObject({ playlist: { origin: 'mixtape' } })
  })
})
