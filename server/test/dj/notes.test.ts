import { describe, it, expect } from 'vitest'
import { dropRepeatedNotes, noteKey } from '../../src/dj/notes'

// Spec 2026-11-09 every-song-earns-its-place, decision 7: a note already in
// the queue is never shown twice.
describe('noteKey', () => {
  it('folds case, whitespace and punctuation', () => {
    expect(noteKey('  The comedown,  after that RUN. ')).toBe(noteKey('the comedown after that run'))
    expect(noteKey('It’s a slow-burn opener!')).toBe(noteKey("its a slow burn opener"))
  })

  it('keeps different words different', () => {
    expect(noteKey('the comedown after that run')).not.toBe(noteKey('the comedown after that song'))
  })

  it('is empty for an empty, punctuation-only or absent note', () => {
    expect(noteKey('')).toBe('')
    expect(noteKey(' ... ')).toBe('')
    expect(noteKey(null)).toBe('')
  })
})

describe('dropRepeatedNotes', () => {
  const row = (trackId: string, reason: string | null) => ({ trackId, reason })

  it('blanks a later repeat within one list and keeps the first', () => {
    const out = dropRepeatedNotes([
      row('a', 'The comedown after that run.'),
      row('b', 'Brushed drums keep the room low.'),
      row('c', 'the comedown, after that run'),
      row('d', 'THE COMEDOWN AFTER THAT RUN'),
    ])
    expect(out.map((r) => r.reason)).toEqual(['The comedown after that run.', 'Brushed drums keep the room low.', '', ''])
    expect(out.map((r) => r.trackId)).toEqual(['a', 'b', 'c', 'd'])
  })

  it('blanks a note the queue already shows', () => {
    const out = dropRepeatedNotes([row('a', 'The comedown after that run'), row('b', 'A new thing to say')], ['the comedown after that run!'])
    expect(out.map((r) => r.reason)).toEqual(['', 'A new thing to say'])
  })

  it('leaves empty and null notes as they are and never matches them', () => {
    const out = dropRepeatedNotes([row('a', ''), row('b', null), row('c', ''), row('d', null)], ['', null])
    expect(out.map((r) => r.reason)).toEqual(['', null, '', null])
  })

  it('keeps the other fields and does not mutate its input', () => {
    const input = [{ trackId: 'a', reason: 'x y z', position: 3 }, { trackId: 'b', reason: 'X Y Z', position: 4 }]
    const out = dropRepeatedNotes(input)
    expect(out).toEqual([{ trackId: 'a', reason: 'x y z', position: 3 }, { trackId: 'b', reason: '', position: 4 }])
    expect(input[1].reason).toBe('X Y Z')
  })
})
