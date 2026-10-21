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
  const view = render(chat ? <Conversation session={demoSessions[0]} messages={[]} thinking={false} onSend={onSubmit} transcribe={transcribe} onOpenQueue={vi.fn()} /> : <HomeComposer albumPicks={false} anonymous={false} onSubmit={onSubmit} transcribe={transcribe} />)
  return { stop, getUserMedia, onSubmit, transcribe, ...view }
}
describe('HomeComposer', () => {
  it('takes a mode seed from outside without a nudge, and a fresh seed applies again', () => {
    const props = { albumPicks: true, anonymous: false, onSubmit: vi.fn(), transcribe: vi.fn() }
    const { rerender } = render(<HomeComposer {...props} modeSeed={{ kind: 'album', id: 1 }} />)
    expect(screen.getByRole('radio', { name: 'Album' })).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('button', { name: 'Find an album' })).toBeInTheDocument()
    expect(screen.queryByText(/Switched to Album/)).toBeNull()
    fireEvent.click(screen.getByRole('radio', { name: 'Mix' }))
    rerender(<HomeComposer {...props} modeSeed={{ kind: 'album', id: 1 }} />)
    expect(screen.getByRole('radio', { name: 'Mix' })).toHaveAttribute('aria-checked', 'true')
    rerender(<HomeComposer {...props} modeSeed={{ kind: 'album', id: 2 }} />)
    expect(screen.getByRole('radio', { name: 'Album' })).toHaveAttribute('aria-checked', 'true')
  })
  it('submits trimmed drafts and keeps them when creation fails', async () => {
    const onSubmit = vi.fn().mockRejectedValue(new Error('offline'))
    render(<HomeComposer albumPicks={false} anonymous={false} onSubmit={onSubmit} transcribe={vi.fn()} />)
    const input = screen.getByRole('textbox', { name: 'Describe your mix' })
    fireEvent.change(input, { target: { value: '  slow songs  ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith('slow songs', { kind: 'mix' }))
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

describe('HomeComposer mode', () => {
  const mixPills = ['Kitchen, early, coffee on', 'Running, long, no lyrics', 'Last bus home']
  const albumPills = ['Rainy evening, start to finish', 'Something I have never heard', 'One I own and forgot']
  function mount(props: { albumPicks?: boolean; anonymous?: boolean; busy?: boolean } = {}) {
    const onSubmit = vi.fn().mockResolvedValue(undefined)
    render(<HomeComposer albumPicks={props.albumPicks ?? true} anonymous={props.anonymous ?? false} busy={props.busy} onSubmit={onSubmit} transcribe={vi.fn()} />)
    return { onSubmit, input: screen.getByRole('textbox', { name: 'Describe your mix' }) }
  }
  const radio = (name: string) => screen.getByRole('radio', { name })
  const type = (input: HTMLElement, value: string) => fireEvent.change(input, { target: { value } })

  it('starts on Mix with the Shape control and the mix pills', () => {
    mount()
    expect(screen.getByRole('radiogroup', { name: 'What to make' })).toBeInTheDocument()
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
    expect(radio('Album')).toHaveAttribute('aria-checked', 'false')
    expect(screen.getByRole('button', { name: 'Energy journey' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Make a mix' })).toBeInTheDocument()
    for (const pill of mixPills) expect(screen.getByRole('button', { name: pill })).toBeInTheDocument()
  })

  it('under Album drops Shape and swaps the send label, placeholder and pills', () => {
    const { input } = mount()
    fireEvent.click(radio('Album'))
    expect(radio('Album')).toHaveAttribute('aria-checked', 'true')
    expect(screen.queryByRole('button', { name: /Energy journey/ })).toBeNull()
    expect(screen.getByRole('button', { name: 'Find an album' })).toBeInTheDocument()
    expect(input).toHaveAttribute('placeholder', 'What kind of record are you in the mood for…')
    for (const pill of albumPills) expect(screen.getByRole('button', { name: pill })).toBeInTheDocument()
    for (const pill of mixPills) expect(screen.queryByRole('button', { name: pill })).toBeNull()
  })

  it('moves between the options with the arrow keys', () => {
    mount()
    radio('Mix').focus()
    fireEvent.keyDown(radio('Mix'), { key: 'ArrowRight' })
    expect(radio('Album')).toHaveAttribute('aria-checked', 'true')
    expect(radio('Album')).toHaveFocus()
    expect(radio('Mix')).toHaveAttribute('tabindex', '-1')
    fireEvent.keyDown(radio('Album'), { key: 'ArrowLeft' })
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
  })

  it('nudges to Album once and stays a mix after Keep it a mix', () => {
    const { input } = mount()
    type(input, 'an album for the train home')
    expect(radio('Album')).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('status')).toHaveTextContent('Switched to Album for this prompt.')
    expect(screen.queryByRole('button', { name: albumPills[0] })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Keep it a mix' }))
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
    expect(screen.queryByText('Switched to Album for this prompt.')).toBeNull()
    type(input, 'an album for the train home, nothing loud')
    type(input, 'an')
    type(input, 'an Albums please')
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
    type(input, '')
    type(input, 'album')
    expect(radio('Album')).toHaveAttribute('aria-checked', 'true')
  })

  it('keeps the live region mounted and empty until the nudge', () => {
    const { input } = mount()
    expect(screen.getByRole('status')).toBeEmptyDOMElement()
    type(input, 'an album')
    expect(screen.getByRole('status')).toHaveTextContent('Switched to Album for this prompt.')
  })

  it('names the album failure', async () => {
    const onSubmit = vi.fn().mockRejectedValue(new Error('offline'))
    render(<HomeComposer albumPicks anonymous={false} onSubmit={onSubmit} transcribe={vi.fn()} />)
    fireEvent.click(radio('Album'))
    type(screen.getByRole('textbox'), 'warm')
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t find an album. Your prompt is still here, try again.')
  })

  it('a Mix choice on the control after a nudge stops further nudges', () => {
    const { input } = mount()
    type(input, 'one album')
    fireEvent.click(radio('Mix'))
    expect(screen.queryByText('Switched to Album for this prompt.')).toBeNull()
    type(input, 'one album, then')
    type(input, 'one')
    type(input, 'one album again')
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
  })

  it('does not nudge on words that only contain album', () => {
    const { input } = mount()
    type(input, 'albumen and photoalbums')
    expect(radio('Mix')).toHaveAttribute('aria-checked', 'true')
  })

  it('a pill fills the draft and never sends', () => {
    const { input, onSubmit } = mount()
    fireEvent.click(screen.getByRole('button', { name: 'Last bus home' }))
    expect(input).toHaveValue('Last bus home')
    expect(input).toHaveFocus()
    expect(onSubmit).not.toHaveBeenCalled()
  })

  it('disables the pills while busy', () => {
    mount({ busy: true })
    expect(screen.getByRole('button', { name: 'Last bus home' })).toBeDisabled()
  })

  it.each([{ anonymous: true }, { albumPicks: false }])('hides the control and never nudges (%o)', async props => {
    const { input, onSubmit } = mount(props)
    expect(screen.queryByRole('radiogroup')).toBeNull()
    expect(screen.getByRole('button', { name: 'Energy journey' })).toBeInTheDocument()
    type(input, 'an album please')
    expect(screen.queryByText('Switched to Album for this prompt.')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith('an album please', { kind: 'mix' }))
  })

  it('sends a chosen Shape with a mix', async () => {
    const { input, onSubmit } = mount()
    fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
    fireEvent.click(screen.getByRole('button', { name: 'Wind down' }))
    fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
    type(input, 'slow train')
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith('slow train', { kind: 'mix', shape: 'fall' }))
  })

  it('sends an album with no Shape even when one was chosen', async () => {
    const { input, onSubmit } = mount()
    fireEvent.click(screen.getByRole('button', { name: 'Energy journey' }))
    fireEvent.click(screen.getByRole('button', { name: 'Use this shape' }))
    fireEvent.click(radio('Album'))
    type(input, 'warm, for cooking')
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith('warm, for cooking', { kind: 'album' }))
  })
})
