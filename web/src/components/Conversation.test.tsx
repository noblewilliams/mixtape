import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import doorCss from './music-door.css?raw'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { toAlbumPick } from '../api/mappers'
import { demoAlbumMessages, demoAlbumPick } from '../data/demo'
import type { DjMessage, DjSession } from '../domain'
import { Conversation } from './Conversation'
import type { TurnWork } from './djWorkingLines'
import type { MusicDoorInput } from './MusicDoor'

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

describe('Conversation while the DJ works on a mix', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })
  const T0 = Date.UTC(2026, 10, 13, 8, 0, 0)
  const asked: DjMessage[] = [{ id: 'u', role: 'user', content: 'Slower in the middle', createdAt: '2026-11-13T08:00:00.000Z' }]
  const visible = () => document.querySelector('.dj-thinking .dj-working-line')

  it('says what the DJ is doing under the cassette, and keeps one steady line for assistive tech', () => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
    const work = (step: TurnWork['step']): TurnWork => ({ startedAt: T0 - 1_000, step })
    const { rerender } = render(<Conversation session={session} messages={asked} thinking working={work(null)} onSend={vi.fn()} />)
    const indicator = document.querySelector('.dj-thinking') as HTMLElement
    expect(indicator).toHaveAttribute('aria-label', 'The DJ is listening')
    expect(visible()).toHaveTextContent('The DJ is listening…')
    expect(visible()!.closest('[aria-hidden="true"]')).not.toBeNull()
    expect(within(indicator).getByText('The DJ is listening')).toHaveClass('sr-only')

    act(() => { vi.advanceTimersByTime(2_000) })
    rerender(<Conversation session={session} messages={asked} thinking working={work({ step: { type: 'step', step: 'labelling', title: 'Slow bridge' }, at: T0 + 2_000 })} onSend={vi.fn()} />)
    expect(visible()).toHaveTextContent('Labelling it “Slow bridge”…')
    expect(indicator).toHaveAttribute('aria-label', 'The DJ is listening')
    expect(within(indicator).getByText('The DJ is listening')).toHaveClass('sr-only')
  })

  it('walks the timed lines when the turn reports nothing', () => {
    vi.useFakeTimers()
    vi.setSystemTime(T0)
    render(<Conversation session={session} messages={asked} thinking working={{ startedAt: T0 - 5_000, step: null }} onSend={vi.fn()} />)
    expect(visible()?.textContent).toMatch(/^(Digging through the crates|Flipping through your records|Thumbing through the stacks)…$/)
  })

  it('draws no working line once the DJ answers', () => {
    render(<Conversation session={session} messages={asked} thinking={false} working={{ startedAt: Date.now(), step: null }} onSend={vi.fn()} />)
    expect(document.querySelector('.dj-thinking')).toBeNull()
  })

  it('keeps an album turn on its own static line', () => {
    const album = { ...session, kind: 'album' as const }
    render(<Conversation kind="album" session={album} messages={asked} thinking working={{ startedAt: Date.now(), step: { step: { type: 'step', step: 'picking' }, at: Date.now() } }} onSend={vi.fn()} />)
    expect(screen.getByText('Finding your album · checking Apple Music')).toBeInTheDocument()
    expect(visible()).toBeNull()
  })
})

describe('Conversation on a catalog mix (add your music)', () => {
  afterEach(cleanup)
  const catalog: DjSession = { ...session, notPersonal: true }
  const turns: DjMessage[] = [
    { id: 'u1', role: 'user', content: 'Rainy commute over the bridge.', createdAt: '2026-11-09T08:00:00.000Z' },
    { id: 'd1', role: 'dj', content: 'Fifteen for the bridge in the rain.', queueVersion: 1, createdAt: '2026-11-09T08:00:08.000Z' },
    { id: 'u2', role: 'user', content: 'Brighter.', createdAt: '2026-11-09T08:01:00.000Z' },
    { id: 'd2', role: 'dj', content: 'Brighter now, still from the catalog.', queueVersion: 2, createdAt: '2026-11-09T08:01:08.000Z' },
  ]
  const idle = { kind: 'idle' as const }
  const idleRun = { getState: () => idle, subscribe: () => () => undefined }
  const door = (over: Partial<MusicDoorInput> = {}): MusicDoorInput => ({
    onboarding: null,
    syncRun: idleRun,
    platform: 'apple',
    onAddMusic: vi.fn(),
    onRemake: vi.fn(),
    ...over,
  })
  const LINE = 'From Mixtape’s catalog for now. With your music, the DJ picks from what you actually play.'

  it('puts the door under the last DJ turn of a catalog mix', () => {
    const musicDoor = door()
    render(<Conversation session={catalog} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={musicDoor} />)
    const line = screen.getByText(LINE)
    const region = line.closest('[role="status"]') as HTMLElement
    expect(region).toHaveClass('music-door')
    const last = screen.getByText('Brighter now, still from the catalog.')
    expect(last.compareDocumentPosition(region) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getAllByText(LINE)).toHaveLength(1)
    fireEvent.click(within(region).getByRole('button', { name: 'Sync Apple Music' }))
    expect(musicDoor.onAddMusic).toHaveBeenCalledWith('door')
  })

  it('keeps one door, mounted once, while the next line waits and after the reply lands', () => {
    const ready = { userId: 'u', sources: [], hasLibrary: true, chosenService: 'apple' as const, markedRequestedAt: null, interviewCompletedAt: null, importCompletedAt: null, interview: null, musicReady: true }
    const musicDoor = door({ onboarding: ready })
    const view = render(<Conversation session={catalog} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={musicDoor} />)
    const mounted = document.querySelector('.music-door')
    const pending: DjMessage = { id: 'u3', role: 'user', content: 'Again, brighter', createdAt: '2026-11-09T08:02:00.000Z' }
    view.rerender(<Conversation session={catalog} messages={[...turns, pending]} thinking onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={musicDoor} />)
    // Not re-added under the polite transcript, so the reply does not re-read it.
    expect(document.querySelector('.music-door')).toBe(mounted)
    expect(document.querySelectorAll('.music-door')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Remake with my music' })).toBeDisabled()
    // The reply's version row comes before the door.
    const revised = screen.getByRole('button', { name: /Tape revised · version 2/ })
    expect(revised.compareDocumentPosition(mounted!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    const reply: DjMessage = { id: 'd3', role: 'dj', content: 'Brighter again.', queueVersion: 3, createdAt: '2026-11-09T08:02:08.000Z' }
    view.rerender(<Conversation session={catalog} messages={[...turns, pending, reply]} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={musicDoor} />)
    expect(document.querySelector('.music-door')).toBe(mounted)
    expect(screen.getByText('Brighter again.').compareDocumentPosition(mounted!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Remake with my music' })).toBeEnabled()
  })

  it('hides its door from assistive tech while the phone shell’s panel covers it', () => {
    render(<Conversation session={catalog} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={door()} musicDoorCovered />)
    const region = document.querySelector('.music-door') as HTMLElement
    const slot = region.parentElement as HTMLElement
    expect(slot).toHaveAttribute('aria-hidden', 'true')
    expect(slot).toHaveAttribute('inert')
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Sync Apple Music' })).toBeNull()
  })

  it('lets the listener’s lines take focus, for focus coming back to the transcript', () => {
    render(<Conversation session={catalog} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} />)
    const mine = screen.getByText('Brighter.')
    expect(mine).toHaveAttribute('tabindex', '-1')
    expect(mine).toHaveAttribute('data-turn-id', 'u2')
  })

  it('draws no door on a personal mix', () => {
    render(<Conversation session={session} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} musicDoor={door()} />)
    expect(screen.queryByText(LINE)).toBeNull()
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('never draws the door on an album session', () => {
    const album: DjSession = { ...catalog, kind: 'album', trackCount: 0 }
    render(<Conversation kind="album" session={album} messages={demoAlbumMessages} thinking={false} onSend={vi.fn()} musicDoor={door()} />)
    expect(screen.queryByText(LINE)).toBeNull()
    expect(screen.queryByRole('button', { name: 'Sync Apple Music' })).toBeNull()
  })

  it('offers Add my listening history in the suggestions row when the turn carried it', () => {
    const onAddHistory = vi.fn()
    render(<Conversation session={session} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} onAddHistory={onAddHistory} />)
    const pill = screen.getByRole('button', { name: 'Add my listening history' })
    expect(pill.closest('.conversation-pills')).not.toBeNull()
    expect(pill).toHaveClass('conversation-history-pill')
    const last = screen.getByText('Brighter now, still from the catalog.')
    expect(last.compareDocumentPosition(pill) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    fireEvent.click(pill)
    expect(onAddHistory).toHaveBeenCalledTimes(1)
  })

  it('puts the history pill beside other suggestions, in one row', () => {
    render(<Conversation session={session} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} suggestions={['Something older']} onSuggestion={vi.fn()} onAddHistory={vi.fn()} />)
    const rows = document.querySelectorAll('.conversation-pills')
    expect(rows).toHaveLength(1)
    expect(within(rows[0] as HTMLElement).getAllByRole('button').map((button) => button.textContent)).toEqual(['Something older', 'Add my listening history'])
  })

  it('gives the history pill a 44px coarse-pointer target, and only that pill', () => {
    const coarse = doorCss.match(/@media \(pointer: coarse\)\s*{([\s\S]*?)\n}/)?.[1] ?? ''
    expect(coarse).toMatch(/\.conversation-history-pill::before\s*{[^}]*inset:\s*-7px 0;/)
    expect(doorCss).toMatch(/\.conversation-history-pill\s*{[^}]*position:\s*relative;/)
    expect(doorCss).not.toMatch(/\.home-starters button[^{]*{/)
  })

  it('shows no history pill without the offer', () => {
    render(<Conversation session={session} messages={turns} thinking={false} onSend={vi.fn()} onOpenQueue={vi.fn()} />)
    expect(screen.queryByRole('button', { name: 'Add my listening history' })).toBeNull()
    expect(document.querySelector('.conversation-pills')).toBeNull()
  })
})
