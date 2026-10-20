import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Artists } from './Artists'

function type(label: string, value: string) {
  fireEvent.change(screen.getByRole('textbox', { name: label }), { target: { value } })
}

describe('Who do you love?', () => {
  afterEach(cleanup)

  it('carries the approved copy, three fields, back, and no counter', () => {
    render(<Artists onContinue={vi.fn()} onBack={vi.fn()} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Who do you love?' })).toBeInTheDocument()
    expect(screen.getByText('Three artists is enough. The DJ borrows from the shared catalogue until your music is in.')).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'First artist' })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Second artist' })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Third artist' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Back' })).toBeInTheDocument()
    expect(screen.queryByText(/Step \d of 3/)).not.toBeInTheDocument()
    expect(screen.queryByTestId('fr-progress')).not.toBeInTheDocument()
  })

  it('enables Continue only at three artists, with the dimmed hint until then', () => {
    render(<Artists onContinue={vi.fn()} onBack={vi.fn()} />)
    const next = screen.getByRole('button', { name: 'Continue' })
    expect(next).toBeDisabled()
    expect(next).toHaveAccessibleDescription('Add three artists.')
    expect(next.querySelector('.fr-ff--hollow')).not.toBeNull()

    type('First artist', 'Burna Boy')
    type('Second artist', 'Tems')
    expect(next).toBeDisabled()

    type('Third artist', 'Sade')
    expect(next).toBeEnabled()
    expect(next).not.toHaveAccessibleDescription()
    expect(next.querySelector('.fr-ff--hollow')).toBeNull()
  })

  it('turns an entered field into a chip that can be removed', () => {
    render(<Artists onContinue={vi.fn()} onBack={vi.fn()} />)

    type('First artist', ' Burna Boy ')
    fireEvent.keyDown(screen.getByRole('textbox', { name: 'First artist' }), { key: 'Enter' })

    expect(screen.queryByRole('textbox', { name: 'First artist' })).not.toBeInTheDocument()
    expect(screen.getByText('Burna Boy')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Remove Burna Boy' }))
    expect(screen.getByRole('textbox', { name: 'First artist' })).toHaveValue('')
  })

  it('makes a chip when the field is left', () => {
    render(<Artists onContinue={vi.fn()} onBack={vi.fn()} />)
    type('Second artist', 'Tems')
    fireEvent.blur(screen.getByRole('textbox', { name: 'Second artist' }))
    expect(screen.getByRole('button', { name: 'Remove Tems' })).toBeInTheDocument()
  })

  it('continues with the three names', () => {
    const onContinue = vi.fn()
    render(<Artists onContinue={onContinue} onBack={vi.fn()} />)
    type('First artist', 'Burna Boy')
    type('Second artist', 'Tems')
    type('Third artist', 'Sade')

    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    expect(onContinue).toHaveBeenCalledWith(['Burna Boy', 'Tems', 'Sade'])
  })

  it('keeps chips from an earlier visit', () => {
    render(<Artists initial={['Burna Boy', 'Tems', 'Sade']} onContinue={vi.fn()} onBack={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Remove Sade' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()
  })

  it('sits on the artists background', () => {
    const { container } = render(<Artists onContinue={vi.fn()} onBack={vi.fn()} />)
    expect((container.querySelector('.fr-page') as HTMLElement).dataset.background).toBe('artists')
  })
})
