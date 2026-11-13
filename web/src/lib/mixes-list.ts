// The Mixes list with the shares this listener saved (spec 2026-11-13
// shared-mixes, Recipient on the web; board WM1): shared rows sort with the
// listener's own mixes by time, sessions by updatedAt and shared rows by
// savedAt, newest first.
import { ageLabel } from '../api/mappers'
import type { DjSession, SharedMixRow } from '../domain'

export type MixesItem =
  | { kind: 'session'; session: DjSession }
  | { kind: 'shared'; row: SharedMixRow }

const time = (iso: string) => {
  const value = Date.parse(iso)
  return Number.isNaN(value) ? 0 : value
}

/**
 * Sessions keep the order they arrive in (newest first from the server, a
 * new tape on top); each shared row goes in before the first session older
 * than its save.
 */
export function mergeSharedRows(sessions: DjSession[], rows: SharedMixRow[]): MixesItem[] {
  const pending = [...rows].sort((a, b) => time(b.savedAt) - time(a.savedAt))
  const merged: MixesItem[] = []
  for (const session of sessions) {
    while (pending.length && time(pending[0].savedAt) > time(session.updatedAt)) merged.push({ kind: 'shared', row: pending.shift()! })
    merged.push({ kind: 'session', session })
  }
  for (const row of pending) merged.push({ kind: 'shared', row })
  return merged
}

export function sharerLabel(name: string | null) {
  return `From ${name ?? 'a friend'}`
}

/** "10 songs · today": the part of the row's line after who shared it. */
export function sharedDetails(row: SharedMixRow) {
  return `${row.trackCount} ${row.trackCount === 1 ? 'song' : 'songs'} · ${ageLabel(row.savedAt)}`
}

/** "From Ada · 10 songs · today": the web row carries the count, as a mix row does. */
export function sharedSubline(row: SharedMixRow) {
  return `${sharerLabel(row.sharerName)} · ${sharedDetails(row)}`
}
