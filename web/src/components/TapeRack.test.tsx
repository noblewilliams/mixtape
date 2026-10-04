import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { demoSessions } from '../data/demo'
import { TapeRack } from './TapeRack'

afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })
it.each([0.1, 0.9])('keeps the bird outside the tape collection with seed %s', seed => {
  vi.spyOn(Math, 'random').mockReturnValue(seed)
  const { container, rerender } = render(<TapeRack sessions={demoSessions} onOpenSession={vi.fn()} />)
  const bird = container.querySelector('.rack-bird')!
  const row = bird.parentElement!
  const children = Array.from(row.children)
  const tapes = children.filter(el => el.classList.contains('rack-tape'))
  expect(children.indexOf(bird) < children.indexOf(tapes[0]) || children.indexOf(bird) > children.indexOf(tapes.at(-1)!)).toBe(true)
  rerender(<TapeRack sessions={[...demoSessions]} onOpenSession={vi.fn()} />)
  expect(container.querySelector('.rack-bird')).toBe(bird)
})
it('opens the real mix and respects its selected colour', () => {
  const open = vi.fn()
  const session = { ...demoSessions[0], caseColor: '#b84755' }
  render(<TapeRack sessions={[session]} onOpenSession={open} />)
  const tape = screen.getByRole('button', { name: `Open mix: ${session.title}` })
  expect(tape.style.getPropertyValue('--case')).toBe('#b84755')
  fireEvent.click(tape)
  expect(open).toHaveBeenCalledWith(session.id)
  expect(screen.queryByRole('button', { name: 'Mix actions' })).toBeNull()
})
it('reflows every mix in order when the container narrows', () => {
  let resize: (entries: unknown[]) => void = () => {}
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: typeof resize) { resize = callback }
    observe() {} disconnect() {}
  })
  const sessions = Array.from({ length: 20 }, (_, i) => ({ ...demoSessions[0], id: String(i), title: `Mix ${i}` }))
  const { container } = render(<TapeRack sessions={sessions} onOpenSession={vi.fn()} />)
  fireEvent(window, new Event('resize'))
  // React flushes the observer update within an act boundary.
  act(() => resize([{ contentRect: { width: 300 } }]))
  expect(screen.getAllByRole('button').map(el => el.getAttribute('aria-label'))).toEqual(sessions.map(s => `Open mix: ${s.title}`))
  expect(container.querySelectorAll('.rack-row').length).toBeGreaterThan(2)
})
it('fills wide shelves from the measured width with no ten-tape cap', () => {
  let resize: (entries: unknown[]) => void = () => {}
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: typeof resize) { resize = callback }
    observe() {} disconnect() {}
  })
  const sessions = Array.from({ length: 20 }, (_, i) => ({ ...demoSessions[0], id: String(i), title: `Mix ${i}` }))
  const { container } = render(<TapeRack sessions={sessions} onOpenSession={vi.fn()} />)
  act(() => resize([{ contentRect: { width: 1400 } }]))
  expect(container.querySelectorAll('.rack-row')).toHaveLength(1)
  expect(container.querySelector('.tape-rack')!.getAttribute('style') ?? '').not.toContain('--rack-width')
  act(() => resize([{ contentRect: { width: 750 } }]))
  // (750 - 28 row padding - 170 plant and bird) / 47 per tape = 11 per shelf.
  expect(Array.from(container.querySelectorAll('.rack-row')).map(row => row.querySelectorAll('.rack-tape').length)).toEqual([11, 9])
})
it('uses the smaller plant and bird allowance on a phone-width shelf', () => {
  let resize: (entries: unknown[]) => void = () => {}
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: typeof resize) { resize = callback }
    observe() {} disconnect() {}
  })
  const sessions = Array.from({ length: 8 }, (_, i) => ({ ...demoSessions[0], id: String(i), title: `Mix ${i}` }))
  const { container } = render(<TapeRack sessions={sessions} onOpenSession={vi.fn()} />)
  act(() => resize([{ contentRect: { width: 358 } }]))
  // (358 - 12 row padding - 138 small plant and bird) / 47 per tape = 4 per shelf.
  expect(Array.from(container.querySelectorAll('.rack-row')).map(row => row.querySelectorAll('.rack-tape').length)).toEqual([4, 4])
})
