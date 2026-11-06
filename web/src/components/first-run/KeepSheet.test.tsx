import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { KeepSheet, keepSheetSeen, markKeepSheetSeen } from './KeepSheet'

beforeEach(() => sessionStorage.clear())
afterEach(cleanup)

describe('Keep this mix sheet', () => {
  it('says the mix is ready: Go to my mix leads, Create an account under it, no provider buttons', () => {
    render(<KeepSheet onKeep={vi.fn()} onNotNow={vi.fn()} />)
    const dialog = screen.getByRole('dialog', { name: 'Your mix is ready.' })
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(screen.getByRole('heading', { level: 2, name: 'Your mix is ready.' })).toHaveFocus()
    expect(screen.getByText('It’s saved on this device. Create an account to have it on your other devices too.')).toBeInTheDocument()
    expect(screen.getAllByRole('button').map((button) => button.textContent)).toEqual(['Go to my mix', 'Create an account'])
    expect(screen.getByRole('button', { name: 'Go to my mix' })).toHaveClass('fr-pill')
  })

  it('Create an account keeps; Go to my mix, Escape, the handle and the backdrop dismiss', () => {
    const onKeep = vi.fn()
    const onNotNow = vi.fn()
    render(<KeepSheet onKeep={onKeep} onNotNow={onNotNow} />)
    fireEvent.click(screen.getByRole('button', { name: 'Create an account' }))
    expect(onKeep).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: 'Go to my mix' }))
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
