import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ChooseMethod } from './ChooseMethod'

describe('Step 2 of 3, How do you want to add it?', () => {
  afterEach(cleanup)

  it('offers the Apple library sync with the Library line', () => {
    const onChoose = vi.fn()
    render(<ChooseMethod service="apple" onChoose={onChoose} onBack={vi.fn()} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Step 2 of 3, How do you want to add it?' })).toBeInTheDocument()
    expect(screen.getByText('You can add more later from Library.')).toBeInTheDocument()
    expect(screen.queryByText(/Exportify brings/)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Sync my library' }))
    expect(onChoose).toHaveBeenCalledWith('apple-sync')
  })

  it('offers the two Spotify routes with their line', () => {
    const onChoose = vi.fn()
    render(<ChooseMethod service="spotify" onChoose={onChoose} onBack={vi.fn()} />)

    expect(screen.getByText('Exportify brings your playlists and likes. The data export adds what you actually played.')).toBeInTheDocument()
    expect(screen.getByText('You can add more later from Library.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Exportify, a few minutes' }))
    fireEvent.click(screen.getByRole('button', { name: 'Spotify data export, a few days' }))
    expect(onChoose.mock.calls).toEqual([['exportify'], ['spotify-export']])
  })

  it('fills two thirds of the progress line on the step 2 background', () => {
    const { container } = render(<ChooseMethod service="spotify" onChoose={vi.fn()} onBack={vi.fn()} />)
    expect(screen.getByText('Step 2 of 3', { selector: '.fr-stepc' })).toBeInTheDocument()
    expect(screen.getByTestId('fr-progress').style.width).toMatch(/^66\.66/)
    expect((container.querySelector('.fr-page') as HTMLElement).dataset.background).toBe('step-2')
  })
})
