// The mix a capped anonymous listener asked for. The web sign-in is a
// redirect, so the request waits in sessionStorage and the signed-in
// workspace sends it once it is ready, with the same playlist inspiration and
// shape. Back from the sign-in page drops it (the field still holds the
// prompt). Storage blocked: nothing is sent after the redirect.

import type { EnergyArc, InitialPlaylistSeed } from '../api/client'

const KEY = 'mixtape.kept-prompt'

export type KeptPrompt = {
  prompt: string
  inspiration: InitialPlaylistSeed | null
  shape: EnergyArc | null
}

export function keepPrompt(kept: KeptPrompt) {
  try {
    window.sessionStorage.setItem(KEY, JSON.stringify(kept))
  } catch {
    // Storage blocked.
  }
}

export function readKeptPrompt(): KeptPrompt | null {
  try {
    const raw = window.sessionStorage.getItem(KEY)
    if (!raw) return null
    const value = JSON.parse(raw) as Partial<KeptPrompt> | null
    if (!value || typeof value.prompt !== 'string' || !value.prompt) return null
    return { prompt: value.prompt, inspiration: value.inspiration ?? null, shape: value.shape ?? null }
  } catch {
    return null
  }
}

export function clearKeptPrompt() {
  try {
    window.sessionStorage.removeItem(KEY)
  } catch {
    // Storage blocked.
  }
}
