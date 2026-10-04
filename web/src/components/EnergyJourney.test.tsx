import { NewTapeDialog } from './Overlays'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { EnergyControl, journeyMessage } from './EnergyJourney'
afterEach(cleanup)
it('only applies a shape after confirmation', () => {
  const onSelect = vi.fn()
  render(<EnergyControl onSelect={onSelect} />)
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Build, then settle' }))
  expect(onSelect).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
  expect(onSelect).toHaveBeenCalledWith('arc')
})
it('cancel leaves the shape untouched and busy controls cannot apply', () => {
  const onSelect = vi.fn()
  const { rerender } = render(<EnergyControl onSelect={onSelect} />)
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  expect(onSelect).not.toHaveBeenCalled()
  rerender(<EnergyControl onSelect={onSelect} disabled />)
  expect(screen.getByRole('button', { name: 'Energy journey' })).toBeDisabled()
})
it('explains a limited assessment', () => {
  expect(journeyMessage('limited')).toContain('not enough energy information')
})

it('keeps the shape out of the written brief and sends it as a setting', () => {
  const onCreate = vi.fn()
  render(<NewTapeDialog onClose={() => {}} onCreate={onCreate} />)
  const brief = screen.getByLabelText('What should this tape feel like?')
  fireEvent.change(brief, { target: { value: 'Sunday' } })
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
  expect(onCreate).not.toHaveBeenCalled()
  expect(brief).toHaveValue('Sunday')
  expect(screen.getByRole('status')).toHaveTextContent('Build, then settle')
  fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))
  expect(onCreate).toHaveBeenCalledWith('Sunday', 'arc')
})

it('leads the compact control with the selected shape and no caret', () => {
  const { rerender } = render(<EnergyControl compact onSelect={vi.fn()} />)
  expect(screen.getByRole('button', { name: 'Energy journey' }).querySelector('svg')).toBeNull()
  rerender(<EnergyControl compact value="rise" onSelect={vi.fn()} />)
  const button = screen.getByRole('button', { name: 'Energy journey: Build gradually' })
  expect(button).toHaveTextContent(/^Shape$/)
  expect(button.firstElementChild?.tagName.toLowerCase()).toBe('svg')
  fireEvent.click(button)
  expect(screen.getByRole('button', { name: 'Build gradually' })).toHaveAttribute('aria-pressed', 'true')
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  rerender(<EnergyControl compact value="fall" onSelect={vi.fn()} />)
  expect(screen.getByRole('button', { name: 'Energy journey: Wind down' }).querySelector('path')).toHaveAttribute('d', 'M10 20 C100 20 200 90 290 90')
})
