import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { Tabs } from './Tabs'
import { ViewSwitch } from './ViewSwitch'
import tabStyles from './tabs.css?raw'

afterEach(cleanup)

it('marks only the current tab and reports the chosen one', () => {
  const select = vi.fn()
  render(<Tabs label="Mix sections" current="archived" onSelect={select} items={[{ id: 'active', label: 'Active' }, { id: 'archived', label: 'Archived' }]} />)
  const nav = screen.getByRole('navigation', { name: 'Mix sections' })
  expect(nav).toHaveClass('tabs')
  expect(screen.getByRole('button', { name: 'Archived' })).toHaveAttribute('aria-current', 'page')
  expect(screen.getByRole('button', { name: 'Active' })).not.toHaveAttribute('aria-current')
  fireEvent.click(screen.getByRole('button', { name: 'Active' }))
  expect(select).toHaveBeenCalledWith('active')
})

it('keeps Library’s tab metrics in the shared rule set', () => {
  expect(tabStyles).toMatch(/\.tabs\s*{[^}]*gap:\s*25px/)
  expect(tabStyles).toMatch(/\.tabs button\s*{[^}]*min-height:\s*48px[^}]*font-size:\s*13px[^}]*border-bottom:\s*2px solid transparent/)
  expect(tabStyles).toMatch(/\.tabs button\[aria-current\]\s*{[^}]*color:\s*var\(--slate\)[^}]*border-bottom-color:\s*var\(--slate\)/)
  expect(tabStyles).toMatch(/:where\(:root\[data-theme="dark"\]\) \.tabs button\[aria-current\]\s*{[^}]*#a6bfd2/)
})

it('offers list, grid and closet views with one pressed', () => {
  const change = vi.fn()
  render(<ViewSwitch value="grid" onChange={change} />)
  const group = screen.getByRole('group', { name: 'Collection view' })
  const buttons = Array.from(group.querySelectorAll('button'))
  expect(buttons.map(button => button.getAttribute('aria-label'))).toEqual(['List view', 'Grid view', 'Closet view'])
  expect(buttons.map(button => button.getAttribute('title'))).toEqual(['List view', 'Grid view', 'Closet view'])
  expect(buttons.map(button => button.getAttribute('aria-pressed'))).toEqual(['false', 'true', 'false'])
  expect(buttons.every(button => button.querySelector('svg[aria-hidden="true"]'))).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: 'Closet view' }))
  expect(change).toHaveBeenCalledWith('closet')
})
