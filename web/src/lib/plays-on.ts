// Where this browser's mixes play (decisions 2026-11-06): Spotify, by way of
// the TuneMyMusic handoff, or Apple Music. A device preference like dark mode,
// not tied to the account, so it survives the anonymous-to-account sign-in.
// Null until the listener answers, which is when a mix asks "Where do you
// listen?". Also remembers whether the Play on Spotify explainer has been
// carried through once. Storage may be blocked: every call swallows that and
// behaves as if nothing were stored.
import { useSyncExternalStore } from 'react'

export type PlaysOn = 'spotify' | 'apple'

const PLAYS_ON_KEY = 'mixtape.plays-on'
const INTRO_KEY = 'mixtape.spotify-intro-seen'

const listeners = new Set<() => void>()

export function readPlaysOn(): PlaysOn | null {
  try {
    const value = window.localStorage.getItem(PLAYS_ON_KEY)
    return value === 'spotify' || value === 'apple' ? value : null
  } catch {
    return null
  }
}

export function writePlaysOn(choice: PlaysOn) {
  try {
    window.localStorage.setItem(PLAYS_ON_KEY, choice)
  } catch {
    // Storage blocked: the mix asks again next time, which still works.
  }
  listeners.forEach((listener) => listener())
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/** The remembered choice, re-read whenever any part of the app changes it. */
export function usePlaysOn(): PlaysOn | null {
  return useSyncExternalStore(subscribe, readPlaysOn, () => null)
}

export function spotifyIntroSeen(): boolean {
  try {
    return window.localStorage.getItem(INTRO_KEY) !== null
  } catch {
    return false
  }
}

export function markSpotifyIntroSeen() {
  try {
    window.localStorage.setItem(INTRO_KEY, 'seen')
  } catch {
    // Storage blocked: the explainer simply shows again next time.
  }
}
