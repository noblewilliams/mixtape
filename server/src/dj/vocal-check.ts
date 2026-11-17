import type { LyricsKey, LyricsResult } from '../enrich/lrclib'
import { featuresSinger } from './artist-pool'

// Instrumental briefs check outside songs on LRCLIB (2026-11-17, founder).
// Live, "Phezulu" by Zakes Bantwini & Skye Wanda reached a "lofi afro house
// ... great instrumentals" mix: Apple lists most dance songs without lyrics,
// and a singer credited with "&" carries no "feat.". The library already
// filters on LRCLIB's instrumental flag (track_meanings.instrumental,
// dj/pool.ts); outside songs (the artist pool, verified proposals) now get
// the same signal per turn, before selection.
//
// Only whether lyrics exist, or the instrumental flag, is read. Lyric text
// is never stored, logged or passed on: it is dropped inside the lookup's
// own callback (docs/decisions.md, lyrics stance).

// 'vocal': LRCLIB holds lyrics and no instrumental flag. 'instrumental': the
// flag. 'unknown': no record, an error, a timeout, or past the deadline or
// the budget.
export type VocalStatus = 'vocal' | 'instrumental' | 'unknown'

// Lookups at once.
export const LYRICS_CHECK_CONCURRENCY = 6
// Wall time for the whole turn's checks.
export const LYRICS_CHECK_DEADLINE_MS = 4_000
// Songs checked per turn at most: the artist pool's 36 plus a few spares.
export const LYRICS_CHECK_MAX = 40
// fetchLyrics' worst case: the exact get misses, then the search.
export const LRCLIB_PER_SONG = 2
// LRCLIB requests a turn may make, charged at the worst case.
export const TURN_LYRICS_BUDGET = LYRICS_CHECK_MAX * LRCLIB_PER_SONG

export type LyricsSong = { id: string; title: string; artist: string; album: string | null; durationMs: number | null }

export type VocalCheckResult = {
  status: Map<string, VocalStatus>
  // Lookups started.
  checked: number
  // LRCLIB requests charged (LRCLIB_PER_SONG per lookup started).
  subrequests: number
  timedOut?: true
}

type Lookup = (key: LyricsKey) => Promise<LyricsResult | null>

// Reads the result and lets go of it: only the status leaves.
function statusOf(r: LyricsResult | null): VocalStatus {
  if (!r) return 'unknown'
  if (r.instrumental) return 'instrumental'
  return typeof r.lyrics === 'string' && r.lyrics.trim() !== '' ? 'vocal' : 'unknown'
}

const EXPIRED = Symbol('expired')

/**
 * Each song's status on LRCLIB, `concurrency` at a time in the order given,
 * inside `deadlineMs` and `budget` requests. A song not reached, or still
 * waiting at the deadline, is unknown. Never throws.
 */
export async function checkVocals(
  songs: LyricsSong[],
  lookup: Lookup,
  options: { deadlineMs: number; budget: number; concurrency?: number },
): Promise<VocalCheckResult> {
  const result: VocalCheckResult = { status: new Map(songs.map((s) => [s.id, 'unknown' as VocalStatus])), checked: 0, subrequests: 0 }
  if (songs.length === 0 || options.deadlineMs <= 0) return result
  let expired = false
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<typeof EXPIRED>((resolve) => {
    timer = setTimeout(() => {
      expired = true
      resolve(EXPIRED)
    }, options.deadlineMs)
  })
  let next = 0
  const worker = async () => {
    while (next < songs.length) {
      if (expired) {
        result.timedOut = true
        return
      }
      if (result.subrequests + LRCLIB_PER_SONG > options.budget) return
      const song = songs[next++]
      result.checked += 1
      result.subrequests += LRCLIB_PER_SONG
      const status = lookup({ title: song.title, artist: song.artist, album: song.album, durationMs: song.durationMs })
        .then(statusOf, () => 'unknown' as const)
      const answer = await Promise.race([status, deadline])
      if (answer === EXPIRED) {
        result.timedOut = true
        return
      }
      result.status.set(song.id, answer)
    }
  }
  try {
    await Promise.all(Array.from({ length: Math.min(options.concurrency ?? LYRICS_CHECK_CONCURRENCY, songs.length) }, worker))
  } finally {
    clearTimeout(timer)
  }
  return result
}

// Several artists in one credit: "&", a comma or "x" between names.
const MULTI = /\s&\s|,\s|\sx\s/i
export function multiArtistCredit(artist: string): boolean {
  return MULTI.test(artist)
}

type Rankable = { trackId: string; title: string; artist: string; hasLyrics?: boolean | null }

/**
 * An instrumental brief's outside songs: vocal ones (LRCLIB lyrics, or a
 * featured singer) dropped; known instrumentals first; then the unknown,
 * single-artist credits before multi-artist ones, and songs Apple lists with
 * lyrics last. The given order holds within each rank.
 */
export function rankInstrumental<T extends Rankable>(songs: T[], status: Map<string, VocalStatus>): { kept: T[]; dropped: string[] } {
  const dropped: string[] = []
  const ranked: { s: T; rank: number; i: number }[] = []
  songs.forEach((s, i) => {
    const st = status.get(s.trackId) ?? 'unknown'
    if (st === 'vocal' || featuresSinger(s)) {
      dropped.push(s.trackId)
      return
    }
    const rank = st === 'instrumental' ? 0 : s.hasLyrics === true ? 3 : multiArtistCredit(s.artist) ? 2 : 1
    ranked.push({ s, rank, i })
  })
  ranked.sort((a, b) => a.rank - b.rank || a.i - b.i)
  return { kept: ranked.map((r) => r.s), dropped }
}
