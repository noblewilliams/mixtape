export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export const SOURCE_TIMEOUT_MS = 5000

export const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N} ]/gu, '').trim()

export class EnrichSourceError extends Error {
  constructor(
    readonly source: string,
    readonly detail: string,
    readonly status?: number,
  ) {
    super(`${source}: ${detail}`)
    this.name = 'EnrichSourceError'
  }
}
