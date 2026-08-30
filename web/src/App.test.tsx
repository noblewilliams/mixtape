import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'

describe('Mixtape web shell', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('opens on the conversation with an unlabeled DJ voice and current tape', () => {
    render(<App />)

    expect(screen.getByRole('heading', { name: 'Blue hour, windows down' })).toBeInTheDocument()
    expect(screen.getByText(/I kept the opening close/)).toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Your tape' })).toBeInTheDocument()
    expect(screen.queryByText(/^DJ$/)).not.toBeInTheDocument()
    expect(screen.queryByText(/^You$/)).not.toBeInTheDocument()
  })

  it('renders the Closet as one tightly packed shelf of text-only spines', () => {
    render(<App />)
    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    fireEvent.click(screen.getByRole('button', { name: 'Closet view' }))

    const closet = screen.getByRole('region', { name: 'Tape closet' })
    expect(within(closet).getAllByRole('list')).toHaveLength(1)
    expect(within(closet).getAllByRole('button')).toHaveLength(19)
    expect(closet.querySelectorAll('.tape-spine svg')).toHaveLength(0)
  })

  it('creates a named blank tape and opens its conversation', () => {
    render(<App />)
    fireEvent.click(screen.getByRole('button', { name: 'Make a new tape' }))
    fireEvent.change(screen.getByLabelText('What should this tape feel like?'), {
      target: { value: 'Dinner after the rain' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))

    expect(screen.getByRole('heading', { name: 'Dinner after the rain' })).toBeInTheDocument()
    expect(screen.getByText('Blank tape · just now')).toBeInTheDocument()
  })

  it('adds a listener message and follows it with the DJ response', () => {
    vi.useFakeTimers()
    render(<App />)
    fireEvent.change(screen.getByLabelText('Message your DJ'), {
      target: { value: 'Make the middle brighter.' },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    expect(screen.getByText('Make the middle brighter.')).toBeInTheDocument()
    expect(screen.getByLabelText('The DJ is listening')).toBeInTheDocument()

    act(() => {
      vi.advanceTimersByTime(900)
    })

    expect(screen.getByText(/reshape the middle around that feeling/)).toBeInTheDocument()
  })

  it('supports the local play and playlist-save prototype states', () => {
    render(<App />)
    fireEvent.click(screen.getByRole('button', { name: 'Play tape' }))
    expect(screen.getByRole('button', { name: 'Pause tape' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Save playlist' }))
    expect(screen.getByRole('dialog', { name: 'Save as a playlist' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Confirm save playlist' }))
    expect(screen.getByText('Playlist ready for Apple Music')).toBeInTheDocument()
  })
})
