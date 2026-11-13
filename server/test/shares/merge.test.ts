import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { randomUUID } from 'node:crypto'
import { createTestDb, type TestDb } from '../helpers/db'
import { linkAnonymousRows } from '../../src/auth/link-anonymous'
import { djSessions, funnelEvents, mixShares, mixShareSaves, user, userMusicSources } from '../../src/db/schema'
import { generateShareToken } from '../../src/shares/store'

// Spec 2026-11-13 shared-mixes → Merging and deletion, plan task S3: saves
// move to the account (skipping one it already has) and shares move with
// their sessions.

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

async function makeShare(db: TestDb, sharerId: string) {
  const [session] = await db.insert(djSessions).values({ userId: sharerId, title: 'Mix' }).returning()
  const [share] = await db
    .insert(mixShares)
    .values({
      token: generateShareToken(),
      sessionId: session!.id,
      sharerId,
      queueVersion: session!.queueVersion,
      title: 'Mix',
      caseColor: '#b84755',
      entries: [{ position: 0, trackId: randomUUID() }],
    })
    .returning()
  return { sessionId: session!.id, shareId: share!.id }
}

async function savesOf(db: TestDb, userId: string) {
  return (await db.select().from(mixShareSaves).where(eq(mixShareSaves.userId, userId)))
    .map((s) => s.shareId)
    .sort()
}

async function sharerOf(db: TestDb, shareId: string) {
  const [row] = await db.select({ sharerId: mixShares.sharerId }).from(mixShares).where(eq(mixShares.id, shareId))
  return row?.sharerId
}

async function world(db: TestDb, opts: { accountHasData: boolean }) {
  const anon = await makeUser(db, { anonymous: true })
  const account = await makeUser(db, { anonymous: false })
  const friend = await makeUser(db, { anonymous: false })
  if (opts.accountHasData) await db.insert(userMusicSources).values({ userId: account, source: 'apple_live' })
  // The anonymous listener's own shared mix.
  const anonShare = await makeShare(db, anon)
  // Two friend shares: the anonymous listener saved both, the account one.
  const onlyAnon = await makeShare(db, friend)
  const both = await makeShare(db, friend)
  const savedAt = new Date('2026-11-01T10:00:00Z')
  await db.insert(mixShareSaves).values([
    { userId: anon, shareId: onlyAnon.shareId, savedAt },
    { userId: anon, shareId: both.shareId, savedAt },
    { userId: account, shareId: both.shareId, savedAt: new Date('2026-10-01T10:00:00Z') },
  ])
  return { anon, account, friend, anonShare, onlyAnon, both }
}

describe('linkAnonymousRows and shared mixes', () => {
  for (const accountHasData of [false, true]) {
    const mode = accountHasData ? 'mixes_only' : 'all'
    it(`moves saves, de-duplicates them and moves shares with their sessions (mode ${mode})`, async () => {
      const db = await createTestDb()
      const w = await world(db, { accountHasData })

      const result = await linkAnonymousRows(db, { anonymousUserId: w.anon, newUserId: w.account })
      expect(result).toEqual({ mode })

      expect(await savesOf(db, w.account)).toEqual([w.onlyAnon.shareId, w.both.shareId].sort())
      expect(await savesOf(db, w.anon)).toEqual([])
      // The account's own save of the shared one wins (its savedAt is kept).
      const [kept] = await db.select().from(mixShareSaves)
        .where(eq(mixShareSaves.shareId, w.both.shareId))
      expect(kept!.savedAt.toISOString()).toBe('2026-10-01T10:00:00.000Z')

      expect(await sharerOf(db, w.anonShare.shareId)).toBe(w.account)
      const [session] = await db.select().from(djSessions).where(eq(djSessions.id, w.anonShare.sessionId))
      expect(session!.userId).toBe(w.account)
      expect(await db.select().from(mixShares).where(eq(mixShares.sharerId, w.anon))).toEqual([])

      // The plugin then deletes the anonymous user: nothing moved goes with it.
      await db.delete(user).where(eq(user.id, w.anon))
      expect(await savesOf(db, w.account)).toEqual([w.onlyAnon.shareId, w.both.shareId].sort())
      expect(await sharerOf(db, w.anonShare.shareId)).toBe(w.account)
    })
  }

  it('moves saves on their own, without a merge notice or funnel event', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const account = await makeUser(db, { anonymous: false })
    const friend = await makeUser(db, { anonymous: false })
    await db.insert(djSessions).values({ userId: account, title: 'own' })
    const { shareId } = await makeShare(db, friend)
    await db.insert(mixShareSaves).values({ userId: anon, shareId })

    expect(await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: account })).toEqual({ mode: 'none' })
    expect(await savesOf(db, account)).toEqual([shareId])
    expect(await savesOf(db, anon)).toEqual([])
    expect(await db.select().from(funnelEvents).where(eq(funnelEvents.userId, account))).toEqual([])
  })

  it('drops a save of the account\'s own share rather than moving it', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const account = await makeUser(db, { anonymous: false })
    const { shareId } = await makeShare(db, account)
    await db.insert(mixShareSaves).values({ userId: anon, shareId })

    await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: account })
    expect(await db.select().from(mixShareSaves)).toEqual([])
  })

  it('drops the account\'s save of a share that moves to it', async () => {
    const db = await createTestDb()
    const anon = await makeUser(db, { anonymous: true })
    const account = await makeUser(db, { anonymous: false })
    const { shareId } = await makeShare(db, anon)
    await db.insert(mixShareSaves).values({ userId: account, shareId })

    await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: account })
    expect(await sharerOf(db, shareId)).toBe(account)
    expect(await db.select().from(mixShareSaves)).toEqual([])
  })
})

// The name an anonymous listener typed on the Share name page: shares made
// before sign-up already show it, so the account keeps it unless the
// provider gave a usable one.
describe('linkAnonymousRows and the anonymous listener\'s name', () => {
  async function names(db: TestDb, accountName: string, anonName: string) {
    const anon = await makeUser(db, { anonymous: true })
    const account = await makeUser(db, { anonymous: false })
    await db.update(user).set({ name: anonName, namePromptedAt: new Date('2026-11-10T10:00:00Z') }).where(eq(user.id, anon))
    await db.update(user).set({ name: accountName }).where(eq(user.id, account))
    await linkAnonymousRows(db, { anonymousUserId: anon, newUserId: account })
    const [row] = await db.select({ name: user.name, namePromptedAt: user.namePromptedAt }).from(user).where(eq(user.id, account))
    return row!
  }

  it('copies the name to an account with none, and marks the name page answered', async () => {
    const db = await createTestDb()
    const row = await names(db, '', 'Ada')
    expect(row.name).toBe('Ada')
    expect(row.namePromptedAt).not.toBeNull()
  })

  it('copies it over an account named Listener', async () => {
    const db = await createTestDb()
    expect((await names(db, 'Listener', 'Ada')).name).toBe('Ada')
  })

  it('keeps a usable provider name', async () => {
    const db = await createTestDb()
    const row = await names(db, 'Tolu Ade', 'Ada')
    expect(row.name).toBe('Tolu Ade')
    expect(row.namePromptedAt).toBeNull()
  })

  it('never copies the anonymous placeholder', async () => {
    const db = await createTestDb()
    const row = await names(db, '', 'Listener')
    expect(row.name).toBe('')
    expect(row.namePromptedAt).toBeNull()
  })
})
