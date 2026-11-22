import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { MixComposer } from './MixComposer'
import { PromptKept } from './PromptComposer'
import { Conversation } from './Conversation'
import { useMixDraft } from '../lib/mix-draft'
import type { DjSession } from '../domain'

afterEach(cleanup)

const terminator = { title: 'Terminator', artist: 'Asake', trackId: 't1' }
const calm = { title: 'Calm Down', artist: 'Rema', trackId: 't2' }

function Quoter({ song }: { song: typeof terminator }) {
  const draft = useMixDraft('mix-1')
  return <button type="button" onClick={() => draft.quote(song)}>Quote {song.title}</button>
}

function field(container: HTMLElement) {
  return within(container).getByRole('textbox', { name: 'Message your DJ' })
}

describe('MixComposer', () => {
  it('shares one draft, quotes and words, between two composers of a mix', () => {
    render(
      <>
        <Quoter song={terminator} />
        <section data-testid="conversation"><MixComposer sessionId="mix-1" onSend={vi.fn()} busy={false} transcribe={vi.fn()} /></section>
        <section data-testid="tape"><MixComposer sessionId="mix-1" onSend={vi.fn()} busy={false} transcribe={vi.fn()} /></section>
      </>,
    )
    fireEvent.click(screen.getByRole('button', { name: 'Quote Terminator' }))
    fireEvent.click(screen.getByRole('button', { name: 'Quote Terminator' }))
    fireEvent.change(field(screen.getByTestId('tape')), { target: { value: 'too fast' } })

    const conversation = screen.getByTestId('conversation')
    expect(within(conversation).getAllByRole('listitem')).toHaveLength(1)
    expect(within(conversation).getByText('Terminator · Asake')).toBeInTheDocument()
    expect(field(conversation)).toHaveValue('too fast')
  })

  it('sends quote lines first, sends quotes alone, and clears both composers', async () => {
    const onSend = vi.fn()
    render(
      <>
        <Quoter song={terminator} />
        <Quoter song={calm} />
        <section data-testid="tape"><MixComposer sessionId="mix-1" onSend={onSend} busy={false} transcribe={vi.fn()} /></section>
      </>,
    )
    fireEvent.click(screen.getByRole('button', { name: 'Quote Terminator' }))
    fireEvent.click(screen.getByRole('button', { name: 'Quote Calm Down' }))
    const send = screen.getByRole('button', { name: 'Send message' })
    expect(send).toBeEnabled()
    fireEvent.click(send)
    await waitFor(() => expect(onSend).toHaveBeenCalledWith('> Terminator — Asake\n> Calm Down — Rema'))
    expect(screen.queryByRole('list', { name: 'Quoted songs' })).toBeNull()
  })

  it('a quote can be taken off before sending', () => {
    render(<><Quoter song={terminator} /><MixComposer sessionId="mix-1" onSend={vi.fn()} busy={false} transcribe={vi.fn()} /></>)
    fireEvent.click(screen.getByRole('button', { name: 'Quote Terminator' }))
    fireEvent.click(screen.getByRole('button', { name: 'Remove quote: Terminator · Asake' }))
    expect(screen.queryByRole('list', { name: 'Quoted songs' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Send message' })).toBeDisabled()
  })

  it('puts a kept message back, quotes and all', async () => {
    const onSend = vi.fn().mockRejectedValue(new PromptKept())
    render(<><Quoter song={terminator} /><MixComposer sessionId="mix-1" onSend={onSend} busy={false} transcribe={vi.fn()} /></>)
    fireEvent.click(screen.getByRole('button', { name: 'Quote Terminator' }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'swap it' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await waitFor(() => expect(screen.getByRole('textbox')).toHaveValue('swap it'))
    expect(screen.getByText('Terminator · Asake')).toBeInTheDocument()
  })

  it('a stopped turn brings its quotes back', () => {
    render(<MixComposer sessionId="mix-1" onSend={vi.fn()} onStop={() => '> Terminator — Asake\nslower'} busy transcribe={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: 'Stop' }))
    expect(screen.getByRole('textbox')).toHaveValue('slower')
    expect(screen.getByText('Terminator · Asake')).toBeInTheDocument()
  })
})

describe('quoted turns in the conversation', () => {
  const session: DjSession = {
    id: 'mix-1', kind: 'mix', title: 'Blue hour', status: 'active', queueVersion: 3, notPersonal: false,
    updatedAt: '2026-11-22T12:00:00.000Z', ageLabel: 'a moment ago', trackCount: 15, durationLabel: '52 min', caseColor: '#544451',
  }

  it('draws a quoted song as a quote, not as markup', () => {
    render(<Conversation session={session} thinking={false} onSend={vi.fn()} messages={[{ id: 'u1', role: 'user', content: '> Terminator — Asake\nthis one is too fast', createdAt: '2026-11-22T12:00:00.000Z' }]} />)
    const turn = document.querySelector('[data-turn-id="u1"]') as HTMLElement
    expect(within(turn).getByText('Terminator · Asake')).toBeInTheDocument()
    expect(turn).toHaveTextContent('this one is too fast')
    expect(turn.textContent).not.toContain('>')
    expect(turn.textContent).not.toContain('—')
  })
})
