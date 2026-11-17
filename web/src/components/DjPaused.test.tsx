import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useState, type ReactNode } from 'react'
import { ApiError, type PublicConfig } from '../api/client'
import { demoSessions } from '../data/demo'
import { DJ_PAUSED_DETAIL, DJ_PAUSED_LINE, DjStatusFixed, DjStatusProvider } from '../lib/dj-status'
import { Conversation } from './Conversation'
import { HomeComposer } from './HomeComposer'
import { FirstRunComposer } from './first-run/Welcome'

afterEach(() => { cleanup(); vi.restoreAllMocks() })

const paused = (node: ReactNode) => <DjStatusFixed paused>{node}</DjStatusFixed>
const djMessage = { id: 'dj-1', role: 'dj' as const, content: 'Here is your mix.', createdAt: '2026-11-17T00:00:00.000Z' }

describe('the DJ paused composer', () => {
  it('home: the field, send and mic are off, with the break line and the quiet note', () => {
    const onSubmit = vi.fn()
    render(paused(<HomeComposer albumPicks={false} anonymous={false} onSubmit={onSubmit} transcribe={vi.fn()} />))
    const input = screen.getByRole('textbox', { name: 'Describe your mix' })
    expect(input).toBeDisabled()
    expect(input).toHaveAttribute('placeholder', DJ_PAUSED_LINE)
    expect(screen.getByRole('button', { name: 'Make a mix' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Record a voice prompt' })).toBeDisabled()
    expect(screen.getByText(DJ_PAUSED_DETAIL)).toBeInTheDocument()
    // Enter on the field sends nothing either.
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(onSubmit).not.toHaveBeenCalled()
    // No alert: it is a quiet line, not an error.
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('home: the starters are off too, and an open DJ shows no note', () => {
    const { rerender } = render(paused(<HomeComposer albumPicks={false} anonymous={false} onSubmit={vi.fn()} transcribe={vi.fn()} />))
    for (const starter of screen.getAllByRole('button', { name: /Kitchen|Running|Last bus/ })) expect(starter).toBeDisabled()
    rerender(<DjStatusFixed paused={false}><HomeComposer albumPicks={false} anonymous={false} onSubmit={vi.fn()} transcribe={vi.fn()} /></DjStatusFixed>)
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toBeEnabled()
    expect(screen.queryByText(DJ_PAUSED_DETAIL)).toBeNull()
  })

  it('home: a draft typed before the pause stays in the field, and the reason still shows', () => {
    function Harness() {
      const [on, setOn] = useState(false)
      return <DjStatusFixed paused={on}><button onClick={() => setOn(true)}>pause</button><HomeComposer albumPicks={false} anonymous={false} onSubmit={vi.fn()} transcribe={vi.fn()} /></DjStatusFixed>
    }
    render(<Harness />)
    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'slow songs' } })
    fireEvent.click(screen.getByRole('button', { name: 'pause' }))
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('slow songs')
    expect(screen.getByText(DJ_PAUSED_LINE, { exact: false })).toBeInTheDocument()
  })

  it('conversation: the turn composer and suggestions are off; nothing reaches onSend', () => {
    const onSend = vi.fn()
    const onSuggestion = vi.fn()
    render(paused(<Conversation session={demoSessions[0]} messages={[djMessage]} thinking={false} onSend={onSend} onSuggestion={onSuggestion} suggestions={['Slower']} transcribe={vi.fn()} onOpenQueue={vi.fn()} />))
    const input = screen.getByRole('textbox', { name: 'Message your DJ' })
    expect(input).toBeDisabled()
    expect(input).toHaveAttribute('placeholder', DJ_PAUSED_LINE)
    expect(screen.getByRole('button', { name: 'Send message' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Record a voice prompt' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Slower' })).toBeDisabled()
    expect(screen.getByText(DJ_PAUSED_DETAIL)).toBeInTheDocument()
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(onSend).not.toHaveBeenCalled()
    // The mix itself stays reachable.
    expect(screen.getByRole('button', { name: 'Open your mix' })).toBeEnabled()
  })

  it('conversation: a send refused with dj_paused keeps the text and pauses the composer', async () => {
    const getConfig = vi.fn(async (): Promise<PublicConfig> => ({ neverRefuse: false, djPaused: false }))
    const onSend = vi.fn(async () => { throw new ApiError(503, { error: 'dj_paused' }) })
    // The send path reports the refusal (App does this) and keeps the prompt.
    function Harness() {
      return <DjStatusProvider api={{ getConfig }}><Reporter onSend={onSend} /></DjStatusProvider>
    }
    render(<Harness />)
    await act(async () => {})
    const input = screen.getByRole('textbox', { name: 'Message your DJ' })
    fireEvent.change(input, { target: { value: 'more bass' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toBeDisabled())
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('more bass')
    // The kept draft hides the placeholder, so the quiet line names the break too.
    expect(screen.getByText(`${DJ_PAUSED_LINE}. ${DJ_PAUSED_DETAIL}`)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('first run: the welcome field is off with the same copy', () => {
    const onSend = vi.fn()
    render(paused(<FirstRunComposer draft="" onDraft={vi.fn()} onSend={onSend} transcribe={vi.fn()} />))
    const input = screen.getByRole('textbox', { name: 'Describe your mix' })
    expect(input).toBeDisabled()
    expect(input).toHaveAttribute('placeholder', DJ_PAUSED_LINE)
    expect(screen.getByRole('button', { name: 'Make a mix' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Record a voice prompt' })).toBeDisabled()
    expect(screen.getByText(DJ_PAUSED_DETAIL)).toBeInTheDocument()
  })
})

// Mirrors App's sendMessage seam: report the refusal, then reject with PromptKept.
import { PromptKept } from './PromptComposer'
import { useDjStatus } from '../lib/dj-status'
function Reporter({ onSend }: { onSend: () => Promise<void> }) {
  const dj = useDjStatus()
  return <Conversation session={demoSessions[0]} messages={[]} thinking={false} transcribe={vi.fn()} onOpenQueue={vi.fn()} onSend={async () => {
    try { await onSend() } catch (cause) {
      if (dj.report(cause)) throw new PromptKept()
      throw cause
    }
  }} />
}
