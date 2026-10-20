import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KeepSheet, keepSheetSeen, markKeepSheetSeen } from './KeepSheet'

beforeEach(() => sessionStorage.clear())
afterEach(cleanup)

describe('Keep this mix sheet', () => {
  it('reads as the board: headline, line, one paper pill, Not now, no provider buttons', () => {
    render(<KeepSheet onKeep={vi.fn()} onNotNow={vi.fn()} />)
    const dialog = screen.getByRole('dialog', { name: 'Keep this mix.' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('heading', { level: 2, name: 'Keep this mix.' })).toHaveFocus()
    expect(screen.getByText('Sign in and your mixes and music stay with you on any device.')).toBeInTheDocument()
    expect(screen.getAllByRole('button').map((button) => button.textContent)).toEqual(['Keep this mix', 'Not now'])
    expect(screen.getByRole('button', { name: 'Keep this mix' })).toHaveClass('fr-pill')
  })

  it('the pill keeps; Not now, Escape, the handle and the backdrop dismiss', () => {
    const onKeep = vi.fn()
    const onNotNow = vi.fn()
    render(<KeepSheet onKeep={onKeep} onNotNow={onNotNow} />)
    fireEvent.click(screen.getByRole('button', { name: 'Keep this mix' }))
    expect(onKeep).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    fireEvent.keyDown(window, { key: 'Escape' })
    fireEvent.click(screen.getByTestId('keep-sheet-handle'))
    fireEvent.click(screen.getByTestId('keep-sheet-backdrop'))
    expect(onNotNow).toHaveBeenCalledTimes(4)
    expect(onKeep).toHaveBeenCalledOnce()
  })

  it('remembers for the browser session, and survives blocked storage', () => {
    expect(keepSheetSeen()).toBe(false)
    markKeepSheetSeen()
    expect(keepSheetSeen()).toBe(true)
    const get = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked') })
    const set = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('blocked') })
    expect(keepSheetSeen()).toBe(false)
    expect(() => markKeepSheetSeen()).not.toThrow()
    get.mockRestore()
    set.mockRestore()
  })
})
