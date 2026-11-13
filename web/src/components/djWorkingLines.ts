import type { TurnProgress, TurnStepProgress } from '../api/client'

/**
 * What the DJ's working line says as a mix turn goes on (spec
 * `docs/superpowers/specs/2026-11-13-dj-turn-steps-design.md`, "Copy"; the iOS
 * `DjWorkingPhrases` in `lyric_turn.dart` follows the same rules). Pure: the
 * table and the rules, with every time in milliseconds. The timers live in
 * `useDjWorkingLine`.
 *
 * Until a turn's stream opens (the headers are not back, or an older server
 * answered JSON) the line walks the timed phases on the clock. Once it opens
 * the clock stops: listening holds until the first step, then each step says
 * its line, its later lines 12 s apart, and the still line from 30 s. Each
 * line holds at least 1.5 s ({@link settleLine}). Names are only ever ones the
 * listener said or sees, and land in a plain text node.
 */

export const LISTENING_LINE = 'The DJ is listening…'
export const STILL_LINE = 'Still at the decks. Worth the wait…'
/** How long each of a step's later lines holds. */
export const STEP_CLOCK_MS = 12_000
/** A step (listening included) this long says the still line, whatever it is. */
export const STILL_AFTER_MS = 30_000
/** The least time a line shows before another takes over, so a 50 ms step never flashes. */
export const DWELL_MS = 1_500
/** The longest a line with names may run; past it the step says its nameless line. */
export const MAX_NAMED_LENGTH = 44

/**
 * The timed walk, for a turn that reports nothing (the iOS `DjWorkingPhrases.mix`).
 * The first line is always the same; each later phase picks one of its lines
 * by seed, so a turn reads differently from the last one but never changes its
 * mind about a phase it is in.
 */
export const TIMED_MIX_PHASES: ReadonlyArray<{ from: number; lines: readonly string[] }> = [
  { from: 0, lines: [LISTENING_LINE] },
  { from: 4_000, lines: ['Digging through the crates…', 'Flipping through your records…', 'Thumbing through the stacks…'] },
  { from: 11_000, lines: ['Pulling records that fit…', 'Checking the tempos…', 'Cueing up contenders…'] },
  { from: 20_000, lines: ['Sequencing the tracklist…', 'Working the crossfader…', 'Lining up the transitions…'] },
  { from: 32_000, lines: ['Pressing the tape…', 'Labelling the cassette…', 'Spooling it up…'] },
  { from: 50_000, lines: [STILL_LINE] },
]

/**
 * Where a streamed turn has got to: the latest step it reported (null: the
 * stream opened and no step has come, so the DJ is listening) and when it
 * arrived, on this device's clock.
 */
export type WorkingStep = { step: TurnStepProgress | null; at: number }

/** A mix turn in flight: when it went out, and its step once its stream opened (null before). */
export type TurnWork = { startedAt: number; step: WorkingStep | null }

function phaseAt(elapsed: number): number {
  let index = 0
  TIMED_MIX_PHASES.forEach((phase, i) => {
    if (elapsed >= phase.from) index = i
  })
  return index
}

/** The timed line `elapsed` into a turn. */
export function timedLineAt(elapsed: number, seed: number): string {
  const index = phaseAt(elapsed)
  const { lines } = TIMED_MIX_PHASES[index]
  return lines[(seed + index) % lines.length]
}

/** How long after `elapsed` the timed line next changes; null once it holds. */
export function untilNextTimedLine(elapsed: number): number | null {
  const next = TIMED_MIX_PHASES[phaseAt(elapsed) + 1]
  return next ? next.from - elapsed : null
}

/** A step's nameless lines: one of `first` picked per turn, then each of `later` in turn, 12 s apart. */
type StepLines = { order: number; first: readonly string[]; later: readonly string[] }

/** Each step's nameless lines, with its place in the table (so a seed picks differently from one step to the next). */
function linesFor(step: TurnStepProgress | null): StepLines | null {
  const lines = (order: number, first: readonly string[], later: readonly string[] = []) => ({ order, first, later })
  switch (step?.step) {
    case undefined:
    case 'listening':
      return lines(0, [LISTENING_LINE])
    case 'playlists':
      return lines(1, ['Looking through your playlists…', 'Pulling that playlist off the shelf…'])
    case 'digging':
      return step.scope === 'library'
        ? lines(2, ['Flipping through your records…', 'Thumbing through your stacks…'], ['Still flipping…'])
        // The catalogue, and a scope this build does not know.
        : lines(3, ['Digging through the crates…', 'Crate-digging for you…'], ['Deeper in the crates…'])
    case 'picking':
      return lines(4, ['Pulling records that fit…', 'Cueing up contenders…'], ['Sequencing the tracklist…', 'Lining up the transitions…'])
    case 'checking':
      return lines(5, ['Checking the pressings…', 'Giving it a sound check…'])
    case 'editing':
      return lines(6, ['Reworking the tracklist…', 'Swapping records…'])
    case 'pressing':
      return lines(7, ['Pressing the tape…', 'Spooling it up…'])
    case 'labelling':
      return lines(8, ['Labelling the cassette…'])
    case 'noting':
      return lines(9, ['Jotting that on the sleeve…'])
    case 'writing':
      return lines(10, ['Writing the liner notes…'])
    default:
      return null
  }
}

/** Whether the line has words for `step`. It keeps its current line through any other (the server may add steps). */
export function knowsStep(step: TurnStepProgress): boolean {
  return linesFor(step) !== null
}

/** "A", "A and B", or past two "A, B and more"; with `most` 2, the first two only. */
function nameList(names: readonly string[] | undefined, most: number): string | null {
  const kept = (names ?? []).slice(0, most)
  if (kept.length === 0) return null
  if (kept.length === 1) return kept[0]
  if (kept.length === 2) return `${kept[0]} and ${kept[1]}`
  return `${kept[0]}, ${kept[1]} and more`
}

/** The step's line with the names it carries, or null when it carries none. */
function namedLine(step: TurnStepProgress, pick: number): string | null {
  const one = (lines: string[]) => lines[pick % lines.length]
  switch (step.step) {
    case 'digging': {
      const artists = nameList(step.artists, 3)
      if (!artists) return null
      return step.scope === 'library'
        ? one([`Flipping through your ${artists} records…`, `Pulling your ${artists} records…`])
        : one([`Digging for ${artists}…`, `Crate-digging for ${artists}…`])
    }
    case 'picking': {
      const artists = nameList(step.artists, 3)
      return artists ? one([`Pulling records that sit with ${artists}…`, `Finding company for ${artists}…`]) : null
    }
    case 'checking': {
      const genres = nameList(step.genres, 2)
      return genres ? `Running the ${genres} sound check…` : null
    }
    case 'playlists':
      return step.playlist ? `Pulling “${step.playlist}” off the shelf…` : null
    case 'labelling':
      return step.title ? `Labelling it “${step.title}”…` : null
    case 'pressing': {
      const count = step.count
      if (count === undefined || count < 1) return null
      return count === 1 ? 'Pressing one song to tape…' : `Pressing ${count} songs to tape…`
    }
    default:
      return null
  }
}

/** The line `inStep` into `step` (null: the stream opened and nothing has come yet). `seed` picks one line per step. */
export function stepLineAt(step: TurnStepProgress | null, inStep: number, seed: number): string {
  if (inStep >= STILL_AFTER_MS) return STILL_LINE
  const lines = linesFor(step) ?? linesFor(null)!
  const later = Math.floor(Math.max(0, inStep) / STEP_CLOCK_MS)
  if (later > 0 && lines.later.length > 0) return lines.later[Math.min(later, lines.later.length) - 1]
  const pick = seed + lines.order
  const named = step ? namedLine(step, pick) : null
  if (named !== null && named.length <= MAX_NAMED_LENGTH) return named
  return lines.first[pick % lines.first.length]
}

/** How long after `inStep` the step's line next changes; null once it holds. */
export function untilNextStepLine(step: TurnStepProgress | null, inStep: number): number | null {
  if (inStep >= STILL_AFTER_MS) return null
  const lines = linesFor(step) ?? linesFor(null)!
  for (let i = 1; i <= lines.later.length; i += 1) {
    const at = STEP_CLOCK_MS * i
    if (at >= STILL_AFTER_MS) break
    if (at > inStep) return at - inStep
  }
  return STILL_AFTER_MS - inStep
}

function sameNames(a: readonly string[] | undefined, b: readonly string[] | undefined): boolean {
  if (!a || !b) return a === b
  return a.length === b.length && a.every((name, i) => name === b[i])
}

function sameStep(a: TurnStepProgress, b: TurnStepProgress): boolean {
  return a.step === b.step && a.scope === b.scope && sameNames(a.artists, b.artists) && sameNames(a.genres, b.genres)
    && a.playlist === b.playlist && a.title === b.title && a.count === b.count
}

/**
 * `current` once `progress` has arrived at `now`; `current` itself when the
 * progress changes nothing: a step not in the table, the same step again (its
 * clock keeps running), the create's session id, or a second open.
 */
export function nextWorkingStep(current: WorkingStep | null, progress: TurnProgress, now: number): WorkingStep | null {
  if (progress.type === 'opened') return current ?? { step: null, at: now }
  if (progress.type !== 'step' || !knowsStep(progress)) return current
  if (current?.step && sameStep(current.step, progress)) return current
  return { step: progress, at: now }
}

/** The line the clock or the step calls for at `now`. */
export function workingLineAt(work: TurnWork, now: number, seed: number): string {
  if (!work.step) return timedLineAt(Math.max(0, now - work.startedAt), seed)
  return stepLineAt(work.step.step, Math.max(0, now - work.step.at), seed)
}

/** When (absolute, ms) the line {@link workingLineAt} calls for next changes on its own; null once it holds. */
export function nextWorkingLineAt(work: TurnWork, now: number): number | null {
  const wait = work.step
    ? untilNextStepLine(work.step.step, Math.max(0, now - work.step.at))
    : untilNextTimedLine(Math.max(0, now - work.startedAt))
  return wait === null ? null : now + wait
}

/** The line on show, and since when. */
export type ShownLine = { line: string; since: number }

/**
 * Puts up `target` unless the line on show has not held {@link DWELL_MS} yet.
 * While it holds, `wakeAt` is when to look again, with whatever the target is
 * by then: a step overtaken meanwhile never shows. `shown` is the same object
 * when nothing changed.
 */
export function settleLine(shown: ShownLine | null, target: string, now: number): { shown: ShownLine; wakeAt: number | null } {
  if (!shown) return { shown: { line: target, since: now }, wakeAt: null }
  if (shown.line === target) return { shown, wakeAt: null }
  if (now - shown.since < DWELL_MS) return { shown, wakeAt: shown.since + DWELL_MS }
  return { shown: { line: target, since: now }, wakeAt: null }
}
