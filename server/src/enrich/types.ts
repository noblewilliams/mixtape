export type FetchLike = (url: string | URL, init?: RequestInit) => Promise<Response>

export const SOURCE_TIMEOUT_MS = 5000

export const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N} ]/gu, '').trim()

// `transient` marks a provider-side hiccup (429, 5xx, a rejected fetch, the AI
// binding failing) as opposed to something wrong with the track or the
// response. It defaults from the HTTP status; sources pass it explicitly for
// failures that carry no status. The runner backs off transient failures
// instead of spending the track's ordinary attempts on them (see failures.ts).
export class EnrichSourceError extends Error {
  readonly transient: boolean

  constructor(
    readonly source: string,
    readonly detail: string,
    readonly status?: number,
    options: { transient?: boolean } = {},
  ) {
    super(`${source}: ${detail}`)
    this.name = 'EnrichSourceError'
    this.transient = options.transient ?? (status !== undefined && (status === 429 || status >= 500))
  }
}

// A rejected fetch (timeout, abort, DNS or connection failure) names the
// request URL in its message, so only its kind travels into the detail.
export const fetchFailedDetail = (label: string, e: unknown): string =>
  `${label} (${e instanceof Error ? e.name : typeof e})`

// For a failed `res.json()`: only a SyntaxError means the body really is
// malformed (permanent). Anything else (the timeout firing mid-body, an abort,
// a dropped stream) is the provider's side and transient.
export function bodyReadError(source: string, malformedDetail: string, label: string, e: unknown): EnrichSourceError {
  return e instanceof SyntaxError
    ? new EnrichSourceError(source, malformedDetail)
    : new EnrichSourceError(source, fetchFailedDetail(label, e), undefined, { transient: true })
}
