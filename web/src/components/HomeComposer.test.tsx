import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Conversation } from './Conversation'
import { demoSessions } from '../data/demo'
import { HomeComposer } from './HomeComposer'

afterEach(() => { cleanup(); vi.unstubAllGlobals(); vi.restoreAllMocks(); vi.useRealTimers() })
function setup(transcribe = vi.fn().mockResolvedValue({ text: 'A quiet evening' }), chat = false) {
  const stop = vi.fn()
  const getUserMedia = vi.fn().mockResolvedValue({ getTracks: () => [{ stop }] })
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
  class Recorder {
    static isTypeSupported() { return true }
    state = 'inactive'; mimeType = 'audio/webm'; ondataavailable: ((event: { data: Blob }) => void) | null = null; onstop: (() => void) | null = null; onerror: (() => void) | null = null
    start() { this.state = 'recording' }
    stop() { this.state = 'inactive'; this.ondataavailable?.({ data: new Blob(['x'.repeat(2048)]) }); this.onstop?.() }
  }
  vi.stubGlobal('MediaRecorder', Recorder)
  const onSubmit = vi.fn().mockResolvedValue(undefined)
  const view = render(chat ? <Conversation session={demoSessions[0]} messages={[]} thinking={false} onSend={onSubmit} transcribe={transcribe} onOpenQueue={vi.fn()} /> : <HomeComposer onSubmit={onSubmit} transcribe={transcribe} />)
  return { stop, getUserMedia, onSubmit, transcribe, ...view }
}
describe('HomeComposer', () => {
  it('submits trimmed drafts and keeps them when creation fails', async () => {
    const onSubmit = vi.fn().mockRejectedValue(new Error('offline'))
    render(<HomeComposer onSubmit={onSubmit} transcribe={vi.fn()} />)
    const input = screen.getByRole('textbox', { name: 'Describe your mix' })
    fireEvent.change(input, { target: { value: '  slow songs  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith('slow songs'))
    expect(input).toHaveValue('  slow songs  ')
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t make your mix')
  })
  it('records, releases microphone, and adds an editable transcript without sending', async () => {
    const { stop, transcribe, onSubmit } = setup()
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'Keep it mellow.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Stop recording' }))
    await waitFor(() => expect(screen.getByRole('textbox')).toHaveValue('Keep it mellow. A quiet evening'))
    expect(stop).toHaveBeenCalled(); expect(transcribe).toHaveBeenCalledWith(expect.any(File), expect.any(AbortSignal))
    expect(onSubmit).not.toHaveBeenCalled()
  })
  it('keeps the draft when microphone permission is denied', async () => {
    const { getUserMedia } = setup()
    getUserMedia.mockRejectedValue(new DOMException('denied', 'NotAllowedError'))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'draft' } })
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Microphone access is blocked')
    expect(screen.getByRole('textbox')).toHaveValue('draft')
  })
  it('aborts transcription on cancel and ignores late results', async () => {
    let resolve!: (value: { text: string }) => void
    const transcribe = vi.fn((_audio: File, _signal: AbortSignal) => new Promise<{ text: string }>(r => { resolve = r }))
    setup(transcribe)
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Stop recording' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel transcription' }))
    expect(transcribe.mock.calls[0][1].aborted).toBe(true)
    await act(async () => resolve({ text: 'late' }))
    expect(screen.getByRole('textbox')).toHaveValue('')
  })
  it('releases a microphone granted after unmount without recording', async () => {
    const { getUserMedia, stop, unmount } = setup()
    let resolve!: (value: { getTracks: () => { stop: typeof stop }[] }) => void
    getUserMedia.mockImplementation(() => new Promise(r => { resolve = r }))
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    unmount()
    await act(async () => resolve({ getTracks: () => [{ stop }] }))
    expect(stop).toHaveBeenCalledOnce()
  })
  it('rotates placeholders only when empty, unfocused, and motion is allowed', () => {
    vi.useFakeTimers()
    const matchMedia = vi.fn().mockReturnValue({ matches: false })
    vi.stubGlobal('matchMedia', matchMedia)
    setup()
    const input = screen.getByRole('textbox')
    const first = input.getAttribute('placeholder')
    act(() => vi.advanceTimersByTime(5000))
    const second = input.getAttribute('placeholder')
    expect(second).not.toBe(first)
    act(() => input.focus())
    act(() => vi.advanceTimersByTime(5000))
    expect(input).toHaveAttribute('placeholder', second!)
    act(() => input.blur())
    matchMedia.mockReturnValue({ matches: true })
    act(() => vi.advanceTimersByTime(5000))
    expect(input).toHaveAttribute('placeholder', second!)
    matchMedia.mockReturnValue({ matches: false })
    fireEvent.change(input, { target: { value: 'draft' } })
    act(() => vi.advanceTimersByTime(5000))
    expect(input).toHaveAttribute('placeholder', second!)
  })
  it('keeps typed text after a transcription error', async () => {
    setup(vi.fn().mockRejectedValue(new Error('offline')))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'A slow start' } })
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Stop recording' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t transcribe')
    expect(screen.getByRole('textbox')).toHaveValue('A slow start')
  })
  it('releases active recording on unmount without transcription', async () => {
    const { stop, transcribe, unmount } = setup()
    fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
    await screen.findByRole('button', { name: 'Stop recording' })
    unmount()
    expect(stop).toHaveBeenCalledOnce()
    expect(transcribe).not.toHaveBeenCalled()
  })

})

it('uses editable voice transcripts in an existing mix too', async () => {
  const { onSubmit, transcribe } = setup(vi.fn().mockResolvedValue({ text: 'More mellow' }), true)
  fireEvent.click(screen.getByRole('button', { name: 'Record a voice prompt' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Stop recording' }))
  await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('More mellow'))
  expect(transcribe).toHaveBeenCalledOnce()
  expect(onSubmit).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
  expect(onSubmit).toHaveBeenCalledWith('More mellow')
})
