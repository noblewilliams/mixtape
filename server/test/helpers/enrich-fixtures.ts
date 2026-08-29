import type { EnrichDeps } from '../../src/enrich/pipeline'

export const OK_FEATURES = {
  tempo: 120, key: 1, mode: 1, energy: 0.5, danceability: 0.5, valence: 0.5,
  acousticness: 0.5, instrumentalness: 0.5, liveness: 0.5, speechiness: 0.5,
  loudness: -10, isrc: null,
}

export const okDeps: EnrichDeps = {
  storefront: 'ng',
  itunes: async () => null,
  features: async () => OK_FEATURES,
  lyrics: async () => ({ lyrics: 'words', instrumental: false }),
  embed: async () => Array.from({ length: 1024 }, () => 0),
}
