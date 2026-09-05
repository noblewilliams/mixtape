import { eq, sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import {
  playlistEditDraftEntries,
  playlistEditDraftEvents,
  playlistEditDrafts,
  playlistEntries,
  tracks,
  user,
  userPlaylists,
} from '../../src/db/schema'
import { createTestDb, type TestDb } from '../helpers/db'

async function seed(db: TestDb) {
  await db.insert(user).values({ id: 'u1', name: 'User', email: 'u1@example.com' })
  const [playlist] = await db.insert(userPlaylists).values({
    userId: 'u1',
    appleLibraryId: 'playlist',
    name: 'Playlist',
    kind: 'user',
    sourceFingerprint: 'a'.repeat(64),
  }).returning()
  const [entry] = await db.insert(playlistEntries).values({
    playlistId: playlist.id,
    position: 0,
    appleLibraryEntryId: 'entry',
    titleSnapshot: 'Song',
    artistSnapshot: 'Artist',
  }).returning()
  const [draft] = await db.insert(playlistEditDrafts).values({
    userId: 'u1',
    sourcePlaylistId: playlist.id,
    baseSourceFingerprint: playlist.sourceFingerprint,
    baseName: playlist.name,
    sourceType: 'apple',
  }).returning()
  return { playlist, entry, draft }
}

describe('playlist edit draft schema', () => {
  it('allows one resumable draft and a new one after abandonment', async () => {
    const db = await createTestDb()
    const { playlist, draft } = await seed(db)
    const value = {
      userId: 'u1',
      sourcePlaylistId: playlist.id,
      baseSourceFingerprint: playlist.sourceFingerprint,
      baseName: playlist.name,
      sourceType: 'apple' as const,
    }
    await expect(db.insert(playlistEditDrafts).values(value)).rejects.toThrow()
    await db.update(playlistEditDrafts).set({ status: 'abandoned' })
      .where(eq(playlistEditDrafts.id, draft.id))
    await expect(db.insert(playlistEditDrafts).values(value)).resolves.toBeDefined()
  })

  it.each([
    { version: -1 },
    { baseSourceFingerprint: 'not-a-fingerprint' },
    { sourceType: 'unknown' },
    { status: 'deleted' },
    { requestedApplyMode: 'append' },
  ])('rejects invalid or incomplete draft state: %j', async (over) => {
    const db = await createTestDb()
    const { playlist, draft } = await seed(db)
    await db.update(playlistEditDrafts).set({ status: 'abandoned' })
      .where(eq(playlistEditDrafts.id, draft.id))
    await expect(db.insert(playlistEditDrafts).values({
      userId: 'u1',
      sourcePlaylistId: playlist.id,
      baseSourceFingerprint: playlist.sourceFingerprint,
      baseName: playlist.name,
      sourceType: 'apple',
      ...(over as object),
    })).rejects.toThrow()
  })

  it('preserves duplicate tracks with unique occurrence keys in both roles', async () => {
    const db = await createTestDb()
    const { entry, draft } = await seed(db)
    const [track] = await db.insert(tracks).values({
      appleId: 'song', title: 'Song', artist: 'Artist',
    }).returning()
    const keyA = crypto.randomUUID()
    const keyB = crypto.randomUUID()
    await db.insert(playlistEditDraftEntries).values([
      { draftId: draft.id, role: 'base', entryKey: keyA, position: 0,
        origin: 'source', sourceEntryId: entry.id, trackId: track.id,
        titleSnapshot: 'Song', artistSnapshot: 'Artist' },
      { draftId: draft.id, role: 'draft', entryKey: keyA, position: 0,
        origin: 'source', sourceEntryId: entry.id, trackId: track.id,
        titleSnapshot: 'Song', artistSnapshot: 'Artist' },
      { draftId: draft.id, role: 'draft', entryKey: keyB, position: 1,
        origin: 'catalog_addition', trackId: track.id,
        titleSnapshot: 'Song', artistSnapshot: 'Artist' },
    ])
    expect(await db.select().from(playlistEditDraftEntries)).toHaveLength(3)
    await expect(db.insert(playlistEditDraftEntries).values({
      draftId: draft.id, role: 'draft', entryKey: keyB, position: 2,
      origin: 'source', titleSnapshot: 'Dup key', artistSnapshot: 'Artist',
    })).rejects.toThrow()
    await expect(db.insert(playlistEditDraftEntries).values({
      draftId: draft.id, role: 'draft', entryKey: crypto.randomUUID(), position: 1,
      origin: 'source', titleSnapshot: 'Dup position', artistSnapshot: 'Artist',
    })).rejects.toThrow()
  })

  it('enforces entry and event value constraints', async () => {
    const db = await createTestDb()
    const { draft } = await seed(db)
    await expect(db.insert(playlistEditDraftEntries).values({
      draftId: draft.id, role: 'draft', entryKey: crypto.randomUUID(), position: -1,
      origin: 'source', titleSnapshot: 'Song', artistSnapshot: 'Artist',
    })).rejects.toThrow()
    await expect(db.insert(playlistEditDraftEntries).values({
      draftId: draft.id, role: 'draft', entryKey: crypto.randomUUID(), position: 0,
      origin: 'source', titleSnapshot: 'Song', artistSnapshot: 'Artist',
      artworkBgColorSnapshot: '#ffffff',
    })).rejects.toThrow()
    await expect(db.insert(playlistEditDraftEvents).values({
      draftId: draft.id, version: 0, kind: 'add', entryKey: crypto.randomUUID(),
    })).rejects.toThrow()
  })

  it('indexes every foreign-key access path', async () => {
    const db = await createTestDb()
    const result = await db.execute(sql`
      SELECT indexname FROM pg_indexes
      WHERE schemaname = 'public' AND indexname IN (
        'playlist_edit_drafts_source_idx',
        'playlist_edit_entries_draft_role_position_idx',
        'playlist_edit_entries_source_entry_idx',
        'playlist_edit_entries_track_idx',
        'playlist_edit_events_draft_version_idx',
        'playlist_edit_events_track_idx'
      )
      ORDER BY indexname
    `)
    const rows = Array.isArray(result) ? result : result.rows
    expect(rows).toHaveLength(6)
  })
})
