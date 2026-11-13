import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { TurnWork } from '../djWorkingLines'
import { Making, MAKING_ANNOUNCEMENT, MAKING_HEADLINE, MAKING_LINE } from './Making'

const T0 = Date.UTC(2026, 10, 13, 8, 0, 0)
const stepLine = () => document.querySelector('.fr-step')

describe('the Making page', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
  })
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('keeps the headline, says the wait once, and shows what the DJ is doing under it', () => {
    render(<Making working={{ startedAt: T0, step: null }} />)
    expect(screen.getByRole('heading', { level: 1, name: MAKING_HEADLINE })).toBeInTheDocument()
    expect(MAKING_LINE).toBe('This takes about a minute.')
    expect(screen.getByText(MAKING_LINE, { selector: 'p.fr-line' })).toBeInTheDocument()
    expect(stepLine()).toHaveTextContent('The DJ is listening…')
    expect(stepLine()).toHaveAttribute('aria-hidden', 'true')
    // The page never says "The DJ is listening" twice.
    expect(screen.queryByText(/The DJ is listening\. This takes/, { selector: 'p.fr-line' })).toBeNull()
  })

  it('walks the timed lines until the stream opens', () => {
    render(<Making working={{ startedAt: T0, step: null }} />)
    act(() => { vi.advanceTimersByTime(4_000) })
    expect(stepLine()?.textContent).toMatch(/^(Digging through the crates|Flipping through your records|Thumbing through the stacks)…$/)
  })

  it('follows the turn’s steps, with the same rules as the conversation', () => {
    const work = (step: TurnWork['step']): TurnWork => ({ startedAt: T0, step })
    const { rerender } = render(<Making working={work({ step: null, at: T0 })} />)
    act(() => { vi.advanceTimersByTime(3_000) })
    rerender(<Making working={work({ step: { type: 'step', step: 'digging', scope: 'catalogue', artists: ['Tems', 'Asake', 'Rema'] }, at: T0 + 3_000 })} />)
    expect(stepLine()?.textContent).toMatch(/^(Digging for|Crate-digging for) Tems, Asake and more…$/)
    act(() => { vi.advanceTimersByTime(12_000) })
    expect(stepLine()).toHaveTextContent('Deeper in the crates…')
  })

  it('keeps its one polite announcement steady while the line moves', () => {
    const { rerender } = render(<Making working={{ startedAt: T0, step: null }} />)
    act(() => { vi.advanceTimersByTime(0) })
    const status = screen.getByRole('status')
    expect(status).toHaveTextContent(MAKING_ANNOUNCEMENT)
    expect(MAKING_ANNOUNCEMENT).toBe('The DJ is listening. This takes about a minute.')
    act(() => { vi.advanceTimersByTime(2_000) })
    rerender(<Making working={{ startedAt: T0, step: { step: { type: 'step', step: 'pressing', count: 15 }, at: T0 + 2_000 } }} />)
    expect(stepLine()).toHaveTextContent('Pressing 15 songs to tape…')
    expect(status).toHaveTextContent(MAKING_ANNOUNCEMENT)
    expect(status.textContent).toBe(MAKING_ANNOUNCEMENT)
  })
})
