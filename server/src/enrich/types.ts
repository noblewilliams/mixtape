export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

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
