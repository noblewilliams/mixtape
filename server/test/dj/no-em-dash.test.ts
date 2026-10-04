import { describe, it, expect } from 'vitest'
import { stripEmDashes } from '../../src/dj/sanitize'
import {
  CONFLICT_APOLOGY,
  CORPUS_NOTICE,
  CURATION_APOLOGY,
  EMPTY_LIBRARY_TEXT,
  FALLBACK_TEXT,
  FALLBACK_UNCHANGED_TEXT,
  INSUFFICIENT_SEEDS_TEXT,
  INTERNAL_APOLOGY,
  LLM_APOLOGY,
  NEW_MARKER_LEGEND,
  OUTSIDE_PERSONA_LINE,
  PERSONA_PROMPT,
  PERSONA_PROMPT_WITH_OUTSIDE,
  outsidePicksNotice,
} from '../../src/dj/loop'
import { OUTSIDE_LEGEND_LINE, OUTSIDE_SYSTEM_INTRO } from '../../src/dj/curate'
import { DJ_TOOLS_WITH_OUTSIDE } from '../../src/dj/contracts'
import { PLAYLIST_EDIT_FALLBACK, PLAYLIST_EDIT_PERSONA } from '../../src/playlist-editing/loop'

const EM = '—'

describe('stripEmDashes', () => {
  it('turns a spaced or tight em dash into a comma', () => {
    expect(stripEmDashes(`slow burn ${EM} then the drop`)).toBe('slow burn, then the drop')
    expect(stripEmDashes(`slow burn${EM}then the drop`)).toBe('slow burn, then the drop')
    expect(stripEmDashes(`a ${EM} b ${EM} c`)).toBe('a, b, c')
  })

  it('drops one at the very start or end', () => {
    expect(stripEmDashes(`${EM} here you go`)).toBe('here you go')
    expect(stripEmDashes(`here you go ${EM}`)).toBe('here you go')
    expect(stripEmDashes(`${EM}`)).toBe('')
  })

  it('never produces ", ," or a space before punctuation', () => {
    expect(stripEmDashes(`one, ${EM} two`)).toBe('one, two')
    expect(stripEmDashes(`one ${EM}, two`)).toBe('one, two')
    expect(stripEmDashes(`done. ${EM} next`)).toBe('done. next')
    expect(stripEmDashes(`wait ${EM}.`)).toBe('wait.')
    expect(stripEmDashes(`a ${EM}${EM} b`)).toBe('a, b')
    expect(stripEmDashes(`a ${EM} ${EM} b`)).toBe('a, b')
  })

  it('treats a line boundary like the start or end', () => {
    expect(stripEmDashes(`first\n${EM} second`)).toBe('first\nsecond')
    expect(stripEmDashes(`first ${EM}\nsecond`)).toBe('first\nsecond')
  })

  it('treats CRLF and an opening bracket or quote as a boundary too', () => {
    expect(stripEmDashes(`first ${EM}\r\nsecond`)).toBe('first\r\nsecond')
    expect(stripEmDashes(`first\r\n${EM} second`)).toBe('first\r\nsecond')
    expect(stripEmDashes(`(${EM} x)`)).toBe('(x)')
    expect(stripEmDashes(`"${EM} x"`)).toBe('"x"')
  })

  it('leaves en dashes, hyphens and dash-free text alone', () => {
    expect(stripEmDashes('120–140 bpm, lo-fi')).toBe('120–140 bpm, lo-fi')
    expect(stripEmDashes('just chatting.')).toBe('just chatting.')
  })
})

describe('no em dashes in canned DJ text or persona prompts', () => {
  it.each([
    ['FALLBACK_TEXT', FALLBACK_TEXT],
    ['FALLBACK_UNCHANGED_TEXT', FALLBACK_UNCHANGED_TEXT],
    ['EMPTY_LIBRARY_TEXT', EMPTY_LIBRARY_TEXT],
    ['INSUFFICIENT_SEEDS_TEXT', INSUFFICIENT_SEEDS_TEXT],
    ['CORPUS_NOTICE', CORPUS_NOTICE],
    ['CURATION_APOLOGY', CURATION_APOLOGY],
    ['CONFLICT_APOLOGY', CONFLICT_APOLOGY],
    ['LLM_APOLOGY', LLM_APOLOGY],
    ['INTERNAL_APOLOGY', INTERNAL_APOLOGY],
    ['PERSONA_PROMPT', PERSONA_PROMPT],
    ['OUTSIDE_PERSONA_LINE', OUTSIDE_PERSONA_LINE],
    ['NEW_MARKER_LEGEND', NEW_MARKER_LEGEND],
    ['outsidePicksNotice (one)', outsidePicksNotice([2])],
    ['outsidePicksNotice (several)', outsidePicksNotice([0, 5, 9])],
    ['OUTSIDE_LEGEND_LINE', OUTSIDE_LEGEND_LINE],
    ['OUTSIDE_SYSTEM_INTRO', OUTSIDE_SYSTEM_INTRO],
    ['allowOutside description', JSON.stringify(
      (DJ_TOOLS_WITH_OUTSIDE.find((t) => t.name === 'generate_queue')!.input_schema.properties as Record<string, unknown>).allowOutside,
    )],
    ['PLAYLIST_EDIT_FALLBACK', PLAYLIST_EDIT_FALLBACK],
    ['PLAYLIST_EDIT_PERSONA', PLAYLIST_EDIT_PERSONA],
  ])('%s', (_name, text) => {
    expect(text).not.toContain(EM)
  })

  it('both personas tell the model not to use them', () => {
    expect(PERSONA_PROMPT).toMatch(/em dash/i)
    expect(PERSONA_PROMPT_WITH_OUTSIDE).toMatch(/em dash/i)
    expect(PLAYLIST_EDIT_PERSONA).toMatch(/em dash/i)
  })
})
