import { afterEach, describe, expect, it } from 'vitest'
import { installFocusModality } from './focus-modality'

const modality = () => document.documentElement.dataset.focus

let teardown: (() => void) | null = null
afterEach(() => {
  teardown?.()
  teardown = null
  delete document.documentElement.dataset.focus
})

describe('focus modality', () => {
  it('starts as pointer', () => {
    teardown = installFocusModality()
    expect(modality()).toBe('pointer')
  })

  it('becomes keyboard on Tab, Shift+Tab, arrows, Enter and Space, and pointer on pointerdown or mousedown', () => {
    teardown = installFocusModality()
    for (const key of ['Tab', 'ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight', 'Enter', ' ']) {
      document.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true }))
      expect(modality()).toBe('pointer')
      document.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }))
      expect(modality()).toBe('keyboard')
    }
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true }))
    expect(modality()).toBe('keyboard')
    document.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    expect(modality()).toBe('pointer')
  })

  it('leaves the modality alone for ordinary typing', () => {
    teardown = installFocusModality()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }))
    expect(modality()).toBe('pointer')
  })

  it('stops listening after teardown', () => {
    const stop = installFocusModality()
    stop()
    document.documentElement.dataset.focus = 'pointer'
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))
    expect(modality()).toBe('pointer')
  })

  it('installs once', () => {
    const first = installFocusModality()
    const second = installFocusModality()
    second()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))
    expect(modality()).toBe('keyboard')
    first()
    teardown = null
  })
})
