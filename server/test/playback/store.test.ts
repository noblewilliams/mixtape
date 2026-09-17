import { it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { user, djSessions, tracks, playbackEvidence } from '../../src/db/schema'
import { replaceQueue } from '../../src/dj/queue-store'
import {
  playbackPreferences,
  savePlaybackPreference,
  clearPlaybackEvidence,
  ingestPlayback,
} from '../../src/playback/store'
async function setup() {
  const db = await createTestDb()
  await db
    .insert(user)
    .values({ id: 'u', name: 'U', email: 'u@test.test', emailVerified: false })
  const [s] = await db
    .insert(djSessions)
    .values({ userId: 'u', title: 'Mix' })
    .returning()
  const [t] = await db
    .insert(tracks)
    .values({
      title: 'Song',
      artist: 'Artist',
      appleId: '123',
      durationMs: 200000,
    })
    .returning()
  await replaceQueue(db, s.id, [{ trackId: t.id, reason: 'chosen' }], 'dj')
  return {
    db,
    s,
    t,
    event: {
      playbackId: crypto.randomUUID(),
      sequence: 0,
      sessionId: s.id,
      version: 1,
      position: 0,
      trackId: t.id,
      source: 'apple_native' as const,
      observedMs: 90000,
      kind: 'listen' as const,
      occurredAt: new Date().toISOString(),
    },
  }
}
it('requires consent, accepts exact retries once and rejects stale evidence after clear', async () => {
  const { db, event } = await setup()
  expect(await playbackPreferences(db, 'u')).toMatchObject({
    enabled: false,
    revision: 0,
  })
  await expect(
    ingestPlayback(db, 'u', { revision: 0, events: [event] }),
  ).rejects.toThrow()
  const prefs = await savePlaybackPreference(db, 'u', true)
  await ingestPlayback(db, 'u', {
    revision: prefs.revision,
    events: [event, event],
  })
  expect(await db.select().from(playbackEvidence)).toHaveLength(1)
  const clear = await clearPlaybackEvidence(db, 'u', 'clear-1')
  expect(await clearPlaybackEvidence(db, 'u', 'clear-1')).toEqual(clear)
  await expect(
    ingestPlayback(db, 'u', { revision: prefs.revision, events: [event] }),
  ).rejects.toThrow()
  expect(await db.select().from(playbackEvidence)).toHaveLength(0)
})
it('rejects forged track positions, foreign sessions and impossible observation lengths atomically', async () => {
  const { db, event } = await setup()
  const prefs = await savePlaybackPreference(db, 'u', true)
  for (const patch of [
    { position: 1 },
    { observedMs: 900000 },
    { trackId: crypto.randomUUID() },
  ]) {
    await expect(
      ingestPlayback(db, 'u', {
        revision: prefs.revision,
        events: [event, { ...event, sequence: 1, ...patch }],
      }),
    ).rejects.toThrow()
    expect(await db.select().from(playbackEvidence)).toHaveLength(0)
  }
  await db
    .insert(user)
    .values({
      id: 'other',
      name: 'O',
      email: 'o@test.test',
      emailVerified: false,
    })
  const other = await savePlaybackPreference(db, 'other', true)
  await expect(
    ingestPlayback(db, 'other', { revision: other.revision, events: [event] }),
  ).rejects.toThrow()
})
it('switching off preserves evidence but disables collection; account deletion cascades', async () => {
  const { db, event } = await setup()
  const prefs = await savePlaybackPreference(db, 'u', true)
  await ingestPlayback(db, 'u', { revision: prefs.revision, events: [event] })
  await savePlaybackPreference(db, 'u', false)
  await expect(
    ingestPlayback(db, 'u', { revision: prefs.revision, events: [event] }),
  ).rejects.toThrow()
  expect(await db.select().from(playbackEvidence)).toHaveLength(1)
  await db.delete(user).where(eq(user.id, 'u'))
  expect(await db.select().from(playbackEvidence)).toHaveLength(0)
})
it('does not let an older clear erase evidence from a newer preference epoch', async () => {
  const { db, event } = await setup()
  const first = await savePlaybackPreference(db, 'u', true)
  await clearPlaybackEvidence(db, 'u', 'clear-first', first.revision)
  const now = await playbackPreferences(db, 'u')
  await ingestPlayback(db, 'u', { revision: now.revision, events: [event] })
  await expect(
    clearPlaybackEvidence(db, 'u', 'stale-clear', first.revision),
  ).rejects.toThrow()
  expect(await db.select().from(playbackEvidence)).toHaveLength(1)
})
