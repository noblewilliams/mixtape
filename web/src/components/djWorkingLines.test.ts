import { describe, expect, it } from 'vitest'
import type { TurnProgress, TurnStepProgress } from '../api/client'
import {
  DWELL_MS,
  LISTENING_LINE,
  STILL_LINE,
  TIMED_MIX_PHASES,
  knowsStep,
  nextWorkingLineAt,
  nextWorkingStep,
  settleLine,
  stepLineAt,
  timedLineAt,
  untilNextStepLine,
  untilNextTimedLine,
  workingLineAt,
  type ShownLine,
  type WorkingStep,
} from './djWorkingLines'

const step = (name: string, fields: Omit<TurnStepProgress, 'type' | 'step'> = {}): TurnStepProgress => ({ type: 'step', step: name, ...fields })
const S = 1000

describe('the timed walk (no stream)', () => {
  it('is the iOS mix list, phase for phase', () => {
    expect(TIMED_MIX_PHASES).toEqual([
      { from: 0, lines: ['The DJ is listening…'] },
      { from: 4 * S, lines: ['Digging through the crates…', 'Flipping through your records…', 'Thumbing through the stacks…'] },
      { from: 11 * S, lines: ['Pulling records that fit…', 'Checking the tempos…', 'Cueing up contenders…'] },
      { from: 20 * S, lines: ['Sequencing the tracklist…', 'Working the crossfader…', 'Lining up the transitions…'] },
      { from: 32 * S, lines: ['Pressing the tape…', 'Labelling the cassette…', 'Spooling it up…'] },
      { from: 50 * S, lines: ['Still at the decks. Worth the wait…'] },
    ])
  })

  it('walks the phases on the clock, one line per phase picked by the seed', () => {
    expect(timedLineAt(0, 0)).toBe(LISTENING_LINE)
    expect(timedLineAt(4 * S - 1, 0)).toBe(LISTENING_LINE)
    expect(timedLineAt(4 * S, 0)).toBe('Flipping through your records…')
    expect(timedLineAt(4 * S, 2)).toBe('Digging through the crates…')
    expect(timedLineAt(11 * S, 0)).toBe('Cueing up contenders…')
    expect(timedLineAt(20 * S, 0)).toBe('Sequencing the tracklist…')
    expect(timedLineAt(32 * S, 0)).toBe('Labelling the cassette…')
    expect(timedLineAt(50 * S, 0)).toBe(STILL_LINE)
    expect(timedLineAt(500 * S, 7)).toBe(STILL_LINE)
  })

  it('says when the line next changes, and nothing once it holds', () => {
    expect(untilNextTimedLine(0)).toBe(4 * S)
    expect(untilNextTimedLine(4 * S)).toBe(7 * S)
    expect(untilNextTimedLine(49 * S)).toBe(1 * S)
    expect(untilNextTimedLine(50 * S)).toBeNull()
  })

  it('runs from when the turn went out while no stream has opened', () => {
    const work = { startedAt: 100 * S, step: null }
    expect(workingLineAt(work, 100 * S, 0)).toBe(LISTENING_LINE)
    expect(workingLineAt(work, 105 * S, 0)).toBe('Flipping through your records…')
    expect(nextWorkingLineAt(work, 105 * S)).toBe(111 * S)
    expect(nextWorkingLineAt(work, 160 * S)).toBeNull()
  })
})

describe('once the stream opens', () => {
  const opened: WorkingStep = { step: null, at: 3 * S }

  it('stops the clock and holds listening until the first step, the still line from 30 s after it opened', () => {
    const work = { startedAt: 0, step: opened }
    expect(workingLineAt(work, 3 * S, 0)).toBe(LISTENING_LINE)
    // The timed walk would be on its third phase here.
    expect(workingLineAt(work, 12 * S, 0)).toBe(LISTENING_LINE)
    expect(nextWorkingLineAt(work, 12 * S)).toBe(33 * S)
    expect(workingLineAt(work, 33 * S - 1, 0)).toBe(LISTENING_LINE)
    expect(workingLineAt(work, 33 * S, 0)).toBe(STILL_LINE)
    expect(nextWorkingLineAt(work, 33 * S)).toBeNull()
  })

  it('shows each step from when it arrived', () => {
    const work = { startedAt: 0, step: { step: step('pressing'), at: 40 * S } }
    expect(workingLineAt(work, 41 * S, 1)).toBe('Pressing the tape…')
    expect(workingLineAt(work, 41 * S, 0)).toBe('Spooling it up…')
    expect(nextWorkingLineAt(work, 41 * S)).toBe(70 * S)
  })
})

describe('step lines', () => {
  it.each([
    ['playlists', {}, ['Looking through your playlists…', 'Pulling that playlist off the shelf…']],
    ['digging', { scope: 'library' }, ['Flipping through your records…', 'Thumbing through your stacks…']],
    ['digging', { scope: 'catalogue' }, ['Digging through the crates…', 'Crate-digging for you…']],
    ['picking', {}, ['Pulling records that fit…', 'Cueing up contenders…']],
    ['checking', {}, ['Checking the pressings…', 'Giving it a sound check…']],
    ['editing', {}, ['Reworking the tracklist…', 'Swapping records…']],
    ['pressing', {}, ['Pressing the tape…', 'Spooling it up…']],
    ['labelling', {}, ['Labelling the cassette…']],
    ['noting', {}, ['Jotting that on the sleeve…']],
    ['writing', {}, ['Writing the liner notes…']],
    ['listening', {}, ['The DJ is listening…']],
  ] as const)('%s %o says one of its nameless lines, picked by the seed', (name, fields, lines) => {
    const said = new Set([0, 1, 2, 3, 4, 5].map((seed) => stepLineAt(step(name, fields), 0, seed)))
    expect([...said].sort()).toEqual([...lines].sort())
  })

  it('picks the same line for a step all turn long', () => {
    expect(stepLineAt(step('picking'), 0, 41)).toBe(stepLineAt(step('picking'), 11 * S, 41))
  })

  it('reads a digging step with no known scope as the catalogue', () => {
    for (const seed of [0, 1]) {
      expect(stepLineAt(step('digging'), 0, seed)).toBe(stepLineAt(step('digging', { scope: 'catalogue' }), 0, seed))
      expect(stepLineAt(step('digging', { scope: 'moon' }), 0, seed)).toBe(stepLineAt(step('digging', { scope: 'catalogue' }), 0, seed))
    }
    expect(stepLineAt(step('digging', { scope: 'moon' }), 12 * S, 0)).toBe('Deeper in the crates…')
  })

  it('knows the table’s steps, and no others', () => {
    for (const name of ['listening', 'playlists', 'digging', 'picking', 'checking', 'editing', 'pressing', 'labelling', 'noting', 'writing']) {
      expect(knowsStep(step(name))).toBe(true)
    }
    expect(knowsStep(step('tuning'))).toBe(false)
  })
})

describe('named lines', () => {
  const both = (fields: Omit<TurnStepProgress, 'type' | 'step'>, name: string) => [0, 1].map((seed) => stepLineAt(step(name, fields), 0, seed)).sort()

  it('names the artists: one, two, or two and more', () => {
    expect(both({ scope: 'catalogue', artists: ['Tems'] }, 'digging')).toEqual(['Crate-digging for Tems…', 'Digging for Tems…'])
    expect(both({ scope: 'catalogue', artists: ['Tems', 'Asake'] }, 'digging')).toEqual(['Crate-digging for Tems and Asake…', 'Digging for Tems and Asake…'])
    expect(both({ scope: 'catalogue', artists: ['Tems', 'Asake', 'Rema', 'Wizkid'] }, 'digging')).toEqual(['Crate-digging for Tems, Asake and more…', 'Digging for Tems, Asake and more…'])
    expect(both({ scope: 'library', artists: ['Sade'] }, 'digging')).toEqual(['Flipping through your Sade records…', 'Pulling your Sade records…'])
    expect(both({ artists: ['Sade'] }, 'picking')).toEqual(['Finding company for Sade…', 'Pulling records that sit with Sade…'])
  })

  it('names at most two genres on the sound check', () => {
    expect(stepLineAt(step('checking', { genres: ['Afrobeats'] }), 0, 0)).toBe('Running the Afrobeats sound check…')
    expect(stepLineAt(step('checking', { genres: ['Jazz', 'Soul', 'Funk'] }), 0, 1)).toBe('Running the Jazz and Soul sound check…')
  })

  it('quotes the playlist and the title in curly quotes', () => {
    expect(stepLineAt(step('playlists', { playlist: 'Sunday' }), 0, 0)).toBe('Pulling “Sunday” off the shelf…')
    expect(stepLineAt(step('labelling', { title: 'Blue hour' }), 0, 0)).toBe('Labelling it “Blue hour”…')
  })

  it('counts the songs pressed, "one song" for one, and drops a count below one', () => {
    expect(stepLineAt(step('pressing', { count: 15 }), 0, 0)).toBe('Pressing 15 songs to tape…')
    expect(stepLineAt(step('pressing', { count: 1 }), 0, 0)).toBe('Pressing one song to tape…')
    expect(both({ count: 0 }, 'pressing')).toEqual(['Pressing the tape…', 'Spooling it up…'])
    expect(both({ count: -3 }, 'pressing')).toEqual(['Pressing the tape…', 'Spooling it up…'])
  })

  it('ignores names a step does not carry in the table', () => {
    expect(both({ artists: ['Tems'] }, 'editing')).toEqual(['Reworking the tracklist…', 'Swapping records…'])
    expect(stepLineAt(step('noting', { title: 'x' }), 0, 0)).toBe('Jotting that on the sleeve…')
  })

  it('says the nameless line when the named one would run past 44 characters', () => {
    const fits = 'Labelling it “' + 'x'.repeat(28) + '”…'
    expect(fits).toHaveLength(44)
    expect(stepLineAt(step('labelling', { title: 'x'.repeat(28) }), 0, 0)).toBe(fits)
    expect(stepLineAt(step('labelling', { title: 'x'.repeat(29) }), 0, 0)).toBe('Labelling the cassette…')
    // "Pulling records that sit with Tems and Asake…" is 45: its nameless line, while the other pick fits.
    const lines = [0, 1].map((seed) => stepLineAt(step('picking', { artists: ['Tems', 'Asake'] }), 0, seed)).sort()
    expect(lines).toEqual(['Finding company for Tems and Asake…', 'Pulling records that fit…'])
  })

  it('holds its later lines and the still line whatever the names', () => {
    expect(stepLineAt(step('picking', { artists: ['Tems'] }), 12 * S, 0)).toBe('Sequencing the tracklist…')
    expect(stepLineAt(step('labelling', { title: 'Blue hour' }), 30 * S, 0)).toBe(STILL_LINE)
  })
})

describe('the in-step clock', () => {
  it('walks a step’s later lines in order, 12 s apart, then the still line at 30 s', () => {
    const picking = step('picking')
    expect(stepLineAt(picking, 12 * S - 1, 0)).toBe('Pulling records that fit…')
    expect(stepLineAt(picking, 12 * S, 0)).toBe('Sequencing the tracklist…')
    expect(stepLineAt(picking, 24 * S, 0)).toBe('Lining up the transitions…')
    expect(stepLineAt(picking, 30 * S, 0)).toBe(STILL_LINE)
    expect(untilNextStepLine(picking, 0)).toBe(12 * S)
    expect(untilNextStepLine(picking, 12 * S)).toBe(12 * S)
    expect(untilNextStepLine(picking, 24 * S)).toBe(6 * S)
    expect(untilNextStepLine(picking, 30 * S)).toBeNull()
  })

  it('holds a step’s one later line until the still line', () => {
    const library = step('digging', { scope: 'library' })
    expect(stepLineAt(library, 12 * S, 1)).toBe('Still flipping…')
    expect(stepLineAt(library, 24 * S, 1)).toBe('Still flipping…')
    expect(untilNextStepLine(library, 12 * S)).toBe(18 * S)
    expect(stepLineAt(step('digging', { scope: 'catalogue' }), 12 * S, 0)).toBe('Deeper in the crates…')
  })

  it('holds a step with no later lines until the still line', () => {
    expect(stepLineAt(step('editing'), 29 * S, 0)).toBe(stepLineAt(step('editing'), 0, 0))
    expect(untilNextStepLine(step('editing'), 0)).toBe(30 * S)
    expect(stepLineAt(step('editing'), 30 * S, 0)).toBe(STILL_LINE)
  })
})

describe('following the progress', () => {
  it('starts listening when the stream opens, and only then', () => {
    expect(nextWorkingStep(null, { type: 'opened' }, 5 * S)).toEqual({ step: null, at: 5 * S })
    const current: WorkingStep = { step: step('picking'), at: 2 * S }
    expect(nextWorkingStep(current, { type: 'opened' }, 5 * S)).toBe(current)
  })

  it('takes a known step with its arrival time', () => {
    const picking = step('picking', { artists: ['Tems'] })
    expect(nextWorkingStep({ step: null, at: 0 }, picking, 9 * S)).toEqual({ step: picking, at: 9 * S })
  })

  it('ignores an unknown step, the session event, and the same step again (its clock keeps running)', () => {
    const current: WorkingStep = { step: step('digging', { scope: 'catalogue', artists: ['Tems'] }), at: 2 * S }
    const same: TurnProgress = step('digging', { scope: 'catalogue', artists: ['Tems'] })
    expect(nextWorkingStep(current, step('tuning'), 5 * S)).toBe(current)
    expect(nextWorkingStep(current, { type: 'session', sessionId: 's' }, 5 * S)).toBe(current)
    expect(nextWorkingStep(current, same, 5 * S)).toBe(current)
    expect(nextWorkingStep(null, step('tuning'), 5 * S)).toBeNull()
  })

  it('takes the same step with other names as a new one', () => {
    const current: WorkingStep = { step: step('picking'), at: 2 * S }
    expect(nextWorkingStep(current, step('picking', { artists: ['Tems'] }), 5 * S)).toEqual({ step: step('picking', { artists: ['Tems'] }), at: 5 * S })
  })

  it('takes a step that comes before the opened event (opened is implied)', () => {
    expect(nextWorkingStep(null, step('writing'), 5 * S)).toEqual({ step: step('writing'), at: 5 * S })
  })
})

describe('the dwell', () => {
  it('shows the first line at once and holds a line at least 1.5 s', () => {
    const first = settleLine(null, 'A', 0)
    expect(first).toEqual({ shown: { line: 'A', since: 0 }, wakeAt: null })
    const held = settleLine(first.shown, 'B', 500)
    expect(held).toEqual({ shown: first.shown, wakeAt: DWELL_MS })
    expect(held.shown).toBe(first.shown)
    expect(settleLine(first.shown, 'B', DWELL_MS)).toEqual({ shown: { line: 'B', since: DWELL_MS }, wakeAt: null })
  })

  it('keeps the same object when nothing changes', () => {
    const shown: ShownLine = { line: 'A', since: 0 }
    expect(settleLine(shown, 'A', 300).shown).toBe(shown)
    expect(settleLine(shown, 'A', 300).wakeAt).toBeNull()
    expect(settleLine(shown, 'A', 9 * S).shown).toBe(shown)
  })

  it('skips a step overtaken while the line held, so a 50 ms step never flashes', () => {
    // pressing at 0; noting at 300 ms; writing 50 ms later. Each arrival and wake settles again.
    const seed = 0
    const at = (now: number, current: WorkingStep) => workingLineAt({ startedAt: 0, step: current }, now, seed)
    let current: WorkingStep = { step: step('pressing', { count: 12 }), at: 0 }
    let state = settleLine(null, at(0, current), 0)
    const seen = [state.shown.line]
    current = nextWorkingStep(current, step('noting'), 300)!
    state = settleLine(state.shown, at(300, current), 300)
    current = nextWorkingStep(current, step('writing'), 350)!
    state = settleLine(state.shown, at(350, current), 350)
    expect(state.wakeAt).toBe(DWELL_MS)
    state = settleLine(state.shown, at(DWELL_MS, current), DWELL_MS)
    seen.push(state.shown.line)
    expect(seen).toEqual(['Pressing 12 songs to tape…', 'Writing the liner notes…'])
  })
})
