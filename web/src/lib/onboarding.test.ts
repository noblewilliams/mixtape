import { describe, expect, it } from 'vitest'
import type { ApiMusicSource, OnboardingResponse } from '../api/client'
import {
  elapsedWaitLabel,
  ledgerRangeLabel,
  musicLinkLabel,
  parseSpotifyTrackLines,
  recentDayLabel,
  shortDate,
  sourceName,
  spotifyStatus,
} from './onboarding'

const blank: OnboardingResponse = {
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
}

const spotifySource: ApiMusicSource = {
  source: 'spotify_export',
  connectedAt: '2026-09-04T09:00:00.000Z',
  lastImportedAt: '2026-09-04T09:30:00.000Z',
  ledgerFrom: '2018-03-02',
  ledgerTo: '2026-08-29',
}

describe('parseSpotifyTrackLines', () => {
  it('reads both link forms, ignores query strings, and counts the rest', () => {
    const parsed = parseSpotifyTrackLines([
      'https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUc9Lp',
      'https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3?si=abc123&nd=1',
      '  spotify:track:0VjIjW4GlUZAMYd2vXMi3b  ',
      'https://open.spotify.com/intl-de/track/2takcwOaAZWiXQijPHIx7B',
      'https://open.spotify.com/track/notARealId',
      'https://open.spotify.com/album/3n3Ppam7vgaVa1iaRUc9Lp',
      '',
      'https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUc9Lp',
    ].join('\n'))

    expect(parsed.ids).toEqual([
      '3n3Ppam7vgaVa1iaRUc9Lp',
      '7qiZfU4dY1lWllzX7mPBI3',
      '0VjIjW4GlUZAMYd2vXMi3b',
      '2takcwOaAZWiXQijPHIx7B',
    ])
    expect(parsed.unrecognised).toBe(2)
    expect(parsed.lines).toBe(7)
  })

  it('returns nothing for blank input', () => {
    expect(parseSpotifyTrackLines('\n  \n')).toEqual({ ids: [], unrecognised: 0, lines: 0 })
  })
})

describe('wait labels', () => {
  const now = new Date('2026-09-04T12:00:00.000Z')

  it('counts whole days since the request was marked', () => {
    expect(elapsedWaitLabel('2026-09-04T08:00:00.000Z', now)).toBe('Today')
    expect(elapsedWaitLabel('2026-09-03T08:00:00.000Z', now)).toBe('1 day')
    expect(elapsedWaitLabel('2026-09-02T08:00:00.000Z', now)).toBe('2 days')
    expect(elapsedWaitLabel('2026-08-23T08:00:00.000Z', now)).toBe('12 days')
  })

  it('names the weekday inside a week and the date after it', () => {
    expect(recentDayLabel('2026-09-01T08:00:00.000Z', now)).toBe('Tuesday')
    expect(recentDayLabel('2026-08-23T08:00:00.000Z', now)).toBe('23 Aug')
  })

  it('formats short dates and ledger ranges', () => {
    expect(shortDate('2026-09-04T09:30:00.000Z')).toBe('4 Sep')
    expect(ledgerRangeLabel('2018-03-02', '2026-08-29')).toBe('Mar 2018 → Aug 2026')
    expect(ledgerRangeLabel('2026-08-02', '2026-08-29')).toBe('Aug 2026')
    expect(ledgerRangeLabel(null, null)).toBeNull()
  })
})

describe('spotifyStatus', () => {
  it('moves from Not requested to Waiting to 1 of 2 in', () => {
    expect(spotifyStatus(blank)).toEqual({ label: 'Not requested', tone: 'wait' })
    expect(spotifyStatus({ ...blank, markedRequestedAt: '2026-09-02T08:00:00.000Z' })).toEqual({
      label: 'Waiting',
      tone: 'wait',
    })
    expect(spotifyStatus({ ...blank, sources: [spotifySource] })).toEqual({ label: '1 of 2 in', tone: 'ok' })
  })
})

describe('musicLinkLabel', () => {
  it('reflects the listener state in the sidebar subline', () => {
    expect(musicLinkLabel(null)).toEqual({ text: 'Not connected yet', tone: 'quiet' })
    expect(musicLinkLabel(blank)).toEqual({ text: 'Not connected yet', tone: 'quiet' })
    expect(musicLinkLabel({ ...blank, chosenService: 'apple', hasLibrary: true })).toEqual({
      text: 'Apple Music',
      tone: 'ok',
    })
    expect(musicLinkLabel({ ...blank, chosenService: 'spotify' })).toEqual({
      text: 'Spotify · not requested yet',
      tone: 'waiting',
    })
    expect(musicLinkLabel({ ...blank, chosenService: 'spotify', markedRequestedAt: '2026-09-02T08:00:00.000Z' })).toEqual({
      text: 'Spotify · waiting for your data',
      tone: 'waiting',
    })
    expect(musicLinkLabel({ ...blank, chosenService: 'spotify', sources: [spotifySource] })).toEqual({
      text: 'Spotify · imported 4 Sep',
      tone: 'ok',
    })
  })
})

describe('sourceName', () => {
  it('names each source the way the sources view does', () => {
    expect(sourceName(spotifySource)).toBe('Spotify · extended history')
    expect(sourceName({ ...spotifySource, ledgerFrom: null, ledgerTo: null })).toBe('Spotify · account data')
    expect(sourceName({ ...spotifySource, source: 'apple_live' })).toBe('Apple Music')
    expect(sourceName({ ...spotifySource, source: 'apple_export' })).toBe('Apple Music · export')
  })
})
