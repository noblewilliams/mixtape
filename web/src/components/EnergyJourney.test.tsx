import { NewTapeDialog } from './Overlays'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { EnergyControl, energyBrief, journeyMessage } from './EnergyJourney'
afterEach(cleanup)
it('only applies a shape after confirmation, preserving the written brief', () => {
  const onChange = vi.fn()
  render(<EnergyControl text="Sunday morning" onChange={onChange} />)
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Build, then settle' }))
  expect(onChange).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
  expect(onChange).toHaveBeenCalledWith(
    'Sunday morning\nEnergy journey: Build, then settle.',
  )
})
it('cancel leaves the brief untouched and busy controls cannot apply', () => {
  const onChange = vi.fn()
  const { rerender } = render(
    <EnergyControl text="Sunday" onChange={onChange} />,
  )
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  expect(onChange).not.toHaveBeenCalled()
  rerender(<EnergyControl text="Sunday" onChange={onChange} disabled />)
  expect(screen.getByRole('button', { name: 'Energy journey' })).toBeDisabled()
})
it('replaces only its own shape line and refuses to truncate a long brief', () => {
  expect(energyBrief('Sunday\nEnergy journey: Steady.', 'rise')).toBe(
    'Sunday\nEnergy journey: Build gradually.',
  )
  expect(energyBrief('x'.repeat(2000), 'arc')).toBeNull()
  expect(journeyMessage('limited')).toContain('not enough energy information')
})

it('keeps shape selection separate from mix generation', () => {
  const onCreate = vi.fn()
  render(<NewTapeDialog onClose={() => {}} onCreate={onCreate} />)
  fireEvent.change(screen.getByLabelText('What should this tape feel like?'), {
    target: { value: 'Sunday' },
  })
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
  expect(onCreate).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))
  expect(onCreate).toHaveBeenCalledWith(
    'Sunday\nEnergy journey: Build, then settle.',
  )
})
