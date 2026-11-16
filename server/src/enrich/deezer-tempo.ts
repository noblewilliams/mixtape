import { EnrichSourceError, fetchFailedDetail, type FetchLike } from './types'

// Deezer's public track lookup by ISRC, for its `bpm` field: the tempo
// fallback when ReccoBeats has no features for a song. No key, no billing.
// Results land in track_feature_fallbacks (tempo_source 'deezer'), never in
// track_features, which stays measured-only.

const SOURCE = 'deezer'
const TIMEOUT_MS = 4000
const ISRC_PATTERN = /^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$/
// Matches the write-side range check on track_feature_fallbacks.tempo.
const MIN_BPM = 40
const MAX_BPM = 250

export type DeezerTempoClient = {
  tempoByIsrc(isrc: string): Promise<number | null>
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

export function createDeezerTempoClient({ fetchLike = fetch }: { fetchLike?: FetchLike } = {}): DeezerTempoClient {
  return {
    async tempoByIsrc(value) {
      const isrc = value.trim().toUpperCase()
      if (!ISRC_PATTERN.test(isrc)) return null

      const res = await fetchLike(`https://api.deezer.com/track/isrc:${isrc}`, {
        signal: AbortSignal.timeout(TIMEOUT_MS),
      }).catch((e: unknown) => {
        throw new EnrichSourceError(SOURCE, fetchFailedDetail('fetch failed', e), undefined, { transient: true })
      })
      if (res.status === 429 || res.status >= 500) {
        throw new EnrichSourceError(SOURCE, `HTTP ${res.status}`, res.status)
      }
      // Any other non-2xx is Deezer's answer about this ISRC: a miss.
      if (!res.ok) return null

      // Deezer's own 200s are always JSON; a body that isn't is an edge or
      // proxy page under load, so it's treated as the provider's side.
      const body = await res.json().catch((e: unknown) => {
        throw new EnrichSourceError(SOURCE, fetchFailedDetail('body unreadable', e), undefined, { transient: true })
      })
      // Unknown ISRCs come back as 200 with { error: { code: 800, … } }.
      if (!isRecord(body) || 'error' in body) return null
      const bpm = body.bpm
      if (typeof bpm !== 'number' || !Number.isFinite(bpm) || bpm <= 0) return null
      if (bpm < MIN_BPM || bpm > MAX_BPM) return null
      return bpm
    },
  }
}
