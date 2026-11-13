import { describe, expect, it } from 'vitest'
import type { DjSession, SharedMixRow } from '../domain'
import { mergeSharedRows, sharedSubline } from './mixes-list'

const session = (id: string, updatedAt: string) => ({ id, updatedAt }) as DjSession
const shared = (token: string, savedAt: string, sharerName: string | null = 'Ada'): SharedMixRow => ({
  token, title: token, caseColor: '#bc5734', sharerName, savedAt, trackCount: 10, durationMs: 2_400_000,
})

describe('mergeSharedRows', () => {
  it('places shared rows among sessions by time, newest first, keeping the sessions in their order', () => {
    const sessions = [session('a', '2026-11-13T10:00:00Z'), session('b', '2026-11-11T10:00:00Z'), session('c', '2026-11-01T10:00:00Z')]
    const rows = [shared('new', '2026-11-13T12:00:00Z'), shared('mid', '2026-11-12T08:00:00Z'), shared('old', '2026-10-01T00:00:00Z')]
    const merged = mergeSharedRows(sessions, rows)
    expect(merged.map((item) => item.kind === 'session' ? item.session.id : item.row.token)).toEqual(['new', 'a', 'mid', 'b', 'c', 'old'])
  })

  it('is the sessions alone when nothing is shared', () => {
    const sessions = [session('a', '2026-11-13T10:00:00Z')]
    expect(mergeSharedRows(sessions, []).map((item) => item.kind)).toEqual(['session'])
  })
})

describe('sharedSubline', () => {
  it('reads From <name> · N songs · <relative day>', () => {
    const now = new Date().toISOString()
    expect(sharedSubline(shared('t', now))).toBe('From Ada · 10 songs · just now')
  })

  it('says a friend when the sharer has no name, and one song in the singular', () => {
    const yesterday = new Date(Date.now() - 30 * 3_600_000).toISOString()
    expect(sharedSubline({ ...shared('t', yesterday, null), trackCount: 1 })).toBe('From a friend · 1 song · yesterday')
  })
})
