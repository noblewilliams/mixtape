import { describe, it, expect } from 'vitest'
import {
  checkVocals,
  multiArtistCredit,
  rankInstrumental,
  LRCLIB_PER_SONG,
  LYRICS_CHECK_CONCURRENCY,
  LYRICS_CHECK_DEADLINE_MS,
  LYRICS_CHECK_MAX,
  TURN_LYRICS_BUDGET,
  type VocalStatus,
} from '../../src/dj/vocal-check'
import type { LyricsKey, LyricsResult } from '../../src/enrich/lrclib'

// Instrumental briefs check outside songs on LRCLIB (2026-11-17): live,
// "Phezulu" by Zakes Bantwini & Skye Wanda reached a "great instrumentals"
// mix, since Apple lists most dance songs without lyrics and the credit
// carries no "feat.". Only whether lyrics exist is read; the text is
// discarded on the spot.

const song = (id: string, artist = 'Solo', title = `Song ${id}`) => ({ id, title, artist, album: 'Album', durationMs: 200_000 })

describe('checkVocals', () => {
  it('reads lyrics as vocal, the instrumental flag as instrumental, a miss or error as unknown', async () => {
    const answers: Record<string, LyricsResult | null | Error> = {
      a: { lyrics: 'la la la', instrumental: false },
      b: { lyrics: null, instrumental: true },
      c: null,
      d: new Error('lrclib down'),
      e: { lyrics: '   ', instrumental: false },
    }
    const lookup = async (key: LyricsKey) => {
      const a = answers[key.title.replace('Song ', '')]
      if (a instanceof Error) throw a
      return a
    }
    const result = await checkVocals(['a', 'b', 'c', 'd', 'e'].map((id) => song(id)), lookup, { deadlineMs: 1_000, budget: 100 })
    expect(Object.fromEntries(result.status)).toEqual({ a: 'vocal', b: 'instrumental', c: 'unknown', d: 'unknown', e: 'unknown' })
    expect(result.checked).toBe(5)
    expect(result.subrequests).toBe(5 * LRCLIB_PER_SONG)
  })

  it('passes title, artist, album and duration to the lookup', async () => {
    const keys: LyricsKey[] = []
    await checkVocals([song('a', 'Zakes Bantwini & Skye Wanda', 'Phezulu')], async (k) => { keys.push(k); return null }, { deadlineMs: 1_000, budget: 10 })
    expect(keys).toEqual([{ title: 'Phezulu', artist: 'Zakes Bantwini & Skye Wanda', album: 'Album', durationMs: 200_000 }])
  })

  it('returns no lyric text: only the status per song', async () => {
    const result = await checkVocals([song('a')], async () => ({ lyrics: 'SECRET LYRIC LINE', instrumental: false }), { deadlineMs: 1_000, budget: 10 })
    expect(JSON.stringify({ ...result, status: [...result.status] })).not.toContain('SECRET')
  })

  it('respects the deadline: a lookup that never answers is unknown, and no lookup starts after it', async () => {
    let started = 0
    const began = Date.now()
    const result = await checkVocals(
      Array.from({ length: 20 }, (_, i) => song(String(i))),
      () => { started += 1; return new Promise<LyricsResult | null>(() => {}) },
      { deadlineMs: 40, budget: 100, concurrency: 3 },
    )
    expect(Date.now() - began).toBeLessThan(1_000)
    expect(started).toBe(3)
    expect(result.checked).toBe(3)
    expect(result.timedOut).toBe(true)
    expect([...result.status.values()].every((s) => s === 'unknown')).toBe(true)
    expect(result.status.size).toBe(20)
  })

  it('stays inside the budget, LRCLIB_PER_SONG per song; the rest are unknown', async () => {
    let calls = 0
    const result = await checkVocals(
      Array.from({ length: 10 }, (_, i) => song(String(i))),
      async () => { calls += 1; return { lyrics: null, instrumental: true } },
      { deadlineMs: 1_000, budget: 3 * LRCLIB_PER_SONG + 1 },
    )
    expect(calls).toBe(3)
    expect(result.subrequests).toBe(3 * LRCLIB_PER_SONG)
    expect([...result.status.values()].filter((s) => s === 'instrumental')).toHaveLength(3)
    expect([...result.status.values()].filter((s) => s === 'unknown')).toHaveLength(7)
  })

  it('runs about six at once', async () => {
    let active = 0
    let peak = 0
    await checkVocals(Array.from({ length: 20 }, (_, i) => song(String(i))), async () => {
      active += 1
      peak = Math.max(peak, active)
      await new Promise((r) => setTimeout(r, 2))
      active -= 1
      return null
    }, { deadlineMs: 1_000, budget: 100 })
    expect(LYRICS_CHECK_CONCURRENCY).toBe(6)
    expect(peak).toBe(6)
  })

  it('has a four second deadline and a per-turn allowance of two LRCLIB requests per song', () => {
    expect(LYRICS_CHECK_DEADLINE_MS).toBe(4_000)
    expect(LRCLIB_PER_SONG).toBe(2)
    expect(TURN_LYRICS_BUDGET).toBe(LYRICS_CHECK_MAX * LRCLIB_PER_SONG)
  })
})

describe('multiArtistCredit', () => {
  it('reads &, a comma or x between names as several artists', () => {
    expect(multiArtistCredit('Zakes Bantwini & Skye Wanda')).toBe(true)
    expect(multiArtistCredit('Black Coffee, Msaki')).toBe(true)
    expect(multiArtistCredit('Kabza De Small x DJ Maphorisa')).toBe(true)
    expect(multiArtistCredit('Caiiro')).toBe(false)
    expect(multiArtistCredit('Xoli M')).toBe(false)
    expect(multiArtistCredit('Felix Laband')).toBe(false)
  })
})

describe('rankInstrumental', () => {
  type S = { trackId: string; title: string; artist: string; hasLyrics?: boolean | null }
  const s = (trackId: string, artist = 'Solo', extra: Partial<S> = {}): S => ({ trackId, title: `Song ${trackId}`, artist, ...extra })

  it('drops vocal songs, puts known instrumentals first, unknown after, in order within each', () => {
    const status = new Map<string, VocalStatus>([['a', 'unknown'], ['b', 'vocal'], ['c', 'instrumental'], ['d', 'unknown'], ['e', 'instrumental']])
    const { kept, dropped } = rankInstrumental([s('a'), s('b'), s('c'), s('d'), s('e')], status)
    expect(kept.map((k) => k.trackId)).toEqual(['c', 'e', 'a', 'd'])
    expect(dropped).toEqual(['b'])
  })

  it('a featured singer is vocal whatever LRCLIB says', () => {
    const status = new Map<string, VocalStatus>([['a', 'instrumental'], ['b', 'unknown']])
    const { kept, dropped } = rankInstrumental([s('a', 'Caiiro feat. Pixie L'), s('b')], status)
    expect(kept.map((k) => k.trackId)).toEqual(['b'])
    expect(dropped).toEqual(['a'])
  })

  it('a multi-artist unknown ranks after a single-artist unknown, and is not dropped on that alone', () => {
    const status = new Map<string, VocalStatus>([['a', 'unknown'], ['b', 'unknown'], ['c', 'instrumental']])
    const { kept } = rankInstrumental([s('a', 'Zakes Bantwini & Skye Wanda'), s('b', 'Caiiro'), s('c', 'Kususa & Shimza')], status)
    expect(kept.map((k) => k.trackId)).toEqual(['c', 'b', 'a'])
  })

  it('an unknown Apple lists with lyrics ranks last among the unknown; a song never checked is unknown', () => {
    const status = new Map<string, VocalStatus>([['b', 'unknown']])
    const { kept } = rankInstrumental([s('a', 'Solo', { hasLyrics: true }), s('b', 'Duo & Friend'), s('c')], status)
    expect(kept.map((k) => k.trackId)).toEqual(['c', 'b', 'a'])
  })
})
