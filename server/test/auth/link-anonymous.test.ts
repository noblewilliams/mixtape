import { describe, it, expect, vi, afterEach } from 'vitest'
import { and, count, eq } from 'drizzle-orm'
import { randomUUID } from 'node:crypto'
import { createTestDb, type TestDb } from '../helpers/db'
import { testAuthEnv } from '../helpers/auth'
import { createAuth } from '../../src/auth/create-auth'
import { createApp } from '../../src/app'
import { linkAnonymousAccount, linkAnonymousRows } from '../../src/auth/link-anonymous'
import {
  user,
  session,
  tracks,
  djSessions,
  djMessages,
  queueTracks,
  djMemories,
  funnelEvents,
  playbackEvidence,
  userTracks,
  userTrackLibrarySources,
  userRecentTrackObservations,
  listeningDays,
  userMusicProfiles,
  userArtistSeeds,
  userMusicSources,
  librarySyncRuns,
  listeningImportRuns,
  playlistSyncRuns,
  playlistOrigins,
  userPlaylists,
  playlistEditDrafts,
  playbackSettings,
  suggestionSettings,
} from '../../src/db/schema'

// Every table that carries user_id. Children keyed only by a parent id
// (dj_messages, queue_tracks, run staging rows) follow their parent.
const USER_TABLES = {
  dj_sessions: djSessions,
  dj_memories: djMemories,
  funnel_events: funnelEvents,
  playback_evidence: playbackEvidence,
  user_tracks: userTracks,
  user_track_library_sources: userTrackLibrarySources,
  user_recent_track_observations: userRecentTrackObservations,
  listening_days: listeningDays,
  user_music_profiles: userMusicProfiles,
  user_artist_seeds: userArtistSeeds,
  user_music_sources: userMusicSources,
  library_sync_runs: librarySyncRuns,
  listening_import_runs: listeningImportRuns,
  playlist_sync_runs: playlistSyncRuns,
  playlist_origins: playlistOrigins,
  user_playlists: userPlaylists,
  playlist_edit_drafts: playlistEditDrafts,
  playback_settings: playbackSettings,
  suggestion_settings: suggestionSettings,
} as const

type TableName = keyof typeof USER_TABLES
const FP = 'a'.repeat(64)
const MIX_TABLES: TableName[] = ['dj_sessions', 'dj_memories', 'funnel_events', 'playback_evidence']
const LIBRARY_TABLES = (Object.keys(USER_TABLES) as TableName[]).filter((t) => !MIX_TABLES.includes(t))

async function countsFor(db: TestDb, userId: string): Promise<Record<TableName, number>> {
  const out = {} as Record<TableName, number>
  for (const [name, table] of Object.entries(USER_TABLES) as [TableName, (typeof USER_TABLES)[TableName]][]) {
    const [row] = await db.select({ n: count() }).from(table).where(eq(table.userId, userId))
    out[name] = row!.n
  }
  return out
}

async function makeUser(db: TestDb, { anonymous }: { anonymous: boolean }) {
  const id = randomUUID()
  await db.insert(user).values({
    id,
    name: anonymous ? 'Listener' : 'Real',
    email: `${id}@${anonymous ? 'anonymous.mixtape.invalid' : 'example.com'}`,
    isAnonymous: anonymous,
  })
  return id
}

async function makeTrack(db: TestDb, title: string) {
  const [row] = await db.insert(tracks).values({ title, artist: 'Artist' }).returning({ id: tracks.id })
  return row!.id
}

// One row (at least) in every user-keyed table, plus session children.
async function seedEverything(db: TestDb, userId: string, { note = 'likes brass', seed = 'Khruangbin' } = {}) {
  const trackId = await makeTrack(db, `track-${userId}`)
  const [mix] = await db.insert(djSessions).values({ userId, title: 'Late night' }).returning({ id: djSessions.id })
  const sessionId = mix!.id
  await db.insert(djMessages).values({ sessionId, role: 'user', content: 'something warm' })
  await db.insert(queueTracks).values({ sessionId, position: 0, trackId, addedBy: 'dj' })
  await db.insert(djMemories).values({ userId, note })
  await db.insert(funnelEvents).values({ userId, type: 'first_mix_made', surface: 'web' })
  await db.insert(playbackEvidence).values({
    userId, playbackId: randomUUID(), sequence: 1, sessionId, version: 1, position: 0, trackId,
    source: 'web', kind: 'progress', observedMs: 1000, occurredAt: new Date(),
  })
  await db.insert(userTracks).values({ userId, trackId })
  await db.insert(userTrackLibrarySources).values({ userId, trackId, source: 'apple_live' })
  await db.insert(userRecentTrackObservations).values({
    userId, source: 'web_musickit', trackId, rank: 0, observedAt: new Date(),
  })
  await db.insert(listeningDays).values({
    userId, source: 'spotify_export', trackId, day: '2026-10-01', plays: 1, msPlayed: 1000,
  })
  await db.insert(userMusicProfiles).values({ userId, appleStorefront: 'us' })
  await db.insert(userArtistSeeds).values({ userId, name: seed, source: 'interview' })
  await db.insert(userMusicSources).values({ userId, source: 'apple_live' })
  const expiresAt = new Date(Date.now() + 3_600_000)
  await db.insert(librarySyncRuns).values({
    userId, source: 'web_musickit', status: 'open', appleStorefront: 'us', expectedSongs: 0, expiresAt,
  })
  await db.insert(listeningImportRuns).values({
    userId, source: 'spotify_export', package: 'spotify_extended', status: 'open', timeZone: 'UTC',
    expectedTracks: 0, expectedDays: 0, expectedLibraryTracks: 0, expectedArtists: 0, expiresAt,
  })
  await db.insert(playlistSyncRuns).values({
    userId, source: 'web_musickit', status: 'open', appleStorefront: 'us',
    expectedPlaylists: 0, expectedEntries: 0, expiresAt,
  })
  await db.insert(playlistOrigins).values({ userId, source: 'apple', libraryId: 'p.1', origin: 'mixtape' })
  const [playlist] = await db.insert(userPlaylists).values({
    userId, appleLibraryId: 'p.1', name: 'Mine', kind: 'user', sourceFingerprint: FP,
  }).returning({ id: userPlaylists.id })
  await db.insert(playlistEditDrafts).values({
    userId, sourcePlaylistId: playlist!.id, baseSourceFingerprint: FP, baseName: 'Mine', sourceType: 'apple',
  })
  await db.insert(playbackSettings).values({ userId, enabled: true })
  await db.insert(suggestionSettings).values({ userId })
  return { sessionId, trackId }
}

describe('linkAnonymousRows', () => {
  it('moves every user-keyed row into a brand-new account (mode all)', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const fresh = await makeUser(db, { anonymous: false })
    const { sessionId } = await seedEverything(db, anon)
    const before = await countsFor(db, anon)
    for (const n of Object.values(before)) expect(n).toBeGreaterThan(0)

    const result = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: fresh })

    expect(result).toEqual({ mode: 'all' })
    const after = await countsFor(db, fresh)
    // The new account also gains its account_linked_new funnel row.
    expect(after).toEqual({ ...before, funnel_events: before.funnel_events + 1 })
    expect(Object.values(await countsFor(db, anon)).every((n) => n === 0)).toBe(true)
    // Session children came along with their parent.
    expect(await db.select().from(djMessages).where(eq(djMessages.sessionId, sessionId))).toHaveLength(1)
    expect(await db.select().from(queueTracks).where(eq(queueTracks.sessionId, sessionId))).toHaveLength(1)

    // The plugin's delete then has nothing left to cascade.
    await db.delete(user).where(eq(user.id, anon))
    expect(await countsFor(db, fresh)).toEqual(after)
  })

  it('moves only mixes into an account that already has a library (mode mixes_only)', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const existing = await makeUser(db, { anonymous: false })
    await seedEverything(db, anon)
    const ownTrack = await makeTrack(db, 'own')
    await db.insert(userTracks).values({ userId: existing, trackId: ownTrack })
    await db.insert(userMusicSources).values({ userId: existing, source: 'spotify_export' })
    await db.insert(playbackSettings).values({ userId: existing, enabled: false })
    const anonBefore = await countsFor(db, anon)
    const existingBefore = await countsFor(db, existing)

    const result = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: existing })

    expect(result).toEqual({ mode: 'mixes_only' })
    const existingAfter = await countsFor(db, existing)
    const anonAfter = await countsFor(db, anon)
    for (const t of MIX_TABLES) {
      const linkRow = t === 'funnel_events' ? 1 : 0
      expect(existingAfter[t], t).toBe(existingBefore[t] + anonBefore[t] + linkRow)
      expect(anonAfter[t], t).toBe(0)
    }
    for (const t of LIBRARY_TABLES) {
      expect(existingAfter[t], t).toBe(existingBefore[t])
      expect(anonAfter[t], t).toBe(anonBefore[t])
    }
    // The existing account's own settings win.
    const [settings] = await db.select().from(playbackSettings).where(eq(playbackSettings.userId, existing))
    expect(settings?.enabled).toBe(false)

    // The plugin's delete removes the anonymous library with no FK error,
    // and the moved mixes survive it.
    await db.delete(user).where(eq(user.id, anon))
    expect(await countsFor(db, existing)).toEqual(existingAfter)
    expect(Object.values(await countsFor(db, anon)).every((n) => n === 0)).toBe(true)
  })

  it('never collides on a memory note the existing account already has', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const existing = await makeUser(db, { anonymous: false })
    await seedEverything(db, anon, { note: 'no country' })
    await seedEverything(db, existing, { note: 'no country' })

    const result = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: existing })

    expect(result).toEqual({ mode: 'mixes_only' })
    const notes = await db.select().from(djMemories).where(eq(djMemories.userId, existing))
    expect(notes.map((n) => n.note)).toEqual(['no country'])
    await db.delete(user).where(eq(user.id, anon))
  })

  it('keeps the account side of any unique key when an account with no mixes or library takes everything', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const sparse = await makeUser(db, { anonymous: false })
    await seedEverything(db, anon, { note: 'shared note', seed: 'Shared Artist' })
    await db.insert(playbackSettings).values({ userId: sparse, enabled: false })
    await db.insert(suggestionSettings).values({ userId: sparse, enabled: false })
    await db.insert(userArtistSeeds).values({ userId: sparse, name: 'Shared Artist', source: 'pasted' })
    await db.insert(djMemories).values({ userId: sparse, note: 'shared note' })
    await db.insert(userMusicProfiles).values({ userId: sparse, appleStorefront: 'gb' })
    const expiresAt = new Date(Date.now() + 3_600_000)
    await db.insert(listeningImportRuns).values({
      userId: sparse, source: 'spotify_export', package: 'spotify_extended', status: 'open', timeZone: 'UTC',
      expectedTracks: 0, expectedDays: 0, expectedLibraryTracks: 0, expectedArtists: 0, expiresAt,
    })

    const result = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: sparse })

    expect(result).toEqual({ mode: 'all' })
    const after = await countsFor(db, sparse)
    expect(after.dj_sessions).toBe(1)
    expect(after.user_tracks).toBe(1)
    expect(after.playback_settings).toBe(1)
    expect(after.user_artist_seeds).toBe(1)
    expect(after.dj_memories).toBe(1)
    expect(after.listening_import_runs).toBe(1)
    const [settings] = await db.select().from(playbackSettings).where(eq(playbackSettings.userId, sparse))
    expect(settings?.enabled).toBe(false)
    const [seed] = await db.select().from(userArtistSeeds).where(eq(userArtistSeeds.userId, sparse))
    expect(seed?.source).toBe('pasted')
    const [profile] = await db.select().from(userMusicProfiles).where(eq(userMusicProfiles.userId, sparse))
    expect(profile?.appleStorefront).toBe('gb')
    await db.delete(user).where(eq(user.id, anon))
  })

  it('is a no-op on retry: none while the anonymous user exists, none once it is gone', async () => {
    for (const existingLibrary of [false, true]) {
      const db = await createTestDb()
      const anon = await makeUser(db, { anonymous: true })
      const target = await makeUser(db, { anonymous: false })
      await seedEverything(db, anon)
      if (existingLibrary) {
        await db.insert(userTracks).values({ userId: target, trackId: await makeTrack(db, 'own') })
      }

      const first = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: target })
      const afterFirst = { target: await countsFor(db, target), anon: await countsFor(db, anon) }
      const second = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: target })

      expect(second).toEqual({ mode: 'none' })
      expect(first.mode).toBe(existingLibrary ? 'mixes_only' : 'all')
      expect({ target: await countsFor(db, target), anon: await countsFor(db, anon) }).toEqual(afterFirst)

      await db.delete(user).where(eq(user.id, anon))
      const afterDelete = await countsFor(db, target)
      const third = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: target })
      expect(third).toEqual({ mode: 'none' })
      expect(await countsFor(db, target)).toEqual(afterDelete)
    }
  })

  it('returns none and writes nothing when the ids are the same', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    await seedEverything(db, anon)
    const before = await countsFor(db, anon)

    expect(await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: anon })).toEqual({ mode: 'none' })
    expect(await countsFor(db, anon)).toEqual(before)
  })

  it('records the link in the funnel with the right type and surface', async () => {
    const db = await createTestDb()
    const anonA = await makeUser(db, { anonymous: true })
    const fresh = await makeUser(db, { anonymous: false })
    await seedEverything(db, anonA)
    await linkAnonymousRows(db, { anonymousUserId: anonA, newUserId: fresh, surface: 'ios' })

    const linkedNew = await db.select().from(funnelEvents)
      .where(and(eq(funnelEvents.userId, fresh), eq(funnelEvents.type, 'account_linked_new')))
    expect(linkedNew).toHaveLength(1)
    expect(linkedNew[0]!.surface).toBe('ios')

    const anonB = await makeUser(db, { anonymous: true })
    await seedEverything(db, anonB)
    await linkAnonymousRows(db, { anonymousUserId: anonB, newUserId: fresh })

    const linkedExisting = await db.select().from(funnelEvents)
      .where(and(eq(funnelEvents.userId, fresh), eq(funnelEvents.type, 'account_linked_existing')))
    expect(linkedExisting).toHaveLength(1)
    expect(linkedExisting[0]!.surface).toBe('web')
  })

  async function linkWithSession(db: TestDb, anon: string, target: string) {
    const sessionId = randomUUID()
    await db.insert(session).values({
      id: sessionId, token: randomUUID(), userId: target, expiresAt: new Date(Date.now() + 3_600_000),
      updatedAt: new Date(),
    })
    const result = await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: target, newSessionId: sessionId })
    const [row] = await db.select().from(session).where(eq(session.id, sessionId))
    return { result, mergedMode: row?.mergedMode ?? null }
  }

  async function accountWithLibrary(db: TestDb) {
    const id = await makeUser(db, { anonymous: false })
    await db.insert(userTracks).values({ userId: id, trackId: await makeTrack(db, `own-${id}`) })
    await db.insert(userMusicSources).values({ userId: id, source: 'apple_live' })
    return id
  }

  it('stamps library_kept when a synced library with no mixes meets an account with a library', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const existing = await accountWithLibrary(db)
    // Path B: synced, never made a mix. The sync left its funnel step.
    const trackId = await makeTrack(db, 'anon library')
    await db.insert(userTracks).values({ userId: anon, trackId })
    await db.insert(userMusicSources).values({ userId: anon, source: 'apple_live' })
    await db.insert(funnelEvents).values({ userId: anon, type: 'sync_done', surface: 'ios' })

    const { result, mergedMode } = await linkWithSession(db, anon, existing)

    expect(result).toEqual({ mode: 'mixes_only' })
    expect(mergedMode).toBe('library_kept')
  })

  it('stamps nothing when the anonymous user had only funnel rows', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const existing = await accountWithLibrary(db)
    await db.insert(funnelEvents).values({ userId: anon, type: 'first_run_opened', surface: 'web' })

    const { result, mergedMode } = await linkWithSession(db, anon, existing)

    expect(result).toEqual({ mode: 'mixes_only' })
    expect(mergedMode).toBeNull()
    const [moved] = await db.select({ n: count() }).from(funnelEvents)
      .where(and(eq(funnelEvents.userId, existing), eq(funnelEvents.type, 'first_run_opened')))
    expect(moved!.n).toBe(1)
  })

  it('stamps mixes_only when mixes moved into an account with a library', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const existing = await accountWithLibrary(db)
    await db.insert(djSessions).values({ userId: anon, title: 'First' })

    const { mergedMode } = await linkWithSession(db, anon, existing)

    expect(mergedMode).toBe('mixes_only')
  })

  it('stores the mode on the new session when given one', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const fresh = await makeUser(db, { anonymous: false })
    await seedEverything(db, anon)
    const sessionId = randomUUID()
    await db.insert(session).values({
      id: sessionId, token: randomUUID(), userId: fresh, expiresAt: new Date(Date.now() + 3_600_000),
      updatedAt: new Date(),
    })

    await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: fresh, newSessionId: sessionId })

    const [row] = await db.select().from(session).where(eq(session.id, sessionId))
    expect(row?.mergedMode).toBe('all')
  })
})

describe('linkAnonymousAccount (the plugin hook)', () => {
  afterEach(() => vi.restoreAllMocks())

  function hookInput(anonymousUserId: string, newUserId: string, newSessionId: string) {
    const now = new Date()
    const base = { emailVerified: false, createdAt: now, updatedAt: now, image: null }
    const sess = (id: string, userId: string) => ({
      id, userId, token: id, expiresAt: now, createdAt: now, updatedAt: now,
    })
    return {
      anonymousUser: { user: { ...base, id: anonymousUserId, name: 'Listener', email: 'a@x.invalid' }, session: sess('anon-session', anonymousUserId) },
      newUser: { user: { ...base, id: newUserId, name: 'Real', email: 'r@example.com' }, session: sess(newSessionId, newUserId) },
    }
  }

  it('runs the merge with the plugin data', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const fresh = await makeUser(db, { anonymous: false })
    await seedEverything(db, anon)

    await linkAnonymousAccount(db, hookInput(anon, fresh, 'no-such-session'))

    expect((await countsFor(db, fresh)).dj_sessions).toBe(1)
  })

  it('logs and rethrows a failure so the sign-in fails instead of losing data', async () => {
    const db = await createTestDb()
    const logged = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const broken = { transaction: () => Promise.reject(new Error('db down')) } as unknown as TestDb

    await expect(linkAnonymousAccount(broken, hookInput('a', 'b', 'c'))).rejects.toThrow('db down')
    expect(logged).toHaveBeenCalled()
    void db
  })
})

// Better Auth's default rate-limit storage is a module-level Map; give each
// request its own IP so buckets never bleed across tests.
let ipCounter = 0
function freshIp() {
  ipCounter += 1
  return `198.51.100.${ipCounter}`
}

describe('anonymous to account, end to end through Better Auth', () => {
  afterEach(() => vi.restoreAllMocks())

  async function setup({ breakTransactions }: { breakTransactions?: { on: boolean } } = {}) {
    const db = await createTestDb()
    // Optionally fail every db.transaction while the flag is on: the merge is
    // the only transaction on the social sign-in path.
    const authDb = breakTransactions
      ? new Proxy(db, {
          get(target, prop, receiver) {
            if (prop === 'transaction' && breakTransactions.on) {
              return () => Promise.reject(Object.assign(new Error('link broke'), { code: '40001' }))
            }
            return Reflect.get(target, prop, receiver)
          },
        })
      : db
    const auth = createAuth(authDb, testAuthEnv)
    const app = createApp({ auth, db })
    // Stand-in for Google: accept the id token and return a fixed profile,
    // so the real /sign-in/social id-token path and the plugin hooks run.
    const ctx = await auth.$context
    const google = ctx.socialProviders.find((p) => p.id === 'google')!
    google.options = { ...google.options, verifyIdToken: async () => true }
    google.getUserInfo = async () => ({
      user: { email: 'listener@example.com', name: 'Listener Real', emailVerified: true },
      data: { sub: 'google-sub-1', email: 'listener@example.com' },
    })
    return { db, auth, app }
  }

  function post(auth: ReturnType<typeof createAuth>, path: string, body: unknown, token?: string) {
    const headers: Record<string, string> = {
      'content-type': 'application/json',
      origin: 'http://localhost:4176',
      'cf-connecting-ip': freshIp(),
    }
    if (token) headers.authorization = `Bearer ${token}`
    return auth.handler(new Request(`http://localhost:8787/api/auth${path}`, {
      method: 'POST', headers, body: JSON.stringify(body),
    }))
  }

  it('repoints the mix to the new account, deletes the anonymous user, and reports merged once on /me', async () => {
    const { db, auth, app } = await setup()
    const anonRes = await post(auth, '/sign-in/anonymous', {})
    expect(anonRes.status).toBe(200)
    const anonBearer = anonRes.headers.get('set-auth-token')!
    const { user: anon } = await anonRes.json() as { user: { id: string } }
    const [mix] = await db.insert(djSessions).values({ userId: anon.id, title: 'First' }).returning()

    const social = await post(auth, '/sign-in/social', {
      provider: 'google', idToken: { token: 'fake-google-id-token' },
    }, anonBearer)
    expect(social.status).toBe(200)
    const accountBearer = social.headers.get('set-auth-token')!
    const { user: account } = await social.json() as { user: { id: string } }

    expect(account.id).not.toBe(anon.id)
    const [moved] = await db.select().from(djSessions).where(eq(djSessions.id, mix!.id))
    expect(moved?.userId).toBe(account.id)
    expect(await db.select().from(user).where(eq(user.id, anon.id))).toHaveLength(0)
    const linked = await db.select().from(funnelEvents)
      .where(and(eq(funnelEvents.userId, account.id), eq(funnelEvents.type, 'account_linked_new')))
    expect(linked).toHaveLength(1)

    const me = (token: string) => app.request('http://localhost:8787/me', {
      headers: { authorization: `Bearer ${token}` },
    })
    const first = await (await me(accountBearer)).json() as { user: { id: string; isAnonymous: boolean }; merged: unknown }
    expect(first.user).toMatchObject({ id: account.id, isAnonymous: false })
    expect(first.merged).toBe('all')
    const second = await (await me(accountBearer)).json() as { merged: unknown }
    expect(second.merged).toBeNull()
  })

  it('fails the sign-in and keeps the anonymous user when the link throws', async () => {
    const breakTransactions = { on: false }
    const { db, auth } = await setup({ breakTransactions })
    const logged = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const anonRes = await post(auth, '/sign-in/anonymous', {})
    const anonBearer = anonRes.headers.get('set-auth-token')!
    const { user: anon } = await anonRes.json() as { user: { id: string } }
    const [mix] = await db.insert(djSessions).values({ userId: anon.id, title: 'Keep me' }).returning()

    breakTransactions.on = true
    const social = await post(auth, '/sign-in/social', {
      provider: 'google', idToken: { token: 'fake-google-id-token' },
    }, anonBearer)

    expect(social.status).not.toBe(200)
    expect(logged).toHaveBeenCalledWith('anonymous account link failed', 'Error', '40001')
    expect(await db.select().from(user).where(eq(user.id, anon.id))).toHaveLength(1)
    const [kept] = await db.select().from(djSessions).where(eq(djSessions.id, mix!.id))
    expect(kept?.userId).toBe(anon.id)
  })

  it('reports mixes_only when the account already had a library', async () => {
    const { db, auth, app } = await setup()
    // First sign-in creates the account; give it a library.
    const firstSocial = await post(auth, '/sign-in/social', {
      provider: 'google', idToken: { token: 'fake-google-id-token' },
    })
    expect(firstSocial.status).toBe(200)
    const { user: account } = await firstSocial.json() as { user: { id: string } }
    await db.insert(userMusicSources).values({ userId: account.id, source: 'apple_live' })

    const anonRes = await post(auth, '/sign-in/anonymous', {})
    const anonBearer = anonRes.headers.get('set-auth-token')!
    const { user: anon } = await anonRes.json() as { user: { id: string } }
    const [mix] = await db.insert(djSessions).values({ userId: anon.id, title: 'Second device' }).returning()

    const social = await post(auth, '/sign-in/social', {
      provider: 'google', idToken: { token: 'fake-google-id-token' },
    }, anonBearer)
    expect(social.status).toBe(200)
    const accountBearer = social.headers.get('set-auth-token')!

    const [moved] = await db.select().from(djSessions).where(eq(djSessions.id, mix!.id))
    expect(moved?.userId).toBe(account.id)
    const body = await (await app.request('http://localhost:8787/me', {
      headers: { authorization: `Bearer ${accountBearer}` },
    })).json() as { merged: unknown }
    expect(body.merged).toBe('mixes_only')
  })

  it('gives an anonymous session a 30-day life, since the listener has no way to sign back in', async () => {
    const { db, auth } = await setup()
    const anonRes = await post(auth, '/sign-in/anonymous', {})
    const { user: anon } = await anonRes.json() as { user: { id: string } }
    const [row] = await db.select().from(session).where(eq(session.userId, anon.id))
    const lifeMs = row!.expiresAt.getTime() - row!.createdAt.getTime()
    expect(Math.abs(lifeMs - 30 * 24 * 3_600_000)).toBeLessThan(60_000)
  })

  it('reports merged null on /me for a session that did not come from a link', async () => {
    const { auth, app } = await setup()
    const anonRes = await post(auth, '/sign-in/anonymous', {})
    const anonBearer = anonRes.headers.get('set-auth-token')!
    const body = await (await app.request('http://localhost:8787/me', {
      headers: { authorization: `Bearer ${anonBearer}` },
    })).json() as { merged: unknown }
    expect(body.merged).toBeNull()
  })
})
