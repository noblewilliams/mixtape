import { describe, expect, it } from 'vitest'
import { eq } from 'drizzle-orm'
import { createApp } from '../../src/app'
import { createTestDb, type TestDb } from '../helpers/db'
import { djSessions, playlistEntries, sessionPlaylistSeeds, tracks, user, userPlaylists } from '../../src/db/schema'

async function fixture() {
  const db = await createTestDb()
  await db.insert(user).values([{ id: 'seed-owner', name: 'Owner', email: 'seed-owner@example.com' },
    { id: 'seed-other', name: 'Other', email: 'seed-other@example.com' }])
  const [session] = await db.insert(djSessions).values({ userId: 'seed-owner', title: 'Mix' }).returning()
  const [playlist] = await db.insert(userPlaylists).values({ userId: 'seed-owner',
    appleLibraryId: 'p.seed', name: 'Late Nights', kind: 'editorial', sourceFingerprint: 'a'.repeat(64) }).returning()
  const songs = await db.insert(tracks).values([0, 1, 2].map(i => ({ appleId: `seed-${i}`,
    title: `Song ${i}`, artist: `Artist ${i}`, genre: 'Soul' }))).returning()
  await db.insert(playlistEntries).values(songs.map((song, position) => ({ playlistId: playlist.id,
    position, trackId: song.id, appleLibraryEntryId: `entry-${position}`,
    titleSnapshot: song.title, artistSnapshot: song.artist })))
  return { db, session, playlist, songs }
}
function appFor(db: TestDb, id = 'seed-owner') {
  return createApp({ db, auth: { handler: () => new Response('ok'), api: {
    getSession: async () => ({ user: { id } }),
  } }, dj: { deps: { embed: async () => Array(1024).fill(0), llm: async () => ({ text: 'ready',
    toolCalls: [], raw: [{ type: 'text', text: 'ready' }], stopReason: 'end_turn',
    usage: { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null } }) } } })
}
function put(app: ReturnType<typeof appFor>, sessionId: string, body: unknown) {
  return app.request(`http://x/sessions/${sessionId}/playlist-seed`, { method: 'PUT',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
}

describe('playlist inspiration session contract', () => {
  it('persists an explicit seed across requests without changing the queue', async () => {
    const { db, session, playlist } = await fixture()
    const response = await put(appFor(db), session.id, { playlistId: playlist.id, expectedRevision: 0 })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ playlistSeed: { playlistId: playlist.id,
      revision: 1, excludeSourceTracks: false, status: 'ready', profile: {
        sampledRecordings: 3, artists: ['Artist 0', 'Artist 1', 'Artist 2'], genres: ['Soul'],
      } } })
    const reopened = await appFor(db).request(`http://x/sessions/${session.id}`)
    expect(await reopened.json()).toMatchObject({ playlistSeed: { playlistId: playlist.id, revision: 1 }, queue: [] })
  })

  it('protects ownership and revisions and clears without changing the mix', async () => {
    const { db, session, playlist } = await fixture()
    const owner = appFor(db)
    expect((await put(appFor(db, 'seed-other'), session.id,
      { playlistId: playlist.id, expectedRevision: 0 })).status).toBe(404)
    expect((await put(owner, session.id, { playlistId: playlist.id,
      expectedRevision: 0, excludeSourceTracks: true })).status).toBe(200)
    expect((await put(owner, session.id, { playlistId: null,
      expectedRevision: 0 })).status).toBe(409)
    const cleared = await put(owner, session.id, { playlistId: null,
      expectedRevision: 1, excludeSourceTracks: true })
    expect(await cleared.json()).toMatchObject({ playlistSeed: { status: 'none',
      playlistId: null, revision: 2, excludeSourceTracks: false } })
  })

  it('rejects a playlist too empty to describe rather than pretending it is inspiration', async () => {
    const { db, session, playlist, songs } = await fixture()
    await db.delete(playlistEntries)
    await db.insert(playlistEntries).values({ playlistId: playlist.id, position: 0,
      trackId: songs[0].id, appleLibraryEntryId: 'only', titleSnapshot: 'Only', artistSnapshot: 'Artist' })
    expect((await put(appFor(db), session.id,
      { playlistId: playlist.id, expectedRevision: 0 })).status).toBe(409)
  })

  it('can create an ordinary session with inspiration selected atomically', async () => {
    const { db, playlist } = await fixture()
    const response = await appFor(db).request('http://x/sessions', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ prompt: 'make it calmer',
        playlistSeed: { playlistId: playlist.id, excludeSourceTracks: true } }) })
    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({ playlistSeed: { playlistId: playlist.id,
      excludeSourceTracks: true, revision: 1, status: 'ready' } })
  })

  it('retains an unavailable tombstone after source deletion and cascades it with the session', async () => {
    const { db, session, playlist } = await fixture()
    expect((await put(appFor(db), session.id, { playlistId: playlist.id, expectedRevision: 0 })).status).toBe(200)
    await db.delete(userPlaylists).where(eq(userPlaylists.id, playlist.id))

    const reopened = await appFor(db).request(`http://x/sessions/${session.id}`)
    expect(await reopened.json()).toMatchObject({ playlistSeed: {
      playlistId: null, revision: 1, status: 'unavailable', excludeSourceTracks: false,
    } })

    await db.delete(djSessions).where(eq(djSessions.id, session.id))
    expect(await db.select().from(sessionPlaylistSeeds)).toEqual([])
  })
})
