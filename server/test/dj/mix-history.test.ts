import { it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import {
  user,
  tracks,
  djSessions,
  queueTracks,
  mixVersions,
  trackFeatures,
} from '../../src/db/schema'
import {
  replaceQueue,
  applyOps,
  getActiveQueue,
} from '../../src/dj/queue-store'
import {
  listMixVersions,
  readMixVersion,
  restoreMixVersion,
  MixHistoryError,
} from '../../src/dj/mix-history'

async function setup() {
  const db = await createTestDb()
  await db
    .insert(user)
    .values({
      id: 'owner',
      name: 'Owner',
      email: 'owner@example.test',
      emailVerified: false,
    })
  const [session] = await db
    .insert(djSessions)
    .values({ userId: 'owner', title: 'Sunday' })
    .returning()
  const songs = await db
    .insert(tracks)
    .values(
      ['One', 'Two', 'Three'].map((title, i) => ({
        title,
        artist: 'Test artist',
        appleId: String(i + 1),
      })),
    )
    .returning()
  return { db, session, songs }
}
it('keeps ordered versions and restores as a new version without removal signals', async () => {
  const { db, session, songs } = await setup()
  await replaceQueue(
    db,
    session.id,
    songs.slice(0, 2).map((s) => ({ trackId: s.id, reason: 'first' })),
    'dj',
  )
  await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')
  const before = await db
    .select()
    .from(queueTracks)
    .where(eq(queueTracks.state, 'removed'))
  const v1 = await readMixVersion(db, session.id, 'owner', 1)
  expect(v1.entries.map((e) => e.trackId)).toEqual(
    songs.slice(0, 2).map((s) => s.id),
  )
  const result = await restoreMixVersion(db, session.id, 'owner', {
    version: 1,
    expectedVersion: 2,
    requestId: 'restore-once',
  })
  expect(result.version).toBe(3)
  expect((await getActiveQueue(db, session.id)).map((t) => t.trackId)).toEqual(
    songs.slice(0, 2).map((s) => s.id),
  )
  expect(
    await db.select().from(queueTracks).where(eq(queueTracks.state, 'removed')),
  ).toEqual(before)
  expect(
    (await listMixVersions(db, session.id, 'owner')).versions.map(
      (v) => v.version,
    ),
  ).toEqual([3, 2, 1])
  expect(
    await restoreMixVersion(db, session.id, 'owner', {
      version: 1,
      expectedVersion: 2,
      requestId: 'restore-once',
    }),
  ).toEqual(result)
  await expect(
    restoreMixVersion(db, session.id, 'owner', {
      version: 2,
      expectedVersion: 3,
      requestId: 'restore-once',
    }),
  ).rejects.toMatchObject({ kind: 'conflict' })
})
it('rejects stale restore and foreign access without changing history', async () => {
  const { db, session, songs } = await setup()
  await replaceQueue(
    db,
    session.id,
    [{ trackId: songs[0].id, reason: 'first' }],
    'dj',
  )
  await expect(
    restoreMixVersion(db, session.id, 'owner', {
      version: 1,
      expectedVersion: 0,
      requestId: 'stale',
    }),
  ).rejects.toMatchObject({ kind: 'conflict' })
  await expect(listMixVersions(db, session.id, 'other')).rejects.toMatchObject({
    kind: 'not_found',
  })
  await expect(
    readMixVersion(db, session.id, 'other', 1),
  ).rejects.toMatchObject({ kind: 'not_found' })
  await expect(
    restoreMixVersion(db, session.id, 'other', {
      version: 1,
      expectedVersion: 1,
      requestId: 'foreign',
    }),
  ).rejects.toBeInstanceOf(MixHistoryError)
  expect((await db.select().from(mixVersions)).length).toBe(1)
})
it('captures only the current legacy version, including an empty mix', async () => {
  const { db, session, songs } = await setup()
  await db
    .update(djSessions)
    .set({ queueVersion: 7 })
    .where(eq(djSessions.id, session.id))
  await db
    .insert(queueTracks)
    .values({
      sessionId: session.id,
      position: 0,
      trackId: songs[0].id,
      addedBy: 'dj',
    })
  expect(
    (await listMixVersions(db, session.id, 'owner')).versions.map(
      (v) => v.version,
    ),
  ).toEqual([7])
  await applyOps(db, session.id, [{ op: 'remove', position: 0 }], 'user')
  expect(
    (await readMixVersion(db, session.id, 'owner', 7)).entries,
  ).toHaveLength(1)
  expect(
    (await readMixVersion(db, session.id, 'owner', 8)).entries,
  ).toHaveLength(0)
  await expect(
    readMixVersion(db, session.id, 'owner', 6),
  ).rejects.toMatchObject({ kind: 'not_found' })
})
it('rolls back restore if a historical recording no longer exists', async () => {
  const { db, session, songs } = await setup()
  await replaceQueue(
    db,
    session.id,
    [{ trackId: songs[0].id, reason: 'first' }],
    'dj',
  )
  await replaceQueue(
    db,
    session.id,
    [{ trackId: songs[1].id, reason: 'second' }],
    'dj',
  )
  await db.delete(tracks).where(eq(tracks.id, songs[0].id))
  await expect(
    restoreMixVersion(db, session.id, 'owner', {
      version: 1,
      expectedVersion: 2,
      requestId: 'missing',
    }),
  ).rejects.toMatchObject({ kind: 'unavailable' })
  expect((await getActiveQueue(db, session.id))[0].trackId).toBe(songs[1].id)
  expect((await db.select().from(mixVersions)).length).toBe(2)
  await db.delete(djSessions).where(eq(djSessions.id, session.id))
  expect(await db.select().from(mixVersions)).toHaveLength(0)
})

it('snapshots journey intent and assessment, carries it across edits, restores it unchanged', async () => {
  const { db, session, songs } = await setup()
  await replaceQueue(db, session.id, songs.map(s => ({trackId:s.id,reason:'chosen'})), 'dj', undefined, 'rise')
  const first = await readMixVersion(db, session.id, 'owner', 1)
  expect(first).toMatchObject({energyArc:'rise',energyJourney:{status:'limited',known:0,total:3,bands:null}})
  await applyOps(db, session.id, [{op:'move',from:0,to:2}], 'user')
  expect(await readMixVersion(db, session.id, 'owner', 2)).toMatchObject({energyArc:'rise',energyJourney:first.energyJourney})
  await applyOps(db, session.id, [{op:'move',from:2,to:0}], 'dj', undefined, undefined, undefined, 'fall')
  expect(await readMixVersion(db, session.id, 'owner', 3)).toMatchObject({energyArc:'fall'})
  await restoreMixVersion(db,session.id,'owner',{version:1,expectedVersion:3,requestId:'journey-restore'})
  expect(await readMixVersion(db,session.id,'owner',4)).toMatchObject({energyArc:'rise',energyJourney:first.energyJourney})
  await replaceQueue(db, session.id, [], 'dj', undefined, null)
  expect(await readMixVersion(db,session.id,'owner',5)).toMatchObject({energyArc:null,energyJourney:null})
})

 it('measures committed positions and never rewrites a historical assessment after enrichment', async () => {
  const {db, session} = await setup()
  const songs = await db.insert(tracks).values(Array.from({length:6},(_,i)=>({title:`Energy ${i}`,artist:'Test',appleId:`energy-${i}`}))).returning()
  await db.insert(trackFeatures).values(songs.map((s,i)=>({trackId:s.id,energy:[.1,.2,.4,.5,.8,.9][i],source:'test'})))
  await replaceQueue(db,session.id,songs.map(s=>({trackId:s.id,reason:'chosen'})),'dj',undefined,'rise')
  const first = await readMixVersion(db,session.id,'owner',1)
  expect(first.energyJourney).toMatchObject({status:'follows',known:6,total:6})
  await db.update(trackFeatures).set({energy:null})
  await applyOps(db,session.id,[{op:'move',from:0,to:5}],'user')
  expect((await readMixVersion(db,session.id,'owner',2)).energyJourney?.status).toBe('limited')
  expect((await readMixVersion(db,session.id,'owner',1)).energyJourney).toEqual(first.energyJourney)
 })
