import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { Sidebar } from './Sidebar'
describe('primary navigation', () => {
 it('separates Home and Mixes and keeps the sidebar to destinations', () => {
  const home=vi.fn(), mixes=vi.fn(), settings=vi.fn()
  render(<Sidebar activeView="mixes" onOpenHome={home} onOpenMixes={mixes} onOpenMusic={vi.fn()} onOpenSettings={settings} />)
  expect(screen.getByRole('button', {name:'Mixes'})).toHaveAttribute('aria-current','page')
  fireEvent.click(screen.getByRole('button', {name:'Home'})); expect(home).toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', {name:'Mixes'})); expect(mixes).toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', {name:'Settings'})); expect(settings).toHaveBeenCalled()
  expect(screen.queryByRole('button', {name:'Make a mix'})).not.toBeInTheDocument()
  expect(screen.queryByText('Archived mixes')).not.toBeInTheDocument()
 })
})
