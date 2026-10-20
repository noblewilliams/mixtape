import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Welcome, WELCOME_EXAMPLES } from './Welcome'
import { useState } from 'react'

function Harness(props: Partial<Parameters<typeof Welcome>[0]>) {
  const [draft, setDraft] = useState('')
  return <Welcome draft={draft} onDraft={setDraft} onSend={vi.fn()} onSignIn={vi.fn()} {...props} />
}

describe('Welcome', () => {
  afterEach(cleanup)

  it('carries the approved copy and controls with no counter or back', () => {
    render(<Harness onAddMusic={vi.fn()} />)

    expect(screen.getByRole('heading', { level: 1, name: 'What do you want to hear?' })).toBeInTheDocument()
    expect(screen.getByText('mixtape')).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveAttribute('placeholder', 'something for a rainy commute')
    expect(screen.getByText('or')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Add my music first' })).toBeInTheDocument()
    expect(screen.getByText('Already have an account?')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Sign in.' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Back' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Step \d of 3/)).not.toBeInTheDocument()
    expect(screen.queryByTestId('fr-progress')).not.toBeInTheDocument()
  })

  it('uses the three spec examples', () => {
    expect(WELCOME_EXAMPLES).toEqual(['something for a rainy commute', '90s R&B, no ballads', 'warm up for a long run'])
  })

  it('keeps send off until there is text, then sends the trimmed prompt on Enter', () => {
    const onSend = vi.fn()
    render(<Harness onSend={onSend} onAddMusic={vi.fn()} />)
    const send = screen.getByRole('button', { name: 'Make a mix' })
    expect(send).toBeDisabled()

    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: '  late night drive  ' } })
    expect(send).toBeEnabled()
    fireEvent.keyDown(screen.getByRole('textbox', { name: 'Describe your mix' }), { key: 'Enter' })

    expect(onSend).toHaveBeenCalledWith('late night drive')
  })

  it('opens path B and the sign-in page from its pill and foot link', () => {
    const onAddMusic = vi.fn()
    const onSignIn = vi.fn()
    render(<Harness onAddMusic={onAddMusic} onSignIn={onSignIn} />)

    fireEvent.click(screen.getByRole('button', { name: 'Add my music first' }))
    fireEvent.click(screen.getByRole('button', { name: 'Sign in.' }))

    expect(onAddMusic).toHaveBeenCalledOnce()
    expect(onSignIn).toHaveBeenCalledOnce()
  })

  it('as the prompt page after a sync: no add-music pill, the count line, and back', () => {
    const onBack = vi.fn()
    render(<Harness line="1,284 songs in. Ask for anything." onBack={onBack} />)

    expect(screen.getByRole('heading', { level: 1, name: 'What do you want to hear?' })).toBeInTheDocument()
    expect(screen.getByText('1,284 songs in. Ask for anything.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Add my music first' })).not.toBeInTheDocument()
    expect(screen.queryByText('or')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(onBack).toHaveBeenCalledOnce()
  })

  it('draws the cassette as decoration, hidden from assistive tech', () => {
    const { container } = render(<Harness onAddMusic={vi.fn()} />)
    expect(container.querySelector('.fr-hero')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('sits on the welcome background', () => {
    const { container } = render(<Harness onAddMusic={vi.fn()} />)
    const page = container.querySelector('.fr-page') as HTMLElement
    expect(page.dataset.background).toBe('welcome')
    expect(page.style.getPropertyValue('--fr-bg')).toContain('first-run/bg-welcome.jpg')
  })
})
