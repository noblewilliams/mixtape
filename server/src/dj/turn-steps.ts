import { sanitizeTitleText } from './sanitize'

// The DJ's working steps (spec 2026-11-13 dj-turn-steps), reported while a
// turn runs so the apps' working line follows the turn's real work rather
// than a clock. Closed here, open on the clients: a client ignores a step it
// does not know. `listening` is never sent; clients start on it.
export type TurnStep = 'playlists' | 'digging' | 'picking' | 'checking' | 'editing' | 'pressing' | 'labelling' | 'noting' | 'writing'

// Names are only ones the listener already said or sees (spec, "Names"):
// artists on digging and picking, genres on the genre sound check, the
// chosen playlist, the mix's new title, a song count. Never lyrics, track
// lists, memory notes or search queries. Steps are never logged.
export type TurnStepEvent = {
  step: TurnStep
  scope?: 'library' | 'catalogue'
  artists?: string[]
  genres?: string[]
  playlist?: string
  title?: string
  count?: number
}

// One caption line holds a name or two; the clients fall back to the
// nameless line past 44 characters.
export const STEP_NAME_MAX = 40
const STEP_ARTISTS_MAX = 3
const STEP_GENRES_MAX = 2

function cleanName(name: string | undefined): string | undefined {
  const clean = name ? sanitizeTitleText(name, STEP_NAME_MAX) : ''
  return clean === '' ? undefined : clean
}

// The first `max` names, cleaned; one that cleans to nothing is dropped,
// and a list left empty is omitted rather than sent as [].
function cleanNames(names: string[] | undefined, max: number): string[] | undefined {
  const clean = (names ?? []).slice(0, max).flatMap((n) => cleanName(n) ?? [])
  return clean.length > 0 ? clean : undefined
}

/** The event as sent: every name cleaned with sanitizeTitleText(_, 40), empty fields omitted, in a fixed key order. */
export function cleanStepEvent(event: TurnStepEvent): TurnStepEvent {
  const artists = cleanNames(event.artists, STEP_ARTISTS_MAX)
  const genres = cleanNames(event.genres, STEP_GENRES_MAX)
  const playlist = cleanName(event.playlist)
  const title = cleanName(event.title)
  return {
    step: event.step,
    ...(event.scope ? { scope: event.scope } : {}),
    ...(artists ? { artists } : {}),
    ...(genres ? { genres } : {}),
    ...(playlist ? { playlist } : {}),
    ...(title ? { title } : {}),
    ...(event.count !== undefined ? { count: event.count } : {}),
  }
}

export type BriefNames = { onlyArtist?: string; namedArtists?: string[] }

/** The artists a brief's steps name: its artist-only scope, or else the first three it names, as the DJ spelled them. */
export function briefArtists(brief: BriefNames): string[] {
  return brief.onlyArtist ? [brief.onlyArtist] : (brief.namedArtists ?? []).slice(0, STEP_ARTISTS_MAX)
}

/**
 * The brief's names without `artist`, compared trimmed and case-insensitively.
 * An artist-only brief whose artist is nowhere falls back to a mix of the
 * rest, and the model usually repeats that artist among its named ones: the
 * fallback's steps must not name the artist the DJ is about to say it could
 * not find. Names only; the intent curated is unchanged.
 */
export function briefWithoutArtist(brief: BriefNames, artist: string): BriefNames {
  const gone = artist.trim().toLowerCase()
  const kept = (name: string) => name.trim().toLowerCase() !== gone
  return {
    ...(brief.onlyArtist && kept(brief.onlyArtist) ? { onlyArtist: brief.onlyArtist } : {}),
    namedArtists: (brief.namedArtists ?? []).filter(kept),
  }
}

// The per-turn reporter (DjDeps.step). Callable to report a step; `brief`
// sets whose artists digging and picking carry, so the deps wrapper that
// reports picking for every curate and propose call needs no names of its
// own. The loop resets the brief at every tool call, so an edit never names
// a generate's artists. `close` ends the turn's reporting: work the turn
// left running (an early shortfall call the curation made unnecessary, and
// its truncation retry) can still reach the deps after the turn is decided,
// and the route has written its result by then.
export type TurnStepReporter = {
  (event: TurnStepEvent): void
  brief(brief: BriefNames | undefined): void
  close(): void
}

/**
 * Wraps the route's onStep for one turn. It never throws into the turn: a
 * sync throw is caught and a returned rejected promise is swallowed. An
 * event identical to the one before it is dropped, so a blend's curate and
 * propose calls, starting side by side, report one picking. After close,
 * every report is dropped.
 */
export function turnStepReporter(onStep: (event: TurnStepEvent) => void): TurnStepReporter {
  let artists: string[] | undefined
  let last: string | undefined
  let closed = false
  const report = (event: TurnStepEvent): void => {
    if (closed) return
    try {
      const named = event.step === 'digging' || event.step === 'picking' ? { ...event, artists: event.artists ?? artists } : event
      const clean = cleanStepEvent(named)
      const key = JSON.stringify(clean)
      if (key === last) return
      last = key
      // Typed void, but an async listener still type-checks as one.
      const sent: unknown = onStep(clean)
      if (typeof (sent as PromiseLike<unknown> | undefined)?.then === 'function') {
        ;(sent as PromiseLike<unknown>).then(undefined, () => {})
      }
    } catch {
      // A caption never fails the turn.
    }
  }
  return Object.assign(report, {
    brief(brief: BriefNames | undefined) {
      artists = brief ? briefArtists(brief) : undefined
    },
    close() {
      closed = true
    },
  })
}
