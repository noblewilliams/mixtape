import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ChooseService } from './ChooseService'

describe('Step 1 of 3, Which do you use?', () => {
  afterEach(cleanup)

  it('names the page with its step and carries the approved copy', () => {
    const { container } = render(<ChooseService onChoose={vi.fn()} onSkip={vi.fn()} onBack={vi.fn()} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Step 1 of 3, Which do you use?' })).toBeInTheDocument()
    expect(screen.getByText('Mixes get better when the DJ knows your music.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Apple Music' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Spotify' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Skip for now' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Continue' })).not.toBeInTheDocument()
    expect((container.querySelector('.fr-page') as HTMLElement).dataset.background).toBe('step-1')
  })

  it('shows the decorative counter and a third of the progress line', () => {
    render(<ChooseService onChoose={vi.fn()} onSkip={vi.fn()} onBack={vi.fn()} />)

    const counter = screen.getByText('Step 1 of 3', { selector: '.fr-stepc' })
    expect(counter).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('fr-progress').style.width).toMatch(/^33\.33/)
    expect(screen.getByTestId('fr-progress').parentElement).toHaveAttribute('aria-hidden', 'true')
  })

  it('advances on a service tap, skips, and goes back', () => {
    const onChoose = vi.fn()
    const onSkip = vi.fn()
    const onBack = vi.fn()
    render(<ChooseService onChoose={onChoose} onSkip={onSkip} onBack={onBack} />)

    fireEvent.click(screen.getByRole('button', { name: 'Spotify' }))
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))

    expect(onChoose.mock.calls).toEqual([['spotify'], ['apple']])
    expect(onSkip).toHaveBeenCalledOnce()
    expect(onBack).toHaveBeenCalledOnce()
  })

  it('draws back as the outlined tape carrying the rewind glyph', () => {
    render(<ChooseService onChoose={vi.fn()} onSkip={vi.fn()} onBack={vi.fn()} />)
    const back = screen.getByRole('button', { name: 'Back' })
    expect(back).toHaveClass('fr-back')
    expect(back.querySelector('svg path')).toHaveAttribute('d', 'M20 6l-8 6 8 6zM12 6l-8 6 8 6z')
  })
})
