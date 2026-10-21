import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { toAlbumPick } from '../api/mappers'
import { demoAlbumMessages, demoAlbumPick } from '../data/demo'
import type { DjMessage, DjSession } from '../domain'
import { Conversation } from './Conversation'

const session: DjSession = {
  id: 'blue-hour',
  kind: 'mix',
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

describe('Conversation for an album session', () => {
  afterEach(cleanup)
  const albumSession: DjSession = { ...session, id: 'train-home', kind: 'album', title: 'Train home', queueVersion: 2, trackCount: 0 }
  const messages: DjMessage[] = demoAlbumMessages
  const passed = toAlbumPick(demoAlbumPick)

  it('drops the Shape tool, the queue toggle and the Tape revised rows, and asks for another album', () => {
    render(<Conversation kind="album" session={albumSession} messages={messages} thinking={false} onSend={vi.fn()} attachment={<button>＋ Playlist</button>} />)
    expect(screen.queryByRole('button', { name: /Energy journey/ })).toBeNull()
    expect(screen.getByRole('button', { name: '＋ Playlist' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Open your mix' })).toBeNull()
    expect(screen.queryByText(/Tape revised/)).toBeNull()
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveAttribute('placeholder', 'Another? Older? Something you do not know?')
    expect(screen.getByText('Current album')).toBeInTheDocument()
    expect(screen.getByText(/^Pick 2 · /)).toBeInTheDocument()
  })

  it('names the menu for the album, keeps settings and Archive, and drops Version history', () => {
    render(<Conversation kind="album" session={albumSession} messages={messages} thinking={false} onSend={vi.fn()} onColor={vi.fn(async () => undefined)} onArchive={vi.fn(async () => undefined)} />)
    expect(screen.queryByRole('button', { name: 'Tape options' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Album options' }))
    expect(screen.getByRole('button', { name: 'Album settings' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Tape settings' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Archive' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Version history' })).toBeNull()
  })

  it('names the album search while the DJ works', () => {
    render(<Conversation kind="album" session={albumSession} messages={messages.slice(0, 1)} thinking onSend={vi.fn()} />)
    expect(screen.getByText('Finding your album · checking Apple Music')).toBeInTheDocument()
  })

  it('places a passed-over album above the turn that replaced it, with Go back', () => {
    const onGoBack = vi.fn()
    render(<Conversation kind="album" session={albumSession} messages={messages} thinking={false} onSend={vi.fn()} passed={[passed]} onGoBack={onGoBack} />)
    const row = screen.getByText('Passed over').closest('.album-passed') as HTMLElement
    expect(row).toHaveTextContent('Low Tide Hours')
    const refine = screen.getByText(demoAlbumMessages[2].content)
    const firstReply = screen.getByText(demoAlbumMessages[1].content)
    expect(firstReply.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(row.compareDocumentPosition(refine) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    fireEvent.click(within(row).getByRole('button', { name: 'Go back' }))
    expect(onGoBack).toHaveBeenCalledWith(1)
  })

  it('reads passed rows sharing a place oldest first', () => {
    const older = { ...passed, id: 'older', title: 'Older pick', version: 1 }
    const newer = { ...passed, id: 'newer', title: 'Newer pick', version: 2 }
    // The server lists passed albums newest first.
    render(<Conversation kind="album" session={{ ...albumSession, queueVersion: 3 }} messages={messages.slice(0, 2)} thinking={false} onSend={vi.fn()} passed={[newer, older]} onGoBack={vi.fn()} />)
    const rows = [...document.querySelectorAll('.album-passed strong')].map((row) => row.textContent)
    expect(rows).toEqual(['Older pick', 'Newer pick'])
  })

  it('places an album passed by Pick this at the end of the transcript', () => {
    render(<Conversation kind="album" session={{ ...albumSession, queueVersion: 2 }} messages={messages.slice(0, 2)} thinking={false} onSend={vi.fn()} passed={[passed]} onGoBack={vi.fn()} />)
    const row = screen.getByText('Passed over').closest('.album-passed') as HTMLElement
    const reply = screen.getByText(demoAlbumMessages[1].content)
    expect(reply.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('folds the album panel in under the reply that produced the pick', () => {
    render(<Conversation kind="album" session={albumSession} messages={messages} thinking={false} onSend={vi.fn()} inlinePanel={<div>Inline album</div>} inlinePanelVersion={1} />)
    const panel = screen.getByText('Inline album')
    const firstReply = screen.getByText(demoAlbumMessages[1].content)
    const refine = screen.getByText(demoAlbumMessages[2].content)
    expect(firstReply.compareDocumentPosition(panel) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(panel.compareDocumentPosition(refine) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('offers the honest-failure pills under the last reply and sends one', () => {
    const onSuggestion = vi.fn()
    render(<Conversation kind="album" session={albumSession} messages={messages.slice(0, 2)} thinking={false} onSend={vi.fn()} suggestions={['Any year', 'Something stranger I do know']} onSuggestion={onSuggestion} />)
    fireEvent.click(screen.getByRole('button', { name: 'Any year' }))
    expect(onSuggestion).toHaveBeenCalledWith('Any year')
  })
})

describe('Conversation for a mix session', () => {
  afterEach(cleanup)

  it('keeps the queue toggle, the Shape tool, Version history and the Tape revised rows', () => {
    const mixMessages: DjMessage[] = [
      { id: 'a', role: 'dj', content: 'First pass.', queueVersion: 1, createdAt: '2026-08-31T12:00:00.000Z' },
      { id: 'b', role: 'user', content: 'Brighter.', createdAt: '2026-08-31T12:01:00.000Z' },
    ]
    render(<Conversation session={session} messages={mixMessages} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Open your mix' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Energy journey' })).toBeInTheDocument()
    expect(screen.getByText(/Tape revised · version 1/)).toBeInTheDocument()
    expect(screen.getByText('Current tape')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Tape options' }))
    expect(screen.getByRole('button', { name: 'Version history' })).toBeInTheDocument()
  })
})
