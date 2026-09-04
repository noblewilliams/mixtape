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

function daysBetween(iso: string, now: Date): number {
  const then = new Date(iso)
  const startOfNow = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  const startOfThen = Date.UTC(then.getUTCFullYear(), then.getUTCMonth(), then.getUTCDate())
  return Math.max(0, Math.round((startOfNow - startOfThen) / DAY_MS))
}

export function elapsedWaitLabel(markedRequestedAt: string, now: Date = new Date()): string {
  const days = daysBetween(markedRequestedAt, now)
  if (days === 0) return 'Today'
  return days === 1 ? '1 day' : `${days} days`
}

export function shortDate(iso: string): string {
  const date = new Date(iso)
  return `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()]}`
}

export function recentDayLabel(markedRequestedAt: string, now: Date = new Date()): string {
  if (daysBetween(markedRequestedAt, now) < 7) return WEEKDAYS[new Date(markedRequestedAt).getUTCDay()]
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

export type StatusTone = 'neutral' | 'ok' | 'wait' | 'err'

export function spotifyStatus(onboarding: OnboardingResponse): { label: string; tone: StatusTone } {
  if (spotifySource(onboarding)) return { label: '1 of 2 in', tone: 'ok' }
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
  return { text: 'Spotify · not requested yet', tone: 'waiting' }
}

export function sourceName(source: ApiMusicSource): string {
  switch (source.source) {
    case 'spotify_export':
      return source.ledgerFrom ? 'Spotify · extended history' : 'Spotify · account data'
    case 'apple_live':
      return 'Apple Music'
    case 'apple_export':
      return 'Apple Music · export'
  }
}
