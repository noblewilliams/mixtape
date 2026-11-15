import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MixtapeApi, SendMessageOptions, SessionDetailResponse, TurnProgressListener } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi, type FakeApiOptions } from './test/fake-api'

// Spec docs/superpowers/specs/2026-11-15-stop-a-turn-design.md.
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

function renderApp(overrides: Partial<MixtapeApi> = {}, options: FakeApiOptions = {}) {
  const api = createFakeApi(overrides, options)
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} />)
  return api
}

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

const calls = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)
const userLines = () => [...document.querySelectorAll('.conversation-turn--user')].map((node) => node.textContent)

/** Mix message turns the test holds open (until aborted) after they open. */
const heldMessages: FakeApiOptions['turnProgress'] = async (report, turn) => {
  if (turn.method !== 'sendMessage') return
  report({ type: 'opened' })
  await new Promise<void>(() => undefined)
}

/** A promise the test settles by hand. */
function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

afterEach(() => {
  cleanup()
  localStorage.clear()
  sessionStorage.clear()
})

describe('stopping a mix message turn', () => {
  it('keeps the composer open and shows Stop in place of send while the DJ works', async () => {
    renderApp({}, { turnProgress: heldMessages })
    await openMix()
    await send('Slower in the middle')

    const input = await screen.findByRole('textbox', { name: 'Message your DJ' })
    await waitFor(() => expect(screen.getByRole('button', { name: 'Stop' })).toBeInTheDocument())
    expect(input).toBeEnabled()
    expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Record a voice prompt' })).toBeNull()
    fireEvent.change(input, { target: { value: 'and then brighter' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(input).toHaveValue('and then brighter')
  })

  it('takes the turn off screen at once, puts the text back, and stops it on the server', async () => {
    const api = renderApp({}, { turnProgress: heldMessages })
    await openMix()
    const before = userLines()
    await send('Slower in the middle')
    await waitFor(() => expect(userLines()).toContain('Slower in the middle'))

    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))

    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('Slower in the middle'))
    expect(userLines()).toEqual(before)
    expect(document.querySelector('.dj-thinking')).toBeNull()
    await waitFor(() => expect(calls(api, 'stopTurn')).toHaveLength(1))
    expect(calls(api, 'stopTurn')[0].args).toEqual(['blue-hour'])
    const [, , , options] = calls(api, 'sendMessage')[0].args as [string, string, unknown, SendMessageOptions]
    expect(options.signal?.aborted).toBe(true)
    // An abandoned turn draws no error line, and send is back.
    expect(screen.queryByText(/interrupted|went wrong|try again/i)).toBeNull()
    expect(screen.getByRole('button', { name: 'Send message' })).toBeEnabled()
  })

  it('keeps a draft typed meanwhile instead of putting the stopped text back', async () => {
    renderApp({}, { turnProgress: heldMessages })
    await openMix()
    await send('Slower in the middle')
    const input = await screen.findByRole('textbox', { name: 'Message your DJ' })
    await waitFor(() => expect(input).toHaveValue(''))
    fireEvent.change(input, { target: { value: 'actually, louder' } })

    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))

    await waitFor(() => expect(screen.getByRole('button', { name: 'Send message' })).toBeEnabled())
    expect(input).toHaveValue('actually, louder')
  })

  it('reads the session again and shows what landed when the stop came too late', async () => {
    const base = createFakeApi()
    const landed: SessionDetailResponse = {
      ...(await base.getSession('blue-hour')),
    }
    landed.messages = [...landed.messages,
      { id: 'landed-user', role: 'user', content: 'Slower in the middle', createdAt: new Date().toISOString() },
      { id: 'landed-dj', role: 'dj', content: 'Slower now, and the rain stays.', queueVersion: 5, createdAt: new Date().toISOString() },
    ]
    let reads = 0
    const api = renderApp({
      stopTurn: async () => ({ stopped: false }),
      getSession: async (id) => (id === 'blue-hour' && ++reads > 1 ? landed : base.getSession(id)),
    }, { turnProgress: heldMessages })
    await openMix()
    await send('Slower in the middle')
    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))

    expect(await screen.findByText('Slower now, and the rain stays.')).toBeInTheDocument()
    expect(calls(api, 'stopTurn')).toHaveLength(1)
  })

  it('re-reads the session when the stop itself fails', async () => {
    let reads = 0
    const base = createFakeApi()
    const api = renderApp({
      stopTurn: async () => { throw new TypeError('Failed to fetch') },
      getSession: async (id) => { if (id === 'blue-hour') reads += 1; return base.getSession(id) },
    }, { turnProgress: heldMessages })
    await openMix()
    const opened = reads
    await send('Slower in the middle')
    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))
    await waitFor(() => expect(reads).toBeGreaterThan(opened))
    expect(calls(api, 'stopTurn')).toHaveLength(1)
  })

  it('holds a send made while the stop settles until the stop answers', async () => {
    const stop = deferred<{ stopped: boolean }>()
    let held = true
    const api = renderApp({ stopTurn: () => stop.promise }, {
      turnProgress: async (report, turn) => {
        if (turn.method !== 'sendMessage' || !held) return
        report({ type: 'opened' })
        await new Promise<void>(() => undefined)
      },
    })
    await openMix()
    await send('Slower in the middle')
    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))
    await waitFor(() => expect(calls(api, 'stopTurn')).toHaveLength(1))
    held = false

    fireEvent.click(await screen.findByRole('button', { name: 'Send message' }))
    // The new turn shows as working, but goes out only once the stop has answered.
    await waitFor(() => expect(document.querySelector('.dj-thinking')).not.toBeNull())
    expect(screen.getByRole('button', { name: 'Stop' })).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(calls(api, 'sendMessage')).toHaveLength(1)

    stop.resolve({ stopped: true })
    expect(await screen.findByText(REPLY)).toBeInTheDocument()
    expect(calls(api, 'sendMessage')).toHaveLength(2)
    expect(calls(api, 'stopTurn')).toHaveLength(1)
  })

  it('shows no Stop on an album turn', async () => {
    const hold = deferred<void>()
    const base = createFakeApi()
    renderApp({
      sendMessage: async (...args) => { await hold.promise; return base.sendMessage(...args) },
      createSession: base.createSession,
      getSession: base.getSession,
    })
    fireEvent.click(await screen.findByRole('radio', { name: 'Album' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Rainy evening' } })
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    await send('Older')
    expect(await screen.findByText('Finding your album · checking Apple Music')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Stop' })).toBeNull()
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toBeEnabled()
    hold.resolve()
    await waitFor(() => expect(document.querySelector('.dj-thinking')).toBeNull())
  })
})

describe('stopping a new mix from Home', () => {
  /** A create that names its session once `name` resolves, then holds until aborted. */
  function heldCreate(name: Promise<void> = Promise.resolve()) {
    const turnProgress: FakeApiOptions['turnProgress'] = async (report: TurnProgressListener, turn) => {
      if (turn.method !== 'createSession') return
      report({ type: 'opened' })
      await name
      report({ type: 'session', sessionId: 'created-session' })
      await new Promise<void>(() => undefined)
    }
    return turnProgress
  }

  async function startMix(prompt: string) {
    const input = await screen.findByRole('textbox', { name: 'Describe your mix' })
    fireEvent.change(input, { target: { value: prompt } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    return input
  }

  it('shows Stop while the mix starts, and stops it once the session is named', async () => {
    const api = renderApp({}, { turnProgress: heldCreate() })
    const input = await startMix('Rainy commute')
    const stop = await screen.findByRole('button', { name: 'Stop' })
    expect(input).toBeEnabled()
    await new Promise((resolve) => setTimeout(resolve, 10))

    fireEvent.click(stop)

    await waitFor(() => expect(calls(api, 'stopTurn')).toHaveLength(1))
    expect(calls(api, 'stopTurn')[0].args).toEqual(['created-session'])
    expect(screen.getByRole('heading', { name: 'Home' })).toBeInTheDocument()
    expect(input).toHaveValue('Rainy commute')
    expect(screen.getByRole('button', { name: 'Make a mix' })).toBeEnabled()
    expect(screen.queryByRole('button', { name: /Rainy commute/ })).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
    const [, , , , options] = calls(api, 'createSession')[0].args as [string, unknown, unknown, unknown, { signal: AbortSignal }]
    expect(options.signal.aborted).toBe(true)
  })

  it('waits for the session to be named before it stops, and is idle at once meanwhile', async () => {
    const named = deferred<void>()
    const api = renderApp({}, { turnProgress: heldCreate(named.promise) })
    const input = await startMix('Rainy commute')
    fireEvent.click(await screen.findByRole('button', { name: 'Stop' }))

    await waitFor(() => expect(screen.getByRole('button', { name: 'Make a mix' })).toBeEnabled())
    expect(input).toHaveValue('Rainy commute')
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(calls(api, 'stopTurn')).toHaveLength(0)

    named.resolve()
    await waitFor(() => expect(calls(api, 'stopTurn')).toHaveLength(1))
    expect(calls(api, 'stopTurn')[0].args).toEqual(['created-session'])
    expect(screen.getByRole('heading', { name: 'Home' })).toBeInTheDocument()
  })

  it('goes on into the new mix when the stop came too late', async () => {
    const base = createFakeApi()
    const created = await base.createSession('Rainy commute')
    renderApp({
      stopTurn: async () => ({ stopped: false }),
      getSession: async (id) => (id === 'created-session' ? created : base.getSession(id)),
    }, { turnProgress: heldCreate() })
    await startMix('Rainy commute')
    const stop = await screen.findByRole('button', { name: 'Stop' })
    await new Promise((resolve) => setTimeout(resolve, 10))
    fireEvent.click(stop)

    expect(await screen.findByRole('textbox', { name: 'Message your DJ' })).toBeInTheDocument()
    expect(await screen.findByText('I made a first pass for this moment.')).toBeInTheDocument()
  })

  it('shows no Stop while an album is found', async () => {
    const hold = deferred<void>()
    const base = createFakeApi()
    renderApp({ createSession: async (...args) => { await hold.promise; return base.createSession(...args) } })
    fireEvent.click(await screen.findByRole('radio', { name: 'Album' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Rainy evening' } })
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Find an album' })).toBeDisabled())
    expect(screen.queryByRole('button', { name: 'Stop' })).toBeNull()
    hold.resolve()
  })
})
