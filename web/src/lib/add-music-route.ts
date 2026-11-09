// Add your music: where a catalog mix's door, its retry and the history pill
// go (spec 2026-11-09, decision 2). Pure, so each listener's destination is
// tested on its own; App.tsx gathers the facts and opens the result. Every
// destination is the add flow over the mix, so each one returns to it.
import type { OnboardingResponse } from '../api/client'
import type { AddMethod } from '../components/first-run/ChooseMethod'
import type { PlaysOn } from './plays-on'

/**
 * `door`: the catalog mix's action. `retrySync`: the failed sync's Try again.
 * `history`: the "Add my listening history" pill.
 */
export type AddMusicTarget = 'door' | 'retrySync' | 'history'

export type AddMusicPlatform = 'apple' | 'spotify' | null

export type AddMusicFacts = {
  platform: AddMusicPlatform
  /** The listener marked their Spotify data export as requested. */
  spotifyRequested: boolean
}

/** `flow`: the add flow, at Step 3 for `startAt`, else Step 1. `none`: nothing to open. */
export type AddMusicRoute = { kind: 'flow'; startAt?: AddMethod } | { kind: 'none' }

export function addMusicRoute(target: AddMusicTarget, facts: AddMusicFacts): AddMusicRoute {
  // A retry is the Apple sync again, whoever asks: only a sync can have failed.
  if (target === 'retrySync') return { kind: 'flow', startAt: 'apple-sync' }
  if (target === 'history') {
    // The web reads no Apple export, so only Spotify has a history page here.
    // Once the export is requested, the next step is choosing its files.
    if (facts.platform !== 'spotify') return { kind: 'none' }
    return { kind: 'flow', startAt: facts.spotifyRequested ? 'exportify' : 'spotify-export' }
  }
  switch (facts.platform) {
    // With or without a live library: a first sync, or a re-sync.
    case 'apple':
      return { kind: 'flow', startAt: 'apple-sync' }
    // Exportify's Choose files also takes the data export ZIP, so a listener
    // still waiting on Spotify's email lands where the files go too.
    case 'spotify':
      return { kind: 'flow', startAt: 'exportify' }
    default:
      return { kind: 'flow' }
  }
}

/**
 * The facts for this listener: the platform is where this browser plays,
 * then the chosen service, then a live Apple library.
 */
export function addMusicFacts(playsOn: PlaysOn | null, onboarding: OnboardingResponse | null): AddMusicFacts {
  const appleLibrary = Boolean(onboarding?.sources.some((source) => source.source === 'apple_live'))
  return {
    platform: playsOn ?? onboarding?.chosenService ?? (appleLibrary ? 'apple' : null),
    spotifyRequested: Boolean(onboarding?.markedRequestedAt),
  }
}
