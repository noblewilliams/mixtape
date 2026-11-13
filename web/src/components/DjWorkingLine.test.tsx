import { act, cleanup, render, screen } from '@testing-library/react'
import { StrictMode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TurnStepProgress } from '../api/client'
import { DjWorkingLine } from './DjWorkingLine'
import { LISTENING_LINE, STILL_LINE, type TurnWork } from './djWorkingLines'

const T0 = Date.UTC(2026, 10, 13, 8, 0, 0)
const step = (name: string, fields: Omit<TurnStepProgress, 'type' | 'step'> = {}): TurnStepProgress => ({ type: 'step', step: name, ...fields })
const line = () => document.querySelector('.dj-working-line')?.textContent
const advance = (ms: number) => act(() => { vi.advanceTimersByTime(ms) })

describe('the DJ working line', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
  })
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('walks the timed phases while no stream has opened', () => {
    render(<DjWorkingLine work={{ startedAt: T0, step: null }} seed={0} />)
    expect(line()).toBe(LISTENING_LINE)
    advance(3_999)
    expect(line()).toBe(LISTENING_LINE)
    advance(1)
    expect(line()).toBe('Flipping through your records…')
    advance(7_000)
    expect(line()).toBe('Cueing up contenders…')
    advance(39_000)
    expect(line()).toBe(STILL_LINE)
  })

  it('picks the timed walk up where a turn already under way has got to', () => {
    render(<DjWorkingLine work={{ startedAt: T0 - 12_000, step: null }} seed={0} />)
    expect(line()).toBe('Cueing up contenders…')
  })

  it('stops the clock when the stream opens and holds listening until the first step', () => {
    const { rerender } = render(<DjWorkingLine work={{ startedAt: T0, step: null }} seed={0} />)
    advance(2_000)
    rerender(<DjWorkingLine work={{ startedAt: T0, step: { step: null, at: T0 + 2_000 } }} seed={0} />)
    advance(20_000)
    expect(line()).toBe(LISTENING_LINE)
    advance(10_000)
    expect(line()).toBe(STILL_LINE)
  })

  it('follows each step, its later lines 12 s apart and the still line at 30 s', () => {
    const open: TurnWork = { startedAt: T0, step: { step: null, at: T0 } }
    const { rerender } = render(<DjWorkingLine work={open} seed={0} />)
    advance(2_000)
    rerender(<DjWorkingLine work={{ startedAt: T0, step: { step: step('picking'), at: T0 + 2_000 } }} seed={0} />)
    expect(line()).toBe('Pulling records that fit…')
    advance(12_000)
    expect(line()).toBe('Sequencing the tracklist…')
    advance(12_000)
    expect(line()).toBe('Lining up the transitions…')
    advance(6_000)
    expect(line()).toBe(STILL_LINE)
  })

  it('holds each line 1.5 s, and skips a step overtaken meanwhile', () => {
    const at = (name: string, ms: number, fields = {}): TurnWork => ({ startedAt: T0, step: { step: step(name, fields), at: T0 + ms } })
    const { rerender } = render(<DjWorkingLine work={at('pressing', 0, { count: 12 })} seed={0} />)
    expect(line()).toBe('Pressing 12 songs to tape…')
    advance(300)
    rerender(<DjWorkingLine work={at('noting', 300)} seed={0} />)
    expect(line()).toBe('Pressing 12 songs to tape…')
    advance(50)
    rerender(<DjWorkingLine work={at('writing', 350)} seed={0} />)
    advance(1_149)
    expect(line()).toBe('Pressing 12 songs to tape…')
    advance(1)
    expect(line()).toBe('Writing the liner notes…')
  })

  it('shows a step that comes after the dwell at once', () => {
    const { rerender } = render(<DjWorkingLine work={{ startedAt: T0, step: { step: null, at: T0 } }} seed={0} />)
    advance(4_000)
    rerender(<DjWorkingLine work={{ startedAt: T0, step: { step: step('labelling', { title: 'Blue hour' }), at: T0 + 4_000 } }} seed={0} />)
    expect(line()).toBe('Labelling it “Blue hour”…')
  })

  it('resumes the current step on a remount, from when it arrived', () => {
    render(<DjWorkingLine work={{ startedAt: T0 - 40_000, step: { step: step('picking', { artists: ['Sade'] }), at: T0 - 13_000 } }} seed={0} />)
    expect(line()).toBe('Sequencing the tracklist…')
  })

  it('renders names as plain text', () => {
    render(<DjWorkingLine work={{ startedAt: T0, step: { step: step('labelling', { title: '<b>x</b>' }), at: T0 } }} seed={0} />)
    expect(line()).toBe('Labelling it “<b>x</b>”…')
    expect(document.querySelector('.dj-working-line b')).toBeNull()
  })

  it('starts the clock at the mount when no turn is given', () => {
    render(<DjWorkingLine seed={0} />)
    expect(screen.getByText(LISTENING_LINE)).toBeInTheDocument()
    advance(4_000)
    expect(line()).toBe('Flipping through your records…')
  })

  it('runs the same under StrictMode, and leaves no timer behind', () => {
    const at = (name: string, ms: number): TurnWork => ({ startedAt: T0, step: { step: step(name), at: T0 + ms } })
    const { rerender, unmount } = render(<StrictMode><DjWorkingLine work={{ startedAt: T0, step: null }} seed={0} /></StrictMode>)
    expect(line()).toBe(LISTENING_LINE)
    advance(4_000)
    expect(line()).toBe('Flipping through your records…')
    rerender(<StrictMode><DjWorkingLine work={at('noting', 4_000)} seed={0} /></StrictMode>)
    advance(500)
    rerender(<StrictMode><DjWorkingLine work={at('writing', 4_500)} seed={0} /></StrictMode>)
    // The timed line came up at 4 s and holds its dwell; noting is overtaken while it waits.
    expect(line()).toBe('Flipping through your records…')
    advance(999)
    expect(line()).toBe('Flipping through your records…')
    advance(1)
    expect(line()).toBe('Writing the liner notes…')
    expect(document.querySelectorAll('.dj-working-line')).toHaveLength(1)
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })

  it('leaves no timer running once it unmounts', () => {
    const { unmount } = render(<DjWorkingLine work={{ startedAt: T0, step: null }} seed={0} />)
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })
})
