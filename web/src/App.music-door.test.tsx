import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, REMAKE_TEXT, type MixtapeApi, type OnboardingResponse, type SendMessageResponse, type SessionDetailResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import { AI_CONSENT_TITLE } from './components/AiConsent'
import { writePlaysOn } from './lib/plays-on'
import { MusicKitClientError, type MusicKitClient } from './musickit/client'
import { createFakeApi, type FakeApiOptions } from './test/fake-api'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}
const blank: OnboardingResponse = {
  userId: 'user-1',
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
  interview: null,
  musicReady: false,
}
const LINE = 'From Mixtape’s catalog for now. With your music, the DJ picks from what you actually play.'
const PROMPT = 'Rainy commute over the bridge'

function createFakeMusicKit(overrides: Partial<MusicKitClient> = {}): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
    play: vi.fn(async () => undefined),
    playAlbum: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
    ...overrides,
  }
}

type FakeApi = ReturnType<typeof createFakeApi>

/**
 * New mixes come from the catalog (`notPersonal`) until `makePersonal()`; every read says the same.
 * `onboarding` may be a function, read on every request; `overrides` may build on the fake behind it.
 */
function catalogApi(
  onboarding: Partial<OnboardingResponse> | (() => Partial<OnboardingResponse>),
  overrides: Partial<MixtapeApi> | ((base: FakeApi) => Partial<MixtapeApi>) = {},
  options: FakeApiOptions = {},
) {
  const base = createFakeApi({}, options)
  let notPersonal = true
  const api = createFakeApi({
    getOnboarding: async () => ({ ...blank, ...(typeof onboarding === 'function' ? onboarding() : onboarding) }),
    createSession: async (...args) => {
      const created = await base.createSession(...args)
      return { ...created, session: { ...created.session, notPersonal } }
    },
    getSession: async (id) => {
      const detail = await base.getSession(id)
      return { ...detail, session: { ...detail.session, notPersonal } }
    },
    sendMessage: base.sendMessage,
    ...(typeof overrides === 'function' ? overrides(base) : overrides),
  })
  return { api, base, makePersonal: () => { notPersonal = false } }
}

/** Post-turn session reads the test settles by hand, in any order. */
function heldReads(base: FakeApi) {
  const pending: Array<{ id: string; resolve: (detail: SessionDetailResponse) => void; reject: (cause: unknown) => void }> = []
  const getSession = vi.fn((id: string) => new Promise<SessionDetailResponse>((resolve, reject) => pending.push({ id, resolve, reject })))
  return {
    getSession,
    pending,
    async settle(notPersonal: boolean, index = 0) {
      const [read] = pending.splice(index, 1)
      const detail = await base.getSession(read.id)
      read.resolve({ ...detail, session: { ...detail.session, notPersonal } })
    },
    fail(index = 0) {
      const [read] = pending.splice(index, 1)
      read.reject(new Error('offline'))
    },
  }
}

function renderApp(api: ReturnType<typeof createFakeApi>, musicKit: MusicKitClient = createFakeMusicKit()) {
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="google" musicKit={musicKit} user={user} onSignOut={vi.fn()} />)
  return { api, musicKit }
}

async function createTape(api: ReturnType<typeof createFakeApi>) {
  await screen.findByRole('heading', { name: 'Home' })
  await waitFor(() => expect(api.calls.some((call) => call.method === 'getOnboarding')).toBe(true))
  fireEvent.change(screen.getByLabelText('Describe your mix'), { target: { value: PROMPT } })
  fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
  await screen.findByRole('heading', { name: PROMPT })
}

const funnel = (api: ReturnType<typeof createFakeApi>) =>
  api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => (call.args[0] as { type: string }).type)
const step = (name: string) => screen.findByRole('heading', { level: 1, name: `Step 3 of 3, ${name}` })
const door = () => screen.getByText(LINE).closest('[role="status"]') as HTMLElement
const mixPanel = () => screen.getByRole('complementary', { name: 'Your mix' })

function stubNarrow(narrow: boolean) {
  vi.stubGlobal('matchMedia', vi.fn((query: string) => ({
    matches: narrow && query === '(max-width: 1020px)',
    media: query,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  })))
}

beforeEach(() => localStorage.clear())
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('the music door on a catalog mix', () => {
  it('sits under the DJ turn with the Spotify action, and the desktop banner keeps the label only', async () => {
    const { api } = catalogApi({ chosenService: 'spotify' })
    renderApp(api)
    await createTape(api)

    expect(within(door()).getByRole('button', { name: 'Add Spotify music' })).toBeInTheDocument()
    const banner = within(mixPanel()).getByText('Not personal yet').closest('.banner') as HTMLElement
    expect(banner).toHaveTextContent('From Mixtape’s catalog for now.')
    expect(within(banner).queryByRole('button')).toBeNull()
    expect(screen.getAllByText(LINE)).toHaveLength(1)
  })

  it('door: records music_door_tapped and opens the Exportify page for a Spotify listener', async () => {
    const { api } = catalogApi({ chosenService: 'spotify' })
    renderApp(api)
    await createTape(api)

    fireEvent.click(within(door()).getByRole('button', { name: 'Add Spotify music' }))
    expect(await step('Export from Exportify')).toBeInTheDocument()
    expect(funnel(api)).toContain('music_door_tapped')
    expect(funnel(api)).not.toContain('music_chip_tapped')
  })

  it('door: Sync Apple Music opens the sync page for an Apple Music listener', async () => {
    const { api } = catalogApi({ chosenService: 'apple' })
    renderApp(api)
    await createTape(api)

    fireEvent.click(within(door()).getByRole('button', { name: 'Sync Apple Music' }))
    expect(await step('Syncing your library')).toBeInTheDocument()
    expect(funnel(api).filter((type) => type === 'music_door_tapped')).toHaveLength(1)
  })

  it('retrySync: a failed sync reads Sync didn’t finish. on the mix, and Try again reopens the sync', async () => {
    const { api } = catalogApi({ chosenService: 'apple' })
    const musicKit = createFakeMusicKit({ snapshot: vi.fn(async () => { throw new Error('offline') }) })
    renderApp(api, musicKit)
    await createTape(api)

    fireEvent.click(within(door()).getByRole('button', { name: 'Sync Apple Music' }))
    await step('Syncing your library')
    await screen.findByText(/Sync stopped at/)
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())

    const failed = await screen.findByText('Sync didn’t finish.')
    const region = failed.closest('[role="status"]') as HTMLElement
    expect(region).toHaveClass('music-door--err')
    fireEvent.click(within(region).getByRole('button', { name: 'Try again' }))
    expect(await step('Syncing your library')).toBeInTheDocument()
    expect(funnel(api).filter((type) => type === 'music_door_tapped')).toHaveLength(2)
    await waitFor(() => expect(musicKit.snapshot).toHaveBeenCalledTimes(2))
  })

  it('reads a refused Apple Music authorisation as the first state again, not a failure', async () => {
    const { api } = catalogApi({ chosenService: 'apple' })
    const musicKit = createFakeMusicKit({
      connect: vi.fn(async () => { throw new MusicKitClientError('authorization_cancelled', 'cancelled') }),
    })
    renderApp(api, musicKit)
    await createTape(api)

    fireEvent.click(within(door()).getByRole('button', { name: 'Sync Apple Music' }))
    await step('Syncing your library')
    await waitFor(() => expect(musicKit.connect).toHaveBeenCalled())
    await screen.findByText(/Sync stopped at/)
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())

    expect(within(door()).getByRole('button', { name: 'Sync Apple Music' })).toBeInTheDocument()
    expect(screen.queryByText('Sync didn’t finish.')).toBeNull()
  })

  it('door: Choose files for a Spotify listener who plays on Apple Music opens the Exportify page and starts no sync', async () => {
    writePlaysOn('apple')
    const { api } = catalogApi({ chosenService: 'spotify', markedRequestedAt: '2026-11-08T09:00:00.000Z' })
    const musicKit = createFakeMusicKit()
    renderApp(api, musicKit)
    await createTape(api)

    const waiting = screen.getByText('Waiting on your Spotify data. It can take a few days.').closest('[role="status"]') as HTMLElement
    fireEvent.click(within(waiting).getByRole('button', { name: 'Choose files' }))
    expect(await step('Export from Exportify')).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /Syncing your library/ })).toBeNull()
    expect(funnel(api)).toContain('music_door_tapped')
    await act(() => new Promise((resolve) => setTimeout(resolve, 0)))
    expect(musicKit.connect).not.toHaveBeenCalled()
    expect(musicKit.snapshot).not.toHaveBeenCalled()
  })

  it('never tells a Spotify device that an Apple sync failed', async () => {
    const { api } = catalogApi({ chosenService: 'apple' })
    const musicKit = createFakeMusicKit({ snapshot: vi.fn(async () => { throw new Error('offline') }) })
    renderApp(api, musicKit)
    await createTape(api)
    fireEvent.click(within(door()).getByRole('button', { name: 'Sync Apple Music' }))
    await step('Syncing your library')
    await screen.findByText(/Sync stopped at/)
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())
    expect(await screen.findByText('Sync didn’t finish.')).toBeInTheDocument()

    act(() => writePlaysOn('spotify'))
    expect(screen.queryByText('Sync didn’t finish.')).toBeNull()
    expect(within(door()).getByRole('button', { name: 'Add Spotify music' })).toBeInTheDocument()
  })

  it('gives focus to the door’s current action when the opener is gone', async () => {
    let synced = false
    const { api } = catalogApi(() => ({ chosenService: 'apple', musicReady: synced }))
    const musicKit = createFakeMusicKit({
      snapshot: vi.fn(async () => {
        synced = true
        return { storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 }
      }),
    })
    renderApp(api, musicKit)
    await createTape(api)
    const opener = within(door()).getByRole('button', { name: 'Sync Apple Music' })
    opener.focus()
    fireEvent.click(opener)
    await step('Syncing your library')
    const done = await screen.findByRole('button', { name: 'Done' })
    await waitFor(() => expect(done).toBeEnabled())
    await waitFor(() => expect(opener.isConnected).toBe(false))
    fireEvent.click(done)
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())
    await waitFor(() => expect(screen.getByRole('button', { name: 'Remake with my music' })).toHaveFocus())
  })

  it('gives focus to the composer when the opener is gone and the door has no action', async () => {
    const { api } = catalogApi({ chosenService: 'apple' })
    const musicKit = createFakeMusicKit({ snapshot: vi.fn(() => new Promise<never>(() => undefined)) })
    renderApp(api, musicKit)
    await createTape(api)
    const opener = within(door()).getByRole('button', { name: 'Sync Apple Music' })
    opener.focus()
    fireEvent.click(opener)
    await step('Syncing your library')
    await waitFor(() => expect(musicKit.snapshot).toHaveBeenCalled())
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())
    expect(await screen.findByText('Syncing Apple Music…')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByLabelText('Message your DJ')).toHaveFocus())
  })

  it('shows no door on a personal mix', async () => {
    const api = createFakeApi({ getOnboarding: async () => ({ ...blank, chosenService: 'spotify' }) })
    renderApp(api)
    await createTape(api)
    expect(screen.queryByText(LINE)).toBeNull()
    expect(screen.queryByText('Not personal yet')).toBeNull()
  })
})

describe('the phone shell’s banner', () => {
  it('carries the full line and the action; its route reopens the panel on the way back', async () => {
    stubNarrow(true)
    const { api } = catalogApi({ chosenService: 'spotify' })
    renderApp(api)
    await createTape(api)
    fireEvent.click(screen.getByRole('button', { name: 'Open your mix' }))
    expect(mixPanel()).toHaveClass('is-open')

    const banner = within(mixPanel()).getByText('Not personal yet').closest('.banner') as HTMLElement
    expect(banner).toHaveTextContent(LINE)
    fireEvent.click(within(banner).getByRole('button', { name: 'Add Spotify music' }))
    expect(await step('Export from Exportify')).toBeInTheDocument()
    expect(funnel(api)).toContain('music_door_tapped')

    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(screen.queryByTestId('first-run')).not.toBeInTheDocument())
    expect(mixPanel()).toHaveClass('is-open')
  })

  it('keeps one door in the accessibility tree: the conversation’s while the panel is closed, the banner’s while it covers the conversation', async () => {
    stubNarrow(true)
    const { api } = catalogApi({ chosenService: 'spotify' })
    renderApp(api)
    await createTape(api)

    expect(document.querySelectorAll('.music-door, .banner--door')).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: 'Add Spotify music' })).toHaveLength(1)
    expect(within(mixPanel()).queryByText('Not personal yet')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Open your mix' }))
    const reachable = screen.getAllByRole('button', { name: 'Add Spotify music' })
    expect(reachable).toHaveLength(1)
    expect(mixPanel()).toContainElement(reachable[0])
    const covered = document.querySelector('.conversation-panel .music-door')!.closest('.music-door-slot') as HTMLElement
    expect(covered).toHaveAttribute('aria-hidden', 'true')
    expect(covered).toHaveAttribute('inert')

    fireEvent.click(within(mixPanel()).getByRole('button', { name: 'Close your mix' }))
    expect(covered).not.toHaveAttribute('aria-hidden')
    expect(covered).not.toHaveAttribute('inert')
    expect(screen.getAllByRole('button', { name: 'Add Spotify music' })).toHaveLength(1)
  })
})

describe('the history pill', () => {
  it('history: offers Add my listening history to a Spotify listener, records music_chip_tapped and opens the data request', async () => {
    const api = createFakeApi({ getOnboarding: async () => ({ ...blank, chosenService: 'spotify' }) }, { historyPill: true })
    renderApp(api)
    await createTape(api)

    const pill = await screen.findByRole('button', { name: 'Add my listening history' })
    expect(pill.closest('.conversation-pills')).not.toBeNull()
    fireEvent.click(pill)
    expect(await step('Request your data')).toBeInTheDocument()
    expect(funnel(api)).toContain('music_chip_tapped')
    expect(funnel(api)).not.toContain('music_door_tapped')
    expect(api.calls.filter((call) => call.method === 'sendMessage')).toHaveLength(0)
  })

  it('stays away when the router has nowhere to go: Apple Music or no platform on the web', async () => {
    for (const chosenService of ['apple', null] as const) {
      const api = createFakeApi({ getOnboarding: async () => ({ ...blank, chosenService }) }, { historyPill: true })
      renderApp(api)
      await createTape(api)
      expect(screen.queryByRole('button', { name: 'Add my listening history' })).toBeNull()
      cleanup()
      localStorage.clear()
    }
  })

  it('stays away when the turn did not offer it', async () => {
    const api = createFakeApi({ getOnboarding: async () => ({ ...blank, chosenService: 'spotify' }) })
    renderApp(api)
    await createTape(api)
    expect(screen.queryByRole('button', { name: 'Add my listening history' })).toBeNull()
  })

  it('goes with the next turn, as the other suggestions do', async () => {
    const api = createFakeApi({ getOnboarding: async () => ({ ...blank, chosenService: 'spotify' }) }, { historyPill: true })
    renderApp(api)
    await createTape(api)
    await screen.findByRole('button', { name: 'Add my listening history' })
    fireEvent.change(screen.getByLabelText('Message your DJ'), { target: { value: 'Brighter' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await screen.findByText(/reshaped the middle around that feeling/)
    expect(screen.queryByRole('button', { name: 'Add my listening history' })).toBeNull()
  })
})

describe('Remake with my music', () => {
  function deferredTurns(base: FakeApi) {
    const releases: Array<() => void> = []
    const sendMessage = vi.fn((...args: Parameters<MixtapeApi['sendMessage']>) =>
      new Promise<SendMessageResponse>((resolve) => releases.push(() => resolve(base.sendMessage(...args)))))
    return { sendMessage, release: () => releases.shift()?.() }
  }
  const REPLY = /reshaped the middle around that feeling/
  const remakeButton = () => screen.queryByRole('button', { name: 'Remake with my music' })

  it('sends the remake through the send path, records remake_tapped once, and holds the door out of sight until the post-turn read lands', async () => {
    const turns = deferredTurns(createFakeApi())
    let reads!: ReturnType<typeof heldReads>
    const { api } = catalogApi({ chosenService: 'spotify', musicReady: true }, (base) => {
      reads = heldReads(base)
      return { sendMessage: turns.sendMessage, getSession: reads.getSession }
    })
    renderApp(api)
    await createTape(api)

    const musicIn = screen.getByText('Your music is in.').closest('[role="status"]') as HTMLElement
    expect(musicIn).toHaveTextContent('Your music is in. This mix was made before it.')
    fireEvent.click(within(musicIn).getByRole('button', { name: 'Remake with my music' }))

    expect(turns.sendMessage).toHaveBeenCalledOnce()
    expect(turns.sendMessage).toHaveBeenCalledWith('created-session', REMAKE_TEXT, undefined, { remake: true })
    expect(funnel(api).filter((type) => type === 'remake_tapped')).toHaveLength(1)
    expect([...document.querySelectorAll('.conversation-turn--user')].at(-1)).toHaveTextContent(/^Remake this with my music$/)
    expect(screen.getByText('The DJ is listening…')).toBeInTheDocument()
    expect(remakeButton()).toBeNull()

    await act(async () => turns.release())
    // The reply has landed and the session read has not: synchronously, no Remake to tap or hear.
    expect(screen.getByText(REPLY)).toBeInTheDocument()
    expect(screen.queryByText('The DJ is listening…')).toBeNull()
    expect(reads.pending).toHaveLength(1)
    expect(remakeButton()).toBeNull()
    expect(screen.getByText('Your music is in.')).not.toBeVisible()

    await act(() => reads.settle(false))
    expect(screen.queryByText('Your music is in.')).toBeNull()
    expect(screen.queryByText('Not personal yet')).toBeNull()
    expect(turns.sendMessage).toHaveBeenCalledOnce()
    expect(funnel(api).filter((type) => type === 'remake_tapped')).toHaveLength(1)
  })

  it('shows the door again, Remake enabled, when the post-turn read fails', async () => {
    let reads!: ReturnType<typeof heldReads>
    const { api } = catalogApi({ chosenService: 'spotify', musicReady: true }, (base) => {
      reads = heldReads(base)
      return { getSession: reads.getSession }
    })
    renderApp(api)
    await createTape(api)

    fireEvent.click(screen.getByRole('button', { name: 'Remake with my music' }))
    await screen.findByText(REPLY)
    expect(remakeButton()).toBeNull()
    await act(async () => reads.fail())
    expect(await screen.findByRole('button', { name: 'Remake with my music' })).toBeEnabled()
    expect(screen.getByText('Your music is in.')).toBeVisible()
  })

  it('reads onboarding again after the remake, so music that is not ready shows the first state', async () => {
    let ready = true
    const { api } = catalogApi(() => ({ chosenService: 'spotify', musicReady: ready }), (base) => ({
      sendMessage: async (...args) => {
        ready = false
        return base.sendMessage(...args)
      },
    }))
    renderApp(api)
    await createTape(api)
    const onboardingReads = api.calls.filter((call) => call.method === 'getOnboarding').length

    fireEvent.click(screen.getByRole('button', { name: 'Remake with my music' }))
    await screen.findByText(REPLY)
    await waitFor(() => expect(api.calls.filter((call) => call.method === 'getOnboarding').length).toBeGreaterThan(onboardingReads))
    expect(await screen.findByText(LINE)).toBeVisible()
    expect(within(door()).getByRole('button', { name: 'Add Spotify music' })).toBeInTheDocument()
    expect(remakeButton()).toBeNull()
    expect(within(mixPanel()).getByText('Not personal yet')).toBeInTheDocument()
  })

  it('lets only the latest post-turn read apply: a slow earlier one cannot bring the door back', async () => {
    let reads!: ReturnType<typeof heldReads>
    const { api } = catalogApi({ chosenService: 'spotify', musicReady: true }, (base) => {
      reads = heldReads(base)
      return { getSession: reads.getSession }
    })
    renderApp(api)
    await createTape(api)

    fireEvent.change(screen.getByLabelText('Message your DJ'), { target: { value: 'Brighter' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await screen.findByText(REPLY)
    await waitFor(() => expect(reads.pending).toHaveLength(1))

    fireEvent.click(await screen.findByRole('button', { name: 'Remake with my music' }))
    await waitFor(() => expect(reads.pending).toHaveLength(2))
    await act(() => reads.settle(false, 1))
    await waitFor(() => expect(screen.queryByText('Your music is in.')).toBeNull())

    // The first turn's read, slow and stale, says catalog.
    await act(() => reads.settle(true, 0))
    expect(screen.queryByText('Your music is in.')).toBeNull()
    expect(screen.queryByText(LINE)).toBeNull()
    expect(screen.queryByText('Not personal yet')).toBeNull()
  })

  it('records no remake_tapped when the tap is held for consent and nothing is sent', async () => {
    let first = true
    const { api } = catalogApi({ chosenService: 'spotify', musicReady: true }, (base) => ({
      sendMessage: async (...args) => {
        if (first) {
          first = false
          throw new ApiError(403, { error: 'ai_consent_required' })
        }
        return base.sendMessage(...args)
      },
    }))
    renderApp(api)
    await createTape(api)
    // The server asks for consent on a message: later sends are held for the dialog.
    fireEvent.change(screen.getByLabelText('Message your DJ'), { target: { value: 'Brighter' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    const dialog = await screen.findByRole('dialog', { name: AI_CONSENT_TITLE })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Not now' }))
    await waitFor(() => expect(screen.queryByRole('dialog', { name: AI_CONSENT_TITLE })).toBeNull())
    const sends = api.calls.filter((call) => call.method === 'sendMessage').length

    fireEvent.click(screen.getByRole('button', { name: 'Remake with my music' }))
    expect(await screen.findByRole('dialog', { name: AI_CONSENT_TITLE })).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'sendMessage')).toHaveLength(sends)
    expect(funnel(api)).not.toContain('remake_tapped')
  })

  it('from the phone shell’s banner: closes the panel and gives focus to the listener’s new line', async () => {
    stubNarrow(true)
    const { api } = catalogApi({ chosenService: 'spotify', musicReady: true })
    renderApp(api)
    await createTape(api)
    fireEvent.click(screen.getByRole('button', { name: 'Open your mix' }))

    const banner = within(mixPanel()).getByText('Not personal yet').closest('.banner') as HTMLElement
    const remake = within(banner).getByRole('button', { name: 'Remake with my music' })
    remake.focus()
    fireEvent.click(remake)
    expect(mixPanel()).not.toHaveClass('is-open')
    await waitFor(() => expect(api.calls.filter((call) => call.method === 'sendMessage')).toHaveLength(1))
    expect(api.calls.find((call) => call.method === 'sendMessage')!.args).toEqual(['created-session', REMAKE_TEXT, undefined, { remake: true }])
    expect(funnel(api)).toContain('remake_tapped')
    await waitFor(() => expect(document.activeElement).toHaveClass('conversation-turn--user'))
    expect(document.activeElement).toHaveTextContent(/^Remake this with my music$/)
  })
})
