import { describe, expect, it } from 'vitest'
import { user, tracks, trackFeatures, userTracks, userPlaylists, playlistEntries } from '../../src/db/schema'
import { buildPool } from '../../src/dj/pool'
import { MAX_PROFILE_RECORDINGS, MAX_PROFILE_RECORDINGS_PER_ARTIST, MIN_PROFILE_RECORDINGS } from '../../src/playlists/seed'
import { createTestDb } from '../helpers/db'

const embedding = async () => Array(1024).fill(0)

describe('playlist-inspired candidate ranking', () => {
  it('pins the bounded profile contract', () => {
    expect({ minimum: MIN_PROFILE_RECORDINGS, total: MAX_PROFILE_RECORDINGS,
      perArtist: MAX_PROFILE_RECORDINGS_PER_ARTIST }).toEqual({ minimum: 3, total: 200, perArtist: 5 })
  })

  it('changes pre-limit ranking without admitting non-candidates and can exclude every source recording', async () => {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'pool-seed', name: 'User', email: 'pool-seed@example.com' })
    const candidates = await db.insert(tracks).values(Array.from({ length: 50 }, (_, i) => ({
      appleId: `candidate-${i}`, title: `Candidate ${i}`, artist: i < 5 ? 'Reference Artist' : `Artist ${i}`,
      genre: i < 5 ? 'Soul' : 'Rock', isrc: `ZZAAA260${String(i).padStart(4, '0')}`,
    }))).returning()
    await db.insert(userTracks).values(candidates.map(t => ({ userId: 'pool-seed', trackId: t.id,
      playCount: 0, inLibrary: true })))
    await db.insert(trackFeatures).values(candidates.map((t, i) => ({ trackId: t.id,
      tempo: i < 5 ? 90 : 180, energy: i < 5 ? 0.2 : 0.9, source: 'reccobeats' as const })))
    const [isrcSibling] = await db.insert(tracks).values({ spotifyId: '4uLU6hMCjMI75M1A2tKUQC',
      title: 'Same recording elsewhere', artist: 'Reference Artist', genre: 'Soul', isrc: candidates[0].isrc }).returning()
    await db.insert(userTracks).values({ userId: 'pool-seed', trackId: isrcSibling.id, playCount: 0, inLibrary: true })
    await db.insert(trackFeatures).values({ trackId: isrcSibling.id, tempo: 90, energy: 0.2, source: 'reccobeats' })
    const [playlist] = await db.insert(userPlaylists).values({ userId: 'pool-seed', appleLibraryId: 'seed-pool',
      name: 'Low Light', kind: 'user', sourceFingerprint: 'b'.repeat(64) }).returning()
    await db.insert(playlistEntries).values(candidates.slice(0, 3).map((t, position) => ({ playlistId: playlist.id,
      position, trackId: t.id, appleLibraryEntryId: `source-${position}`,
      titleSnapshot: t.title, artistSnapshot: t.artist })))
    const intent = { themes: 'quiet', familiarity: 'mix' as const, allowExplicit: true, targetCount: 3 }
    const seeded = await buildPool(db, embedding, 'pool-seed', intent, undefined,
      { playlistSeed: { playlistId: playlist.id, excludeSourceTracks: false } })
    expect(seeded.slice(0, 5).every(t => t.artist === 'Reference Artist')).toBe(true)
    const excluded = await buildPool(db, embedding, 'pool-seed', intent, undefined,
      { playlistSeed: { playlistId: playlist.id, excludeSourceTracks: true } })
    expect(excluded.some(t => [...candidates.slice(0, 3).map(x => x.id), isrcSibling.id].includes(t.trackId))).toBe(false)
    expect(excluded).toHaveLength(45)
  })
})
