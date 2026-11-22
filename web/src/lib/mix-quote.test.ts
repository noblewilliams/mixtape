import { describe, expect, it } from 'vitest'
import { composeQuotedMessage, quoteLabel, quoteLine, parseQuoteLine, sameSong, splitQuotedMessage } from './mix-quote'

const terminator = { title: 'Terminator', artist: 'Asake', trackId: 't1' }
const calm = { title: 'Calm Down', artist: 'Rema', trackId: 't2' }

describe('mix quotes', () => {
  it('writes the same `> Title — Artist` line iOS sends', () => {
    expect(quoteLine(terminator)).toBe('> Terminator — Asake')
    expect(quoteLabel(terminator)).toBe('Terminator · Asake')
    expect(quoteLabel({ title: 'Untitled', artist: '' })).toBe('Untitled')
  })

  it('puts one quote line per song before the words', () => {
    expect(composeQuotedMessage([terminator, calm], '  too fast  ')).toBe('> Terminator — Asake\n> Calm Down — Rema\ntoo fast')
    expect(composeQuotedMessage([], ' as is ')).toBe('as is')
    expect(composeQuotedMessage([terminator], '')).toBe('> Terminator — Asake')
  })

  it('reads the quotes back out of a sent message', () => {
    expect(splitQuotedMessage('> Terminator — Asake\n> Calm Down — Rema\ntoo fast')).toEqual({
      quotes: [{ title: 'Terminator', artist: 'Asake' }, { title: 'Calm Down', artist: 'Rema' }],
      text: 'too fast',
    })
    expect(splitQuotedMessage('no quotes\n> later')).toEqual({ quotes: [], text: 'no quotes\n> later' })
  })

  it('splits on the last dash, so a title with one keeps it', () => {
    expect(parseQuoteLine('> Love — Again — Dua Lipa')).toEqual({ title: 'Love — Again', artist: 'Dua Lipa' })
    expect(parseQuoteLine('> Just a title')).toEqual({ title: 'Just a title', artist: '' })
    expect(parseQuoteLine('>   ')).toBeNull()
    expect(parseQuoteLine('plain')).toBeNull()
  })

  it('matches by row when both have one, else by title and artist', () => {
    expect(sameSong(terminator, { ...terminator, trackId: 'other' })).toBe(false)
    expect(sameSong(terminator, { title: 'Terminator', artist: 'Asake' })).toBe(true)
  })
})
