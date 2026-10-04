import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DjSession } from '../domain'
import { Conversation } from './Conversation'

const session: DjSession = {
  id: 'blue-hour',
  title: 'Blue hour, windows down',
  status: 'active',
  queueVersion: 3,
  notPersonal: false,
  updatedAt: '2026-08-31T12:00:00.000Z',
  ageLabel: 'a moment ago',
  trackCount: 15,
  durationLabel: '52 min',
  caseColor: '#544451',
}

describe('Conversation composer', () => {
  afterEach(cleanup)

  it('uses the approved straight-up arrow inside a separate visual surface', () => {
    render(
      <Conversation
        session={session}
        messages={[]}
        thinking={false}
        onSend={vi.fn()}
        onOpenQueue={vi.fn()}
      />,
    )

    const sendButton = screen.getByRole('button', { name: 'Send message' })
    const surface = sendButton.querySelector('svg')

    expect(surface).toBeInTheDocument()
    expect(surface?.querySelector('path')).toHaveAttribute('d', 'M12 19V5M8 9l4-4 4 4')
  })

  it('retains the accessible send behavior', () => {
    const onSend = vi.fn()
    render(
      <Conversation
        session={session}
        messages={[]}
        thinking={false}
        onSend={onSend}
        onOpenQueue={vi.fn()}
      />,
    )

    const sendButton = screen.getByRole('button', { name: 'Send message' })
    expect(sendButton).toBeDisabled()

    fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), {
      target: { value: 'Make the middle brighter.' },
    })
    fireEvent.click(sendButton)

    expect(onSend).toHaveBeenCalledWith('Make the middle brighter.')
  })
})

it('restores drafts per mix without carrying a draft into another mix', async () => {
  const { WorkspaceRestoreProvider } = await import('../lib/workspace-restore')
  const show = (id: string) => <WorkspaceRestoreProvider userId="draft-listener" restoring={false}><Conversation key={id} session={{ ...session, id }} messages={[]} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} /></WorkspaceRestoreProvider>
  const view = render(show('one'))
  fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'A little brighter' } })
  view.rerender(show('two'))
  expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('')
  view.rerender(show('one'))
  expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('A little brighter')
  view.unmount()
  render(show('one'))
  expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('A little brighter')
  cleanup()
  sessionStorage.clear()
})

it('shares the home voice input and places compact controls after the text', () => {
  render(<Conversation session={session} messages={[]} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} attachment={<button>＋ Playlist</button>} />)
  expect(screen.getByRole('button', { name: 'Record a voice prompt' })).toBeInTheDocument()
  const input = screen.getByRole('textbox', { name: 'Message your DJ' })
  const energy = screen.getByRole('button', { name: 'Energy journey' })
  expect(input.closest('form')).toHaveClass('home-composer')
  expect(energy.closest('.composer-tools')).toContainElement(screen.getByRole('button', { name: '＋ Playlist' }))
  expect(input.compareDocumentPosition(energy) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  cleanup()
})

it('clears a dispatched draft before leaving while the DJ is still thinking', async () => {
  const { WorkspaceRestoreProvider } = await import('../lib/workspace-restore')
  const onSend = vi.fn(() => new Promise<void>(() => {}))
  const show = () => <WorkspaceRestoreProvider userId="pending-send" restoring={false}><Conversation session={session} messages={[]} thinking={false} onSend={onSend} onOpenQueue={vi.fn()} /></WorkspaceRestoreProvider>
  const view = render(show())
  fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'A brighter ending' } })
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
  view.unmount()
  render(show())
  expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('')
  cleanup()
  sessionStorage.clear()
})

it('treats the shape as a setting: the draft stays as typed and the shape rides the send', () => {
  const onSend = vi.fn()
  render(<Conversation session={session} messages={[]} thinking={false} onSend={onSend} onOpenQueue={vi.fn()} />)
  const input = screen.getByRole('textbox', { name: 'Message your DJ' })
  fireEvent.change(input, { target: { value: 'Slower in the middle' } })
  fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
  fireEvent.click(screen.getByRole('button', { name: 'Wind down' }))
  fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
  expect(input).toHaveValue('Slower in the middle')
  expect(screen.getByRole('button', { name: 'Energy journey: Wind down' })).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
  expect(onSend).toHaveBeenCalledWith('Slower in the middle', 'fall')
  cleanup()
})

it('drops the Apple Music reassurance line under the composer', () => {
  render(<Conversation session={session} messages={[]} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} />)
  expect(screen.queryByText(/Nothing is added to Apple Music/)).not.toBeInTheDocument()
  cleanup()
})
