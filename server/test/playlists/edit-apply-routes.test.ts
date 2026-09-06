import { asc, eq } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { createApp, type AuthLike } from '../../src/app'
import {
  playlistEditDraftEvents,
  playlistEditDrafts,
  playlistEntries,
  playlistOrigins,
  tracks,
  user,
  userPlaylists,
} from '../../src/db/schema'
import { desiredPlaylistFingerprint } from '../../src/playlist-editing/apply'
import { createPlaylistEditDraftStore } from '../../src/playlist-editing/store'
import { createTestDb, type TestDb } from '../helpers/db'

const SOURCE_FINGERPRINT = 'a'.repeat(64)
const authFor = (id: string | null): AuthLike => ({
  handler: () => new Response('ok'),
  api: { getSession: async () => id ? { user: { id } } : null },
})

function request(
  db: TestDb,
  userId: string | null,
  path: string,
  body: unknown,
) {
  return createApp({ db, auth: authFor(userId) }).request(`http://x${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function seedChangedDraft(db: TestDb, options: { unresolved?: boolean } = {}) {
  await db.insert(user).values({ id: 'u1', name: 'User', email: 'u1@example.com' })
  await db.insert(user).values({ id: 'u2', name: 'Other', email: 'u2@example.com' })
  const [playlist] = await db.insert(userPlaylists).values({
    userId: 'u1',
    appleLibraryId: 'source-playlist',
    name: 'Night Bus Notes',
    kind: 'user',
    sourceFingerprint: SOURCE_FINGERPRINT,
  }).returning()
  const seeded = await db.insert(tracks).values([
    { appleId: 'apple-a', title: 'A', artist: 'Artist' },
    { appleId: 'apple-b', title: 'B', artist: 'Artist' },
    { appleId: 'apple-c', title: 'C', artist: 'Artist' },
  ]).returning()
  await db.insert(playlistEntries).values([
    {
      playlistId: playlist.id,
      position: 0,
      trackId: seeded[0].id,
      appleLibraryEntryId: 'entry-a',
      appleCatalogId: 'apple-a',
      titleSnapshot: 'A',
      artistSnapshot: 'Artist',
    },
    {
      playlistId: playlist.id,
      position: 1,
      trackId: options.unresolved ? null : seeded[1].id,
      appleLibraryEntryId: 'entry-b',
      appleCatalogId: options.unresolved ? null : 'apple-b',
      titleSnapshot: 'B',
      artistSnapshot: 'Artist',
    },
  ])
  const created = await createPlaylistEditDraftStore(db).createOrResume('u1', playlist.id)
  if (created.kind !== 'ok') throw new Error('draft seed failed')
  const changed = await createPlaylistEditDraftStore(db).mutate(
    'u1',
    created.view.draft.id,
    0,
    [{ type: 'add', trackId: seeded[2].id, afterEntryKey: created.view.entries[0].entryKey }],
  )
  if (changed.kind !== 'ok') throw new Error('draft mutation failed')
  return { playlist, draft: changed.view }
}

const prepareBody = {
  expectedVersion: 1,
  currentSourceFingerprint: SOURCE_FINGERPRINT,
  clientCapabilities: {
    revisedCopy: true,
    append: false,
    rebuildReceiptClasses: [],
  },
}

describe('playlist revised-copy apply routes', () => {
  it('prepares one immutable ordered plan and reuses it for the draft version', async () => {
    const db = await createTestDb()
    const { draft } = await seedChangedDraft(db)
    const path = `/playlist-edit-drafts/${draft.draft.id}/prepare-apply`

    const first = await request(db, 'u1', path, prepareBody)
    expect(first.status).toBe(200)
    const plan = await first.json() as any
    expect(plan).toMatchObject({
      mode: 'revised_copy',
      draftVersion: 1,
      name: 'Night Bus Notes (mixtape revision)',
      description: 'revised with mixtape',
      appleCatalogIds: ['apple-a', 'apple-c', 'apple-b'],
      sourceWillRemainUntouched: true,
    })
    expect(plan.operationId).toMatch(/^[0-9a-f-]{36}$/)
    expect(plan.desiredFingerprint).toBe(
      await desiredPlaylistFingerprint(['apple-a', 'apple-c', 'apple-b']),
    )
    expect(new Date(plan.expiresAt).getTime()).toBeGreaterThan(Date.now())

    const repeated = await request(db, 'u1', path, prepareBody)
    expect(repeated.status).toBe(200)
    expect((await repeated.json() as any).operationId).toBe(plan.operationId)
    await db.update(playlistEditDrafts).set({
      preparedExpiresAt: new Date('2000-01-01T00:00:00.000Z'),
    })
    const renewed = await request(db, 'u1', path, prepareBody)
    expect(renewed.status).toBe(200)
    const renewedPlan = await renewed.json() as any
    expect(renewedPlan.operationId).toBe(plan.operationId)
    expect(new Date(renewedPlan.expiresAt).getTime()).toBeGreaterThan(Date.now())
    const [stored] = await db.select().from(playlistEditDrafts)
    expect(stored).toMatchObject({ status: 'ready', requestedApplyMode: 'revised_copy' })
  })

  it('blocks stale sources, unresolved copies, unsupported clients, and stale versions', async () => {
    const staleDb = await createTestDb()
    const stale = await seedChangedDraft(staleDb)
    const stalePath = `/playlist-edit-drafts/${stale.draft.draft.id}/prepare-apply`
    expect((await request(staleDb, 'u1', stalePath, {
      ...prepareBody,
      currentSourceFingerprint: 'b'.repeat(64),
    })).status).toBe(409)
    expect((await staleDb.select().from(playlistEditDrafts))[0].status).toBe('conflicted')

    const unresolvedDb = await createTestDb()
    const unresolved = await seedChangedDraft(unresolvedDb, { unresolved: true })
    const unresolvedResponse = await request(
      unresolvedDb,
      'u1',
      `/playlist-edit-drafts/${unresolved.draft.draft.id}/prepare-apply`,
      prepareBody,
    )
    expect(unresolvedResponse.status).toBe(409)
    expect(await unresolvedResponse.json()).toMatchObject({ error: 'apply_blocked', unresolved: 1 })

    const unsupportedDb = await createTestDb()
    const unsupported = await seedChangedDraft(unsupportedDb)
    const unsupportedPath = `/playlist-edit-drafts/${unsupported.draft.draft.id}/prepare-apply`
    expect((await request(unsupportedDb, 'u1', unsupportedPath, {
      ...prepareBody,
      clientCapabilities: { ...prepareBody.clientCapabilities, revisedCopy: false },
    })).status).toBe(409)
    expect((await request(unsupportedDb, 'u1', unsupportedPath, {
      ...prepareBody,
      expectedVersion: 0,
    })).status).toBe(409)
    expect((await request(unsupportedDb, 'u2', unsupportedPath, prepareBody)).status).toBe(404)
  })

  it('confirms once, records ownership, and never duplicates apply evidence', async () => {
    const db = await createTestDb()
    const { draft } = await seedChangedDraft(db)
    const prepare = await request(
      db,
      'u1',
      `/playlist-edit-drafts/${draft.draft.id}/prepare-apply`,
      prepareBody,
    )
    const plan = await prepare.json() as any
    const confirmation = {
      operationId: plan.operationId,
      expectedVersion: 1,
      appliedMode: 'revised_copy',
      applePlaylistLibraryId: 'p.revised-copy',
      resultingFingerprint: plan.desiredFingerprint,
    }
    const path = `/playlist-edit-drafts/${draft.draft.id}/confirm-apply`

    const first = await request(db, 'u1', path, confirmation)
    expect(first.status).toBe(200)
    expect(await first.json()).toMatchObject({
      status: 'applied',
      mode: 'revised_copy',
      applePlaylistLibraryId: 'p.revised-copy',
      sourceWillRemainUntouched: true,
    })
    expect((await request(db, 'u1', path, confirmation)).status).toBe(200)

    expect(await db.select().from(playlistOrigins)).toEqual([
      expect.objectContaining({
        userId: 'u1',
        source: 'apple',
        libraryId: 'p.revised-copy',
        origin: 'mixtape',
      }),
    ])
    const applyEvents = await db.select().from(playlistEditDraftEvents)
      .where(eq(playlistEditDraftEvents.kind, 'apply'))
      .orderBy(asc(playlistEditDraftEvents.createdAt))
    expect(applyEvents).toHaveLength(1)
    expect((await db.select().from(playlistEditDrafts))[0]).toMatchObject({
      status: 'applied',
      appliedPlaylistLibraryId: 'p.revised-copy',
      appliedPlaylistSource: 'apple',
    })
  })

  it('rejects a foreign, mismatched, or malformed confirmation without writing a receipt', async () => {
    const db = await createTestDb()
    const { draft } = await seedChangedDraft(db)
    const prepared = await request(
      db,
      'u1',
      `/playlist-edit-drafts/${draft.draft.id}/prepare-apply`,
      prepareBody,
    )
    const plan = await prepared.json() as any
    const path = `/playlist-edit-drafts/${draft.draft.id}/confirm-apply`
    const valid = {
      operationId: plan.operationId,
      expectedVersion: 1,
      appliedMode: 'revised_copy',
      applePlaylistLibraryId: 'p.revised-copy',
      resultingFingerprint: plan.desiredFingerprint,
    }
    expect((await request(db, 'u2', path, valid)).status).toBe(404)
    expect((await request(db, 'u1', path, {
      ...valid,
      resultingFingerprint: 'c'.repeat(64),
    })).status).toBe(409)
    expect((await request(db, 'u1', path, { ...valid, applePlaylistLibraryId: 'bad/id' })).status)
      .toBe(400)
    expect(await db.select().from(playlistOrigins)).toHaveLength(0)
    expect((await db.select().from(playlistEditDrafts))[0].status).toBe('ready')
  })
})
