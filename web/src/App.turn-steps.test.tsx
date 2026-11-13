import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MixtapeApi, SendMessageOptions, SessionDetailResponse, TurnProgressListener } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi, type FakeApiOptions } from './test/fake-api'

// Whole-app renders run long on a loaded machine; the dwell adds 1.5 s to the step tests.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}
const musicKit = {
  connect: vi.fn(async () => undefined),
  snapshot: vi.fn(),
  play: vi.fn(async () => undefined),
  playAlbum: vi.fn(async () => undefined),
  pause: vi.fn(async () => undefined),
  createPlaylist: vi.fn(async () => undefined),
} as unknown as MusicKitClient

const REPLY = 'I kept the opening intact, then reshaped the middle around that feeling.'
const LANDED = 'Slower in the middle now, and the rain stays.'
const CUT = 'Something interrupted the connection. Please try again.'

function renderApp(overrides: Partial<MixtapeApi> = {}, options: FakeApiOptions = {}, props: { landedReplyRereadMs?: number } = {}) {
  const api = createFakeApi(overrides, options)
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} {...props} />)
  return api
}

/** Mixes, then the first demo mix. */
async function openMix() {
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  return screen.findByRole('textbox', { name: 'Message your DJ' })
}

async function send(text: string) {
  const input = await screen.findByRole('textbox', { name: 'Message your DJ' })
  fireEvent.change(input, { target: { value: text } })
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
}

const line = () => document.querySelector('.dj-thinking .dj-working-line')
const calls = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)

/** A turn the test holds open after its progress, until release(). */
function heldTurn(progress: (report: TurnProgressListener) => void | Promise<void>) {
  let release!: () => void
  const held = new Promise<void>((resolve) => { release = resolve })
  const turnProgress: FakeApiOptions['turnProgress'] = async (report, turn) => {
    if (turn.method !== 'sendMessage') return
    await progress(report)
    await held
  }
  return { turnProgress, release: () => release() }
}

afterEach(() => {
  cleanup()
  localStorage.clear()
  sessionStorage.clear()
})

describe('a streamed mix turn', () => {
  it('shows the step lines under the cassette and clears them when the reply lands', async () => {
    const turn = heldTurn(async (report) => {
      report({ type: 'opened' })
      // The step comes a moment after the line is up, inside its dwell.
      await new Promise((resolve) => setTimeout(resolve, 20))
      report({ type: 'step', step: 'labelling', title: 'Slow bridge' })
    })
    const api = renderApp({}, { turnProgress: turn.turnProgress })
    await openMix()
    await send('Slower in the middle')

    // The listening line holds its dwell, then the step takes over.
    expect(line()).toHaveTextContent('The DJ is listening…')
    expect(await screen.findByText('Labelling it “Slow bridge”…', {}, { timeout: 4_000 })).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toHaveAttribute('aria-label', 'The DJ is listening')
    const [, , , options] = calls(api, 'sendMessage')[0].args as [string, string, unknown, SendMessageOptions]
    expect(options.onProgress).toEqual(expect.any(Function))

    turn.release()
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
    expect(screen.queryByText('Labelling it “Slow bridge”…')).toBeNull()
  })

  it('keeps the current step when the listener leaves the mix and comes back mid-turn', async () => {
    const turn = heldTurn((report) => {
      report({ type: 'opened' })
      report({ type: 'step', step: 'pressing', count: 15 })
    })
    renderApp({}, { turnProgress: turn.turnProgress })
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText('Pressing 15 songs to tape…', {}, { timeout: 4_000 })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    await screen.findByRole('heading', { name: 'Home' })
    expect(screen.queryByText('Pressing 15 songs to tape…')).toBeNull()
    await openMix()
    // At once: the step came long enough ago, so no dwell holds the listening line.
    expect(line()).toHaveTextContent('Pressing 15 songs to tape…')

    turn.release()
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
  })

  it('keeps each mix’s cassette to its own turn when two mixes are working at once', async () => {
    const releases = new Map<string, () => void>()
    const api = renderApp({}, {
      turnProgress: async (report, turn) => {
        if (turn.method !== 'sendMessage') return
        report({ type: 'opened' })
        await new Promise<void>((resolve) => releases.set(turn.sessionId!, resolve))
      },
    })
    const open = async (title: string) => {
      fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
      fireEvent.click(await screen.findByRole('button', { name: `Open ${title}` }))
      await screen.findByRole('heading', { name: title })
    }
    await open('Blue hour, windows down')
    await send('Slower')
    await open('Sunday kitchen radio')
    await send('Brighter')
    await waitFor(() => expect(calls(api, 'sendMessage')).toHaveLength(2))
    expect(document.querySelector('.dj-thinking')).not.toBeNull()

    await open('Blue hour, windows down')
    expect(document.querySelector('.dj-thinking')).not.toBeNull()
    releases.get('blue-hour')!()
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()

    // Mix A's turn ending leaves mix B's still working.
    await open('Sunday kitchen radio')
    expect(document.querySelector('.dj-thinking')).not.toBeNull()
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toBeDisabled()
    releases.get('sunday-kitchen')!()
    await waitFor(() => expect(document.querySelector('.dj-thinking')).toBeNull())
  })

  it('walks the timed lines against a server that answers JSON', async () => {
    const api = renderApp()
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    // The fake reports nothing (an older server): the call still asked for progress.
    expect((calls(api, 'sendMessage')[0].args[3] as SendMessageOptions).onProgress).toEqual(expect.any(Function))
  })

  it('adds only the progress listener to a mix message’s call', async () => {
    const api = renderApp()
    await openMix()
    await send('Slower')
    await screen.findByText(REPLY)
    expect(calls(api, 'sendMessage')[0].args).toEqual(['blue-hour', 'Slower', undefined, { onProgress: expect.any(Function) }])
  })
})

describe('a stream that drops', () => {
  /** The turn opens a stream, reports a step, then the connection drops. */
  const dropped = (options: SendMessageOptions | undefined) => {
    options?.onProgress?.({ type: 'opened' })
    options?.onProgress?.({ type: 'step', step: 'picking' })
    return Promise.reject(new TypeError('network error'))
  }
  /** The read once the turn landed on the server: its own copy of the listener's line, the reply, the new title. */
  const landedIn = (detail: SessionDetailResponse): SessionDetailResponse => ({
    ...detail,
    messages: [
      ...detail.messages,
      { id: 'server-user', role: 'user', content: 'Slower in the middle', createdAt: '2026-11-13T08:00:00.000Z' },
      { id: 'server-dj', role: 'dj', content: LANDED, queueVersion: 4, createdAt: '2026-11-13T08:00:40.000Z' },
    ],
    session: { ...detail.session, queueVersion: 4, title: 'Slow bridge' },
  })
  /** getSession for the drop tests: reads before the drop are the fake's; `after(n)` answers the n-th read after it. */
  function readsAfterDrop(after: (n: number, detail: SessionDetailResponse) => SessionDetailResponse | Promise<SessionDetailResponse>) {
    const base = createFakeApi()
    let droppedYet = false
    let n = 0
    const getSession = async (id: string) => {
      const detail = await base.getSession(id)
      return droppedYet ? after((n += 1), detail) : detail
    }
    const sendMessage: MixtapeApi['sendMessage'] = (_id, _text, _arc, options) => {
      droppedYet = true
      return dropped(options)
    }
    return { getSession, sendMessage }
  }
  const transcript = () => document.querySelector('.conversation-scroll') as HTMLElement
  const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

  it('after it opened: keeps the listener’s line, shows the failure, and adopts a reply that landed', async () => {
    const api = renderApp(readsAfterDrop((_n, detail) => landedIn(detail)), {}, { landedReplyRereadMs: 60 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')

    expect(await screen.findByText(LANDED)).toBeInTheDocument()
    expect(within(transcript()).getAllByText('Slower in the middle')).toHaveLength(1)
    expect(within(transcript()).queryByText(CUT)).toBeNull()
    expect(await screen.findByRole('heading', { name: 'Slow bridge' })).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
    await pause(150)
    // Adopted at once: no second read.
    expect(calls(api, 'getSession')).toHaveLength(reads + 1)
  })

  it('after it opened: reads once more a little later, and adopts the reply that landed by then', async () => {
    const api = renderApp(readsAfterDrop((n, detail) => (n === 1 ? detail : landedIn(detail))), {}, { landedReplyRereadMs: 60 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')

    expect(await screen.findByText(CUT)).toBeInTheDocument()
    expect(await screen.findByText(LANDED)).toBeInTheDocument()
    expect(within(transcript()).queryByText(CUT)).toBeNull()
    expect(within(transcript()).getAllByText('Slower in the middle')).toHaveLength(1)
    expect(await screen.findByRole('heading', { name: 'Slow bridge' })).toBeInTheDocument()
    expect(calls(api, 'getSession')).toHaveLength(reads + 2)
  })

  it('after it opened: keeps the failure when neither read finds a new reply', async () => {
    const api = renderApp(readsAfterDrop((_n, detail) => detail), {}, { landedReplyRereadMs: 60 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')

    expect(await screen.findByText(CUT)).toBeInTheDocument()
    await waitFor(() => expect(calls(api, 'getSession')).toHaveLength(reads + 2))
    await pause(200)
    expect(calls(api, 'getSession')).toHaveLength(reads + 2)
    expect(screen.getByText('Slower in the middle')).toBeInTheDocument()
    expect(screen.getByText(CUT)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
  })

  it('gives up on a read when the mix changed while it was out', async () => {
    let answer!: (detail: SessionDetailResponse) => void
    const base = createFakeApi()
    let sends = 0
    let held = true
    const api = renderApp({
      getSession: async (id) => {
        const detail = await base.getSession(id)
        if (sends === 1 && held) {
          held = false
          return new Promise<SessionDetailResponse>((resolve) => { answer = resolve })
        }
        return detail
      },
      sendMessage: (...args) => ((sends += 1) === 1 ? dropped(args[3]) : base.sendMessage(...args)),
    }, {}, { landedReplyRereadMs: 60 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')
    expect(await screen.findByText(CUT)).toBeInTheDocument()
    await waitFor(() => expect(calls(api, 'getSession')).toHaveLength(reads + 1))

    // The listener sends again while the read is out.
    await send('Brighter')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    answer(landedIn(await base.getSession('blue-hour')))
    await pause(200)

    expect(screen.queryByText(LANDED)).toBeNull()
    expect(screen.getByText(CUT)).toBeInTheDocument()
    // The read gave up: nothing scheduled after it (the other read is the second turn's own).
    expect(calls(api, 'getSession')).toHaveLength(reads + 2)
  })

  it('cancels the later read when the workspace goes', async () => {
    const api = renderApp(readsAfterDrop((_n, detail) => detail), {}, { landedReplyRereadMs: 80 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')
    expect(await screen.findByText(CUT)).toBeInTheDocument()
    await waitFor(() => expect(calls(api, 'getSession')).toHaveLength(reads + 1))
    cleanup()
    await pause(250)
    expect(calls(api, 'getSession')).toHaveLength(reads + 1)
  })

  it('before it opened: shows the failure as today and reads nothing', async () => {
    const api = renderApp({ sendMessage: () => Promise.reject(new TypeError('Failed to fetch')) }, {}, { landedReplyRereadMs: 40 })
    await openMix()
    const reads = calls(api, 'getSession').length
    await send('Slower in the middle')

    expect(await screen.findByText(CUT)).toBeInTheDocument()
    expect(screen.getByText('Slower in the middle')).toBeInTheDocument()
    await pause(150)
    expect(calls(api, 'getSession')).toHaveLength(reads)
  })
})

describe('an album turn', () => {
  it('asks for no progress and keeps its own line', async () => {
    let release!: () => void
    const held = new Promise<void>((resolve) => { release = resolve })
    const base = createFakeApi()
    const api = renderApp({
      sendMessage: async (...args) => {
        await held
        return base.sendMessage(...args)
      },
      createSession: base.createSession,
      getSession: base.getSession,
    })
    fireEvent.click(await screen.findByRole('radio', { name: 'Album' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Rainy evening' } })
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    await send('Older')

    expect(await screen.findByText('Finding your album · checking Apple Music')).toBeInTheDocument()
    expect(line()).toBeNull()
    expect(calls(api, 'sendMessage')[0].args).toEqual([expect.any(String), 'Older', undefined])
    release()
    await waitFor(() => expect(document.querySelector('.dj-thinking')).toBeNull())
  })
})
