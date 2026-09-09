import type { ApiMusicSource, OnboardingResponse } from '../api/client'

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const DAY_MS = 24 * 60 * 60 * 1000

const TRACK_LINK = /^https:\/\/open\.spotify\.com\/(?:intl-[a-z]{2}\/)?track\/([A-Za-z0-9]{22})(?:[?#].*)?$/
const TRACK_URI = /^spotify:track:([A-Za-z0-9]{22})$/

export type ParsedTrackLines = { ids: string[]; unrecognised: number; lines: number }

/** One Spotify link per line, in either form; ids deduped in order, bad lines counted. */
export function parseSpotifyTrackLines(text: string): ParsedTrackLines {
  const ids: string[] = []
  let unrecognised = 0
  let lines = 0
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line) continue
    lines += 1
    const id = TRACK_LINK.exec(line)?.[1] ?? TRACK_URI.exec(line)?.[1] ?? null
    if (!id) {
      unrecognised += 1
      continue
    }
    if (!ids.includes(id)) ids.push(id)
  }
  return { ids, unrecognised, lines }
}

// Local calendar days, so "Today" is the device's today. Date.UTC only turns
// the local y/m/d into a day index here; it is not a zone conversion.
function daysBetween(iso: string, now: Date): number {
  const then = new Date(iso)
  const startOfNow = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate())
  const startOfThen = Date.UTC(then.getFullYear(), then.getMonth(), then.getDate())
  return Math.max(0, Math.round((startOfNow - startOfThen) / DAY_MS))
}

export function elapsedWaitLabel(markedRequestedAt: string, now: Date = new Date()): string {
  const days = daysBetween(markedRequestedAt, now)
  if (days === 0) return 'Today'
  return days === 1 ? '1 day' : `${days} days`
}

export function shortDate(iso: string): string {
  const date = new Date(iso)
  return `${date.getDate()} ${MONTHS[date.getMonth()]}`
}

export function recentDayLabel(markedRequestedAt: string, now: Date = new Date()): string {
  if (daysBetween(markedRequestedAt, now) < 7) return WEEKDAYS[new Date(markedRequestedAt).getDay()]
  return shortDate(markedRequestedAt)
}

function monthYear(day: string): string {
  const [year, month] = day.split('-')
  return `${MONTHS[Number.parseInt(month, 10) - 1]} ${year}`
}

export function ledgerRangeLabel(from: string | null, to: string | null): string | null {
  if (!from) return null
  const start = monthYear(from)
  const end = to ? monthYear(to) : start
  return start === end ? start : `${start} → ${end}`
}

export function spotifySource(onboarding: OnboardingResponse | null): ApiMusicSource | null {
  return onboarding?.sources.find((source) => source.source === 'spotify_export') ?? null
}

export type SpotifyPackages = { extended: boolean; account: boolean; count: number }

/** Which Spotify packages have a completed import behind them; a source row alone proves nothing. */
export function spotifyPackages(source: ApiMusicSource | null): SpotifyPackages {
  const packages = source?.packages ?? []
  const extended = packages.includes('spotify_extended')
  const account = packages.includes('spotify_account')
  return { extended, account, count: Number(extended) + Number(account) }
}

export type StatusTone = 'neutral' | 'ok' | 'wait' | 'err'

export function spotifyStatus(onboarding: OnboardingResponse): { label: string; tone: StatusTone } {
  if (spotifySource(onboarding)?.packages.includes('spotify_exportify')) return {label:'Saved music imported',tone:'ok'}
  const { count } = spotifyPackages(spotifySource(onboarding))
  if (count === 2) return { label: 'Both in', tone: 'ok' }
  if (count === 1) return { label: '1 of 2 in', tone: 'ok' }
  if (onboarding.markedRequestedAt) return { label: 'Waiting', tone: 'wait' }
  return { label: 'Not requested', tone: 'wait' }
}

export function musicLinkLabel(onboarding: OnboardingResponse | null): { text: string; tone: 'ok' | 'waiting' | 'quiet' } {
  if (!onboarding || onboarding.chosenService === null) return { text: 'Not connected yet', tone: 'quiet' }
  if (onboarding.chosenService === 'apple') return { text: 'Apple Music', tone: 'ok' }
  const source = spotifySource(onboarding)
  const importedAt = source?.lastImportedAt ?? onboarding.importCompletedAt
  if (source && importedAt) return { text: `Spotify · imported ${shortDate(importedAt)}`, tone: 'ok' }
  if (onboarding.markedRequestedAt) return { text: 'Spotify · waiting for your data', tone: 'waiting' }
  return { text: 'Spotify · ready to import', tone: 'waiting' }
}

export function sourceName(source: ApiMusicSource): string {
  switch (source.source) {
    case 'spotify_export': {
      if(source.packages.includes('spotify_exportify')) return source.packages.includes('spotify_extended')?'Spotify · saved music and history':'Spotify · saved music'
      const { extended, account } = spotifyPackages(source)
      if (extended && account) return 'Spotify · both packages'
      if (extended) return 'Spotify · extended history'
      if (account) return 'Spotify · account data'
      return 'Spotify'
    }
    case 'apple_live':
      return 'Apple Music'
    case 'apple_export':
      return 'Apple Music · export'
  }
}
