import { describe, expect, it } from 'vitest'
import type { ApiMusicSource, OnboardingResponse } from '../api/client'
import { addMusicFacts, addMusicRoute, type AddMusicFacts } from './add-music-route'

const facts = (over: Partial<AddMusicFacts>): AddMusicFacts => ({
  platform: null,
  spotifyRequested: false,
  spotifyWaiting: false,
  ...over,
})

describe('addMusicRoute', () => {
  it('door, Apple Music, with or without a live library: Step 3 Apple sync', () => {
    expect(addMusicRoute('door', facts({ platform: 'apple' }))).toStrictEqual({ kind: 'flow', startAt: 'apple-sync' })
  })

  it('retrySync: Step 3 Apple sync, whatever the platform', () => {
    expect(addMusicRoute('retrySync', facts({ platform: 'apple' }))).toStrictEqual({ kind: 'flow', startAt: 'apple-sync' })
    expect(addMusicRoute('retrySync', facts({ platform: 'spotify' }))).toStrictEqual({ kind: 'flow', startAt: 'apple-sync' })
    expect(addMusicRoute('retrySync', facts({ platform: null }))).toStrictEqual({ kind: 'flow', startAt: 'apple-sync' })
  })

  it('door, Spotify, data export requested or not: Step 3 Exportify, whose Choose files takes either file', () => {
    expect(addMusicRoute('door', facts({ platform: 'spotify' }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
    expect(addMusicRoute('door', facts({ platform: 'spotify', spotifyRequested: true }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
  })

  it('door, Spotify data export waiting: Step 3 Exportify to choose the files, whatever the platform', () => {
    const waiting = { spotifyRequested: true, spotifyWaiting: true }
    expect(addMusicRoute('door', facts({ platform: 'apple', ...waiting }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
    expect(addMusicRoute('door', facts({ platform: null, ...waiting }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
    expect(addMusicRoute('door', facts({ platform: 'spotify', ...waiting }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
    // A retry is still the Apple sync.
    expect(addMusicRoute('retrySync', facts({ platform: 'apple', ...waiting }))).toStrictEqual({ kind: 'flow', startAt: 'apple-sync' })
  })

  it('door, platform unknown: Step 1', () => {
    expect(addMusicRoute('door', facts({ platform: null }))).toStrictEqual({ kind: 'flow' })
  })

  it('history, Spotify, not requested yet: Step 3 data export', () => {
    expect(addMusicRoute('history', facts({ platform: 'spotify' }))).toStrictEqual({ kind: 'flow', startAt: 'spotify-export' })
  })

  it('history, Spotify, already requested: Step 3 Exportify, to choose the files', () => {
    expect(addMusicRoute('history', facts({ platform: 'spotify', spotifyRequested: true }))).toStrictEqual({ kind: 'flow', startAt: 'exportify' })
  })

  it('history, Apple Music or unknown: nothing, since the web has no Apple export import', () => {
    expect(addMusicRoute('history', facts({ platform: 'apple' }))).toStrictEqual({ kind: 'none' })
    expect(addMusicRoute('history', facts({ platform: 'apple', spotifyRequested: true }))).toStrictEqual({ kind: 'none' })
    expect(addMusicRoute('history', facts({ platform: null }))).toStrictEqual({ kind: 'none' })
  })
})

const blank: OnboardingResponse = {
  userId: 'user-1',
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
  interview: null,
  musicReady: false,
}

const source = (over: Partial<ApiMusicSource>): ApiMusicSource => ({
  source: 'spotify_export',
  connectedAt: '2026-11-01T09:00:00.000Z',
  lastImportedAt: null,
  ledgerFrom: null,
  ledgerTo: null,
  packages: [],
  ...over,
})

const appleLive = source({ source: 'apple_live', lastImportedAt: '2026-11-02T09:00:00.000Z' })

describe('addMusicFacts', () => {
  it('takes the platform from where this browser plays first', () => {
    expect(addMusicFacts('spotify', { ...blank, chosenService: 'apple', sources: [appleLive] }).platform).toBe('spotify')
    expect(addMusicFacts('apple', { ...blank, chosenService: 'spotify' }).platform).toBe('apple')
  })

  it('then from the chosen service', () => {
    expect(addMusicFacts(null, { ...blank, chosenService: 'spotify', sources: [appleLive] }).platform).toBe('spotify')
    expect(addMusicFacts(null, { ...blank, chosenService: 'apple' }).platform).toBe('apple')
  })

  it('then from a live Apple library, else unknown', () => {
    expect(addMusicFacts(null, { ...blank, sources: [appleLive] }).platform).toBe('apple')
    // Only a live library says Apple Music: an export or a library flag does not.
    expect(addMusicFacts(null, { ...blank, hasLibrary: true, sources: [source({ source: 'apple_export' })] }).platform).toBeNull()
    expect(addMusicFacts(null, blank).platform).toBeNull()
    expect(addMusicFacts(null, null).platform).toBeNull()
  })

  it('reads a data export as requested once it is marked, whatever has landed since', () => {
    const requested = { ...blank, chosenService: 'spotify' as const, markedRequestedAt: '2026-11-03T09:00:00.000Z' }
    expect(addMusicFacts(null, requested).spotifyRequested).toBe(true)
    expect(addMusicFacts(null, { ...requested, sources: [source({ packages: ['spotify_account'] })] }).spotifyRequested).toBe(true)
    expect(addMusicFacts(null, blank).spotifyRequested).toBe(false)
    expect(addMusicFacts(null, null).spotifyRequested).toBe(false)
  })

  it('reads the data export as waiting until a package lands', () => {
    const requested = { ...blank, chosenService: 'spotify' as const, markedRequestedAt: '2026-11-03T09:00:00.000Z' }
    expect(addMusicFacts('apple', requested).spotifyWaiting).toBe(true)
    expect(addMusicFacts('apple', { ...requested, sources: [source({ packages: ['spotify_account'] })] }).spotifyWaiting).toBe(false)
    expect(addMusicFacts(null, blank).spotifyWaiting).toBe(false)
  })

  it('carries nothing the router does not read', () => {
    expect(addMusicFacts('spotify', { ...blank, sources: [appleLive] })).toStrictEqual({ platform: 'spotify', spotifyRequested: false, spotifyWaiting: false })
  })
})
