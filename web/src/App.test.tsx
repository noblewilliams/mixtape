import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { createFakeApi } from './test/fake-api'

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }

function renderApp() {
  const api = createFakeApi()
  render(<App api={api} user={user} onSignOut={vi.fn()} />)
  return api
}

describe('Mixtape web shell', () => {
  afterEach(cleanup)

  it('opens on the server-backed conversation with an unlabeled DJ voice and current tape', async () => {
    renderApp()

    expect(await screen.findByRole('heading', { name: 'Blue hour, windows down' })).toBeInTheDocument()
    expect(await screen.findByText(/I kept the opening close/)).toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Your tape' })).toBeInTheDocument()
    expect(screen.queryByText(/^DJ$/)).not.toBeInTheDocument()
    expect(screen.queryByText(/^You$/)).not.toBeInTheDocument()
  })

  it('renders the Closet as one tightly packed shelf of text-only spines', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Home' }))
    fireEvent.click(screen.getByRole('button', { name: 'Closet view' }))

    const closet = screen.getByRole('region', { name: 'Tape closet' })
    expect(within(closet).getAllByRole('list')).toHaveLength(1)
    expect(within(closet).getAllByRole('button')).toHaveLength(19)
    expect(closet.querySelectorAll('.tape-spine svg')).toHaveLength(0)
  })

  it('creates a tape through the server and opens its conversation', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Make a new tape' }))
    fireEvent.change(screen.getByLabelText('What should this tape feel like?'), {
      target: { value: 'Dinner after the rain' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))

    expect(await screen.findByRole('heading', { name: 'Dinner after the rain' })).toBeInTheDocument()
    expect(screen.getByText('I made a first pass for this moment.')).toBeInTheDocument()
  })

  it('posts a listener message and follows it with the DJ response', async () => {
    renderApp()
    fireEvent.change(await screen.findByLabelText('Message your DJ'), {
      target: { value: 'Make the middle brighter.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    expect(screen.getByText('Make the middle brighter.')).toBeInTheDocument()
    expect(await screen.findByText(/reshaped the middle around that feeling/)).toBeInTheDocument()
  })

  it('keeps playback and playlist actions interactive while MusicKit remains the next boundary', async () => {
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Play tape' }))
    expect(screen.getByRole('button', { name: 'Pause tape' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Save playlist' }))
    expect(screen.getByRole('dialog', { name: 'Save as a playlist' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Confirm save playlist' }))
    expect(screen.getByText(/ready for MusicKit export/)).toBeInTheDocument()
  })
})
