import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ThemeToggle } from './ThemeToggle'
import { initializeTheme } from '../theme'

let dark = false
let mediaChange: (() => void) | undefined
beforeEach(() => {
  localStorage.clear()
  dark = false
  vi.stubGlobal('matchMedia', vi.fn(() => ({
    get matches() { return dark },
    addEventListener: (_: string, callback: () => void) => { mediaChange = callback },
    removeEventListener: vi.fn(),
  })))
})
afterEach(() => { cleanup(); vi.unstubAllGlobals(); delete document.documentElement.dataset.theme })

it('uses the system theme until the listener makes a choice', () => {
  dark = true
  initializeTheme()
  render(<ThemeToggle />)
  expect(screen.getByRole('switch', { name: 'Dark mode' })).toHaveAttribute('aria-checked', 'true')
  expect(document.documentElement.dataset.theme).toBe('dark')
  expect(localStorage.getItem('mixtape.theme')).toBeNull()
})

it('switches immediately, persists the choice, and keeps the SVG mounted for animation', () => {
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch', { name: 'Dark mode' })
  const svg = toggle.querySelector('svg')
  fireEvent.click(toggle)
  expect(toggle).toHaveAttribute('aria-checked', 'true')
  expect(document.documentElement.dataset.theme).toBe('dark')
  expect(localStorage.getItem('mixtape.theme')).toBe('dark')
  expect(toggle.querySelector('svg')).toBe(svg)
  fireEvent.click(toggle)
  expect(document.documentElement.dataset.theme).toBe('light')
  expect(localStorage.getItem('mixtape.theme')).toBe('light')
})

it('restores an explicit preference over the system theme', () => {
  localStorage.setItem('mixtape.theme', 'light')
  dark = true
  initializeTheme()
  render(<ThemeToggle />)
  expect(document.documentElement.dataset.theme).toBe('light')
  expect(screen.getByRole('switch')).toHaveAttribute('aria-checked', 'false')
})

it('follows system changes only before an explicit preference', () => {
  render(<ThemeToggle />)
  dark = true
  act(() => mediaChange?.())
  expect(document.documentElement.dataset.theme).toBe('dark')
  fireEvent.click(screen.getByRole('switch'))
  expect(localStorage.getItem('mixtape.theme')).toBe('light')
  dark = false
  act(() => mediaChange?.())
  dark = true
  act(() => mediaChange?.())
  expect(document.documentElement.dataset.theme).toBe('light')
})

it('ignores invalid stored values', () => {
  localStorage.setItem('mixtape.theme', 'invalid')
  initializeTheme()
  expect(document.documentElement.dataset.theme).toBe('light')
})

it('applies theme changes made in another tab', () => {
  render(<ThemeToggle />)
  localStorage.setItem('mixtape.theme', 'dark')
  fireEvent(window, new StorageEvent('storage', { key: 'mixtape.theme', newValue: 'dark' }))
  expect(document.documentElement.dataset.theme).toBe('dark')
  expect(screen.getByRole('switch')).toHaveAttribute('aria-checked', 'true')
})

it('keeps the switch usable when storage is blocked', () => {
  const read = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('unavailable') })
  const write = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('unavailable') })
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch')
  const wasDark = toggle.getAttribute('aria-checked') === 'true'
  fireEvent.click(toggle)
  expect(toggle).toHaveAttribute('aria-checked', String(!wasDark))
  expect(document.documentElement.dataset.theme).toBe(wasDark ? 'light' : 'dark')
  read.mockRestore()
  write.mockRestore()
})

function stubMotion(reduced: boolean) {
  vi.stubGlobal('matchMedia', vi.fn((query: string) => ({
    matches: query.includes('reduced-motion') ? reduced : false,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  })))
}
function stubViewTransition(ready: Promise<void>) {
  const start = vi.fn((update: () => void) => { update(); return { ready, finished: Promise.resolve(), updateCallbackDone: Promise.resolve() } })
  Object.defineProperty(document, 'startViewTransition', { value: start, configurable: true })
  const animate = vi.fn()
  Object.defineProperty(document.documentElement, 'animate', { value: animate, configurable: true })
  return { start, animate }
}
afterEach(() => {
  delete (document as { startViewTransition?: unknown }).startViewTransition
  delete (document.documentElement as { animate?: unknown }).animate
})

it('opens the new theme as a circle from the switch when view transitions are available', async () => {
  stubMotion(false)
  const { start, animate } = stubViewTransition(Promise.resolve())
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch', { name: 'Dark mode' })
  vi.spyOn(toggle, 'getBoundingClientRect').mockReturnValue({ left: 20, top: 700, width: 44, height: 44 } as DOMRect)
  fireEvent.click(toggle)
  expect(start).toHaveBeenCalledTimes(1)
  expect(document.documentElement.dataset.theme).toBe('dark')
  expect(toggle).toHaveAttribute('aria-checked', 'true')
  await vi.waitFor(() => expect(animate).toHaveBeenCalledTimes(1))
  const [keyframes, options] = animate.mock.calls[0]
  expect(keyframes.clipPath[0]).toBe('circle(0px at 42px 722px)')
  expect(keyframes.clipPath[1]).toMatch(/^circle\([\d.]+px at 42px 722px\)$/)
  expect(options).toMatchObject({ duration: 620, easing: 'cubic-bezier(.45,0,.2,1)', pseudoElement: '::view-transition-new(root)' })
})

it('still applies the theme when the browser skips the transition', async () => {
  stubMotion(false)
  const { animate } = stubViewTransition(Promise.reject(new DOMException('Skipped', 'AbortError')))
  render(<ThemeToggle />)
  fireEvent.click(screen.getByRole('switch'))
  expect(document.documentElement.dataset.theme).toBe('dark')
  await Promise.resolve()
  expect(animate).not.toHaveBeenCalled()
})

it('changes theme immediately with no page reveal when reduced motion is requested', () => {
  stubMotion(true)
  const { start } = stubViewTransition(Promise.resolve())
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch')
  const svg = toggle.querySelector('svg')
  fireEvent.click(toggle)
  expect(start).not.toHaveBeenCalled()
  expect(document.documentElement.dataset.theme).toBe('dark')
  expect(toggle.querySelector('svg')).toBe(svg)
})

it('changes theme immediately where view transitions are unavailable', () => {
  stubMotion(false)
  render(<ThemeToggle />)
  fireEvent.click(screen.getByRole('switch'))
  expect(document.documentElement.dataset.theme).toBe('dark')
})

it('draws the reel sun with the mask on a wrapping group', () => {
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch')
  expect(toggle.querySelectorAll('.theme-rays rect')).toHaveLength(8)
  const body = toggle.querySelector('.theme-body')!
  const mask = toggle.querySelector('mask')!
  expect(body.getAttribute('mask')).toBeNull()
  expect(body.parentElement!.getAttribute('mask')).toBe(`url(#${mask.id})`)
  expect(toggle.querySelectorAll('.theme-star')).toHaveLength(2)
})

it('lands on the opposite theme each time when the switch is pressed twice before the first change applies', () => {
  stubMotion(false)
  const updates: Array<() => void> = []
  Object.defineProperty(document, 'startViewTransition', { value: (update: () => void) => { updates.push(update); return { ready: new Promise<void>(() => {}) } }, configurable: true })
  render(<ThemeToggle />)
  const toggle = screen.getByRole('switch')
  fireEvent.click(toggle)
  fireEvent.click(toggle)
  act(() => updates.forEach(update => update()))
  expect(document.documentElement.dataset.theme).toBe('light')
  expect(toggle).toHaveAttribute('aria-checked', 'false')
})
