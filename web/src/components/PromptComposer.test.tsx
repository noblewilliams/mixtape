import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { useState } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { PromptComposer, PromptKept, type PromptComposerProps } from './PromptComposer'

afterEach(() => { cleanup(); vi.restoreAllMocks() })

function Harness(props: Partial<PromptComposerProps> & { initial?: string }) {
  const [draft, setDraft] = useState(props.initial ?? '')
  return <PromptComposer draft={draft} setDraft={setDraft} onSubmit={vi.fn()} transcribe={vi.fn()} inputLabel="Message your DJ" sendLabel="Send message" {...props} />
}

/** A submit the test holds open until settle(). */
function held() {
  let settle!: (outcome?: unknown) => void
  const onSubmit = vi.fn(() => new Promise<void>((resolve, reject) => { settle = (outcome) => (outcome ? reject(outcome) : resolve()) }))
  return { onSubmit, settle: (outcome?: unknown) => settle(outcome) }
}

describe('PromptComposer while the DJ works', () => {
  it('keeps the field open, so the next message can be typed', () => {
    render(<Harness busy initial="first" />)
    const input = screen.getByRole('textbox', { name: 'Message your DJ' })
    expect(input).toBeEnabled()
    fireEvent.change(input, { target: { value: 'the next one' } })
    expect(input).toHaveValue('the next one')
  })

  it('does nothing on Return while busy, and keeps the draft', () => {
    const onSubmit = vi.fn()
    render(<Harness busy initial="hold this" onSubmit={onSubmit} />)
    const input = screen.getByRole('textbox', { name: 'Message your DJ' })
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(onSubmit).not.toHaveBeenCalled()
    expect(input).toHaveValue('hold this')
  })

  it('hides the mic while busy', () => {
    render(<Harness busy />)
    expect(screen.queryByRole('button', { name: 'Record a voice prompt' })).toBeNull()
  })

  it('shows Stop in place of send while a stoppable turn is out, with or without a draft', () => {
    const onStop = vi.fn()
    const { rerender } = render(<Harness busy onStop={onStop} />)
    expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull()
    const stop = screen.getByRole('button', { name: 'Stop' })
    expect(stop).toHaveClass('home-send-button')
    expect(stop).toBeEnabled()
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'a draft' } })
    expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Stop' }))
    expect(onStop).toHaveBeenCalledOnce()
    // Return still does not send, and does not stop.
    fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Enter' })
    expect(onStop).toHaveBeenCalledOnce()
    rerender(<Harness busy />)
    expect(screen.queryByRole('button', { name: 'Stop' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Send message' })).toBeDisabled()
  })

  it('keeps a draft typed while its own submit was out', async () => {
    const turn = held()
    render(<Harness onSubmit={turn.onSubmit} initial="first" />)
    const input = screen.getByRole('textbox')
    fireEvent.keyDown(input, { key: 'Enter' })
    await waitFor(() => expect(turn.onSubmit).toHaveBeenCalledWith('first'))
    expect(input).toBeEnabled()
    fireEvent.change(input, { target: { value: 'second' } })
    turn.settle()
    await waitFor(() => expect(screen.getByRole('button', { name: 'Send message' })).toBeEnabled())
    expect(input).toHaveValue('second')
  })

  it('still clears the sent prompt when nothing was typed meanwhile', async () => {
    const turn = held()
    render(<Harness onSubmit={turn.onSubmit} initial="first" />)
    fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Enter' })
    await waitFor(() => expect(turn.onSubmit).toHaveBeenCalled())
    turn.settle()
    await waitFor(() => expect(screen.getByRole('textbox')).toHaveValue(''))
  })

  it('draws no error when a stopped turn comes back as a kept prompt', async () => {
    const turn = held()
    render(<Harness onSubmit={turn.onSubmit} initial="first" />)
    fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Enter' })
    await waitFor(() => expect(turn.onSubmit).toHaveBeenCalled())
    turn.settle(new PromptKept())
    await waitFor(() => expect(screen.getByRole('button', { name: 'Send message' })).toBeEnabled())
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByRole('textbox')).toHaveValue('first')
  })
})
