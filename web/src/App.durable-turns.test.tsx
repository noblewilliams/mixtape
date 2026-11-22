import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { ApiLiveTurn, MixtapeApi, SessionDetailResponse, TurnAttachEnd, TurnProgressListener } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { WorkspaceRestoreProvider } from './lib/workspace-restore'
import { createFakeApi, type FakeApiOptions } from './test/fake-api'

// Durable mix turns on the web (spec 2026-11-21 durable-mix-turns, "Web
// client"): a session read that shows a running turn attaches to it, the
// result's `seen`, and nothing changes against a server that sends no `turn`.

// Whole-app renders run long on a loaded machine.
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
const TURN = '0b6f3c1e-5d2a-4f8e-9c3b-7a1d2e4f6a8b'
const RUNNING: ApiLiveTurn = { id: TURN, status: 'running', step: 'pressing' }

const line = () => document.querySelector('.dj-thinking .dj-working-line')
const calls = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)

// The tab is in front and focused unless a test says otherwise.
let visibility: DocumentVisibilityState = 'visible'
let focused = true
beforeEach(() => {
  visibility = 'visible'
  focused = true
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => visibility })
  vi.spyOn(document, 'hasFocus').mockImplementation(() => focused)
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  localStorage.clear()
  sessionStorage.clear()
})

/** An attach the test holds open after its progress, until end(). */
function heldAttach(progress: (report: TurnProgressListener) => void = () => {}) {
  let end!: (value: TurnAttachEnd) => void
  const ended = new Promise<TurnAttachEnd>((resolve) => { end = resolve })
  const attachTurn = vi.fn(async (_id: string, onProgress?: TurnProgressListener, _signal?: AbortSignal) => {
    if (onProgress) progress(onProgress)
    return ended
  })
  return { attachTurn, end: (value: TurnAttachEnd = { kind: 'result', body: {} }) => end(value) }
}

/**
 * A fake whose reads of blue-hour show `turn` while `running()` holds, and
 * whose reads once it ended carry the DJ's reply and a new title.
 */
function serverWithTurn(running: () => boolean, overrides: Partial<MixtapeApi> = {}, turn: ApiLiveTurn = RUNNING, options: FakeApiOptions = {}) {
  const base = createFakeApi()
  let landed = false
  const live = (id: string) => id === 'blue-hour' && running()
  const api = createFakeApi({
    listSessions: async () => {
      const result = await base.listSessions()
      return { sessions: result.sessions.map((session) => (live(session.id) ? { ...session, turn } : landed && session.id === 'blue-hour' ? { ...session, title: 'Slow bridge' } : session)) }
    },
    getSession: async (id): Promise<SessionDetailResponse> => {
      const detail = await base.getSession(id)
      if (live(id)) return { ...detail, session: { ...detail.session, turn } }
      if (id !== 'blue-hour' || !landed) return detail
      return {
        ...detail,
        session: { ...detail.session, title: 'Slow bridge', queueVersion: 4 },
        messages: [...detail.messages, { id: 'server-dj', role: 'dj', content: LANDED, queueVersion: 4, createdAt: '2026-11-22T08:00:40.000Z' }],
      }
    },
    ...overrides,
  }, options)
  return { api, land: () => { landed = true } }
}

function renderApp(api: MixtapeApi) {
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} />)
}

async function openMix(title = 'Blue hour, windows down') {
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  fireEvent.click(await screen.findByRole('button', { name: `Open ${title}` }))
  return screen.findByRole('heading', { name: title })
}

async function send(text: string) {
  const input = await screen.findByRole('textbox', { name: 'Message your DJ' })
  fireEvent.change(input, { target: { value: text } })
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
}

describe('a turn the server is running', () => {
  it('attaches when the mix opens, resumes the step caption, and re-reads the session when the turn ends', async () => {
    let running = true
    const attach = heldAttach((report) => {
      report({ type: 'opened' })
      report({ type: 'turn', turnId: TURN, push: true })
      report({ type: 'step', step: 'pressing', count: 15 })
    })
    const server = serverWithTurn(() => running, { attachTurn: attach.attachTurn })
    renderApp(server.api)
    await openMix()

    // At once from the read's step, then the attach's own step with its count.
    expect(await screen.findByText('Pressing 15 songs…', {}, { timeout: 4_000 })).toBeInTheDocument()
    expect(attach.attachTurn).toHaveBeenCalledTimes(1)
    expect(attach.attachTurn.mock.calls[0][0]).toBe('blue-hour')
    // The mix is working: its Stop holds the send key's place.
    expect(screen.getByRole('button', { name: 'Stop' })).toBeInTheDocument()

    const readsBefore = calls(server.api, 'getSession').length
    running = false
    server.land()
    attach.end()
    expect(await screen.findByText(LANDED)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
    expect(calls(server.api, 'getSession').length).toBeGreaterThan(readsBefore)
    expect(attach.attachTurn).toHaveBeenCalledTimes(1)
  })

  it('re-reads the session when the attach finds nothing running (a 204)', async () => {
    let running = true
    const server = serverWithTurn(() => running, {
      attachTurn: vi.fn(async () => {
        running = false
        server.land()
        return { kind: 'not_running' } as const
      }),
    })
    renderApp(server.api)
    // The list's read already attached, found nothing running and read the mix again.
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Slow bridge' }))

    expect(await screen.findByText(LANDED)).toBeInTheDocument()
    expect(document.querySelector('.dj-thinking')).toBeNull()
    expect(calls(server.api, 'attachTurn')).toHaveLength(1)
  })

  it('shows the Mixes row as working from the list read alone, and settles it without a manual refresh', async () => {
    let running = true
    const attach = heldAttach()
    const server = serverWithTurn(() => running, { attachTurn: attach.attachTurn })
    renderApp(server.api)
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    await screen.findByRole('button', { name: 'Open Blue hour, windows down' })

    // The list's own read starts the attach; nothing was opened.
    await waitFor(() => expect(attach.attachTurn).toHaveBeenCalledTimes(1))
    expect(calls(server.api, 'getSession')).toHaveLength(0)
    // Working, as a turn sent from here is: the delete confirm says it will stop.
    fireEvent.click(screen.getByRole('button', { name: 'Select' }))
    fireEvent.click(screen.getByRole('checkbox', { name: 'Blue hour, windows down' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(screen.getByRole('alertdialog', { name: 'Delete this mix?' })).toHaveTextContent('The one being made will stop.')
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))

    running = false
    server.land()
    attach.end()
    // Settled from its own re-read: the row takes the landed title.
    expect(await screen.findByRole('button', { name: 'Open Slow bridge' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Select' }))
    fireEvent.click(screen.getByRole('checkbox', { name: 'Slow bridge' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(screen.getByRole('alertdialog', { name: 'Delete this mix?' })).not.toHaveTextContent('being made')
  })

  it('attaches once per turn, even when a later read still shows it running', async () => {
    const server = serverWithTurn(() => true, { attachTurn: vi.fn(async () => ({ kind: 'not_running' }) as const) })
    renderApp(server.api)
    await openMix()
    // The follow's own read after the attach still shows the turn running.
    await waitFor(() => expect(calls(server.api, 'getSession').length).toBeGreaterThanOrEqual(1))
    await waitFor(() => expect(document.querySelector('.dj-thinking')).toBeNull())
    fireEvent.click(screen.getByRole('button', { name: 'Mixes' }))
    await openMix()
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(calls(server.api, 'attachTurn')).toHaveLength(1)
  })

  it('resumes a reload mid-turn: the restored mix attaches from its revalidating read', async () => {
    const attach = heldAttach()
    const workspace = (api: MixtapeApi, restoring: boolean) => (
      <WorkspaceRestoreProvider userId={user.id} restoring={restoring}>
        <App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} />
      </WorkspaceRestoreProvider>
    )
    const view = render(workspace(createFakeApi(), false))
    await openMix()
    view.unmount()

    // The reload: the workspace comes back on the mix, whose read shows the turn.
    const server = serverWithTurn(() => true, { attachTurn: attach.attachTurn }, { id: TURN, status: 'running', step: 'labelling' })
    const reloaded = render(workspace(server.api, true))
    expect(attach.attachTurn).not.toHaveBeenCalled()
    reloaded.rerender(workspace(server.api, false))
    expect(await screen.findByRole('heading', { name: 'Blue hour, windows down' })).toBeInTheDocument()
    await waitFor(() => expect(attach.attachTurn).toHaveBeenCalledWith('blue-hour', expect.any(Function), expect.any(AbortSignal)))
    await waitFor(() => expect(line()).not.toBeNull())
    expect(line()).toHaveTextContent('Labelling the cassette…')
    attach.end({ kind: 'not_running' })
  })

  it('stops a followed turn: the attach goes, the stop is sent, and the session read again', async () => {
    let running = true
    const attach = heldAttach()
    const server = serverWithTurn(() => running, {
      attachTurn: attach.attachTurn,
      stopTurn: vi.fn(async () => { running = false; return { stopped: true } }),
    })
    renderApp(server.api)
    await openMix()
    const stop = await screen.findByRole('button', { name: 'Stop' })
    await waitFor(() => expect(calls(server.api, 'getSession').length).toBeGreaterThanOrEqual(1))
    const reads = calls(server.api, 'getSession').length
    fireEvent.click(stop)

    expect(document.querySelector('.dj-thinking')).toBeNull()
    expect((attach.attachTurn.mock.calls[0][2] as AbortSignal).aborted).toBe(true)
    await waitFor(() => expect(calls(server.api, 'stopTurn')).toHaveLength(1))
    await waitFor(() => expect(calls(server.api, 'getSession').length).toBeGreaterThan(reads))
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toBeEnabled()
  })
})

describe('seen', () => {
  const sentTurn: FakeApiOptions['turnProgress'] = (report, turn) => {
    if (turn.method !== 'sendMessage') return
    report({ type: 'opened' })
    report({ type: 'turn', turnId: TURN, push: true })
  }

  it('posts seen once when the result lands in a tab in front and focused on that mix', async () => {
    const api = createFakeApi({}, { turnProgress: sentTurn })
    renderApp(api)
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()

    await waitFor(() => expect(calls(api, 'markTurnSeen')).toHaveLength(1))
    expect(calls(api, 'markTurnSeen')[0].args).toEqual(['blue-hour', TURN])
    window.dispatchEvent(new Event('focus'))
    document.dispatchEvent(new Event('visibilitychange'))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(1)
  })

  it('waits while the tab is hidden, then posts it once the tab shows the mix again', async () => {
    const api = createFakeApi({}, {
      turnProgress: (report, turn) => {
        sentTurn(report, turn)
        visibility = 'hidden'
      },
    })
    renderApp(api)
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(0)

    visibility = 'visible'
    document.dispatchEvent(new Event('visibilitychange'))
    await waitFor(() => expect(calls(api, 'markTurnSeen')).toHaveLength(1))
    window.dispatchEvent(new Event('focus'))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(1)
  })

  it('does not post it from an unfocused window, nor for a mix not on screen', async () => {
    focused = false
    const api = createFakeApi({}, { turnProgress: sentTurn })
    renderApp(api)
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(0)

    // Focus comes back with the tab on Mixes: still not that mix.
    fireEvent.click(screen.getByRole('button', { name: 'Mixes' }))
    focused = true
    window.dispatchEvent(new Event('focus'))
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(0)
    await openMix()
    await waitFor(() => expect(calls(api, 'markTurnSeen')).toHaveLength(1))
  })

  it('posts seen for a new mix from Home once it opens in front', async () => {
    const api = createFakeApi({}, {
      turnProgress: (report, turn) => {
        if (turn.method !== 'createSession') return
        report({ type: 'opened' })
        report({ type: 'session', sessionId: 'created-session' })
        report({ type: 'turn', turnId: TURN, push: false })
      },
    })
    renderApp(api)
    const input = await screen.findByRole('textbox', { name: 'Describe your mix' })
    fireEvent.change(input, { target: { value: 'Rainy commute' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))

    await waitFor(() => expect(calls(api, 'markTurnSeen')).toHaveLength(1))
    expect(calls(api, 'markTurnSeen')[0].args).toEqual(['created-session', TURN])
  })

  it('swallows a seen that fails', async () => {
    const api = createFakeApi({ markTurnSeen: vi.fn(async () => { throw new TypeError('offline') }) }, { turnProgress: sentTurn })
    renderApp(api)
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    await waitFor(() => expect(calls(api, 'markTurnSeen')).toHaveLength(1))
    expect(screen.queryByRole('alert')).toBeNull()
  })
})

describe('a server without durable turns', () => {
  it('sends no seen and never attaches when no turn event comes and reads carry no turn', async () => {
    const api = createFakeApi({}, { turnProgress: [{ type: 'opened' }, { type: 'step', step: 'picking' }] })
    renderApp(api)
    await openMix()
    await send('Slower in the middle')
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'markTurnSeen')).toHaveLength(0)
    expect(calls(api, 'attachTurn')).toHaveLength(0)
  })
})
