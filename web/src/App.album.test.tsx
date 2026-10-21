import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, type CreateSessionResponse, type MixtapeApi, type OnboardingResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import { demoAlbumPick, demoAlbumRefinedPick, demoAlbumRefinePrompt, demoAlbumRefineReply, demoAlbumReply, demoAlbumRunnersUp } from './data/demo'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}

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

function renderApp(options: { api?: ReturnType<typeof createFakeApi>; musicKit?: MusicKitClient } = {}) {
  const api = options.api ?? createFakeApi()
  const musicKit = options.musicKit ?? createFakeMusicKit()
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} />)
  return { api, musicKit }
}

async function createAlbum(prompt = 'An album for the train home, nothing loud.') {
  fireEvent.click(await screen.findByRole('radio', { name: 'Album' }))
  fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: prompt } })
  fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
  await screen.findByRole('heading', { name: prompt })
}

const panel = () => screen.getByRole('complementary', { name: 'The album' })
const callsOf = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)

function stubNarrow(narrow: boolean) {
  vi.stubGlobal('matchMedia', vi.fn((query: string) => ({
    matches: narrow && query === '(max-width: 1020px)',
    media: query,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  })))
}

describe('Album sessions on the web', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  it('opens a new album in the conversation with the album panel instead of the queue', async () => {
    renderApp()
    await createAlbum()
    expect(await screen.findByRole('status')).toHaveTextContent('Your album pick is ready.')
    expect(within(panel()).getByText('Low Tide Hours')).toBeInTheDocument()
    expect(within(panel()).getByText('pick 1')).toBeInTheDocument()
    expect(screen.queryByRole('complementary', { name: 'Your mix' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Open your mix' })).toBeNull()
    expect(screen.queryByRole('button', { name: /Energy journey/ })).toBeNull()
    expect(screen.getByText(/^Pick 1 · /)).toBeInTheDocument()
  })

  it('swaps in a runner-up with Pick this and keeps the old pick as passed over', async () => {
    const { api } = renderApp()
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Show' }))
    const row = within(panel()).getByText('Nightshift Radio').closest('li')!
    fireEvent.click(within(row).getByRole('button', { name: 'Pick this' }))
    await waitFor(() => expect(within(panel()).getByText('pick 2')).toBeInTheDocument())
    expect(callsOf(api, 'choosePick')[0].args).toEqual(['created-album-session', { albumId: demoAlbumRunnersUp[0].id }, 1])
    expect(within(panel()).getByText('Nightshift Radio').closest('.album-card')).not.toBeNull()
    const passed = screen.getByText('Passed over').closest('.album-passed') as HTMLElement
    expect(passed).toHaveTextContent('Low Tide Hours')

    fireEvent.click(within(passed).getByRole('button', { name: 'Go back' }))
    await waitFor(() => expect(within(panel()).getByText('pick 3')).toBeInTheDocument())
    expect(callsOf(api, 'choosePick')[1].args).toEqual(['created-album-session', { version: 1 }, 2])
    expect(within(panel()).getByText('Low Tide Hours').closest('.album-card')).not.toBeNull()
  })

  it('shows the latest pick when the pick moved on elsewhere', async () => {
    const latest = { ...demoAlbumRunnersUp[1], version: 4 }
    const api = createFakeApi({
      choosePick: async () => { throw new ApiError(409, { error: 'stale', version: 4 }) },
      getSession: async (id) => ({
        session: { id, title: 'An album for the train home, nothing loud.', status: 'active', queueVersion: 4, notPersonal: false, updatedAt: new Date().toISOString(), kind: 'album' },
        messages: [],
        pick: latest, runnersUp: [], passed: [], version: 4,
      }),
    })
    renderApp({ api })
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Show' }))
    fireEvent.click(within(panel()).getAllByRole('button', { name: 'Pick this' })[0])
    expect(await screen.findByText('This album pick moved on. Showing the latest.')).toBeInTheDocument()
    expect(callsOf(api, 'getSession').map((call) => call.args[0])).toContain('created-album-session')
    expect(within(panel()).getByText('pick 4')).toBeInTheDocument()
    expect(within(panel()).getByText('Slow Rooms').closest('.album-card')).not.toBeNull()
    expect(screen.getByText(/^Pick 4 · /)).toBeInTheDocument()
  })

  it('saves to Listen later with the session, toasts with Undo, and Undo removes it', async () => {
    const { api } = renderApp()
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Listen later' }))
    expect(within(panel()).getByRole('button', { name: 'Saved for later' })).toHaveAttribute('aria-pressed', 'true')
    await waitFor(() => expect(callsOf(api, 'saveForLater')).toHaveLength(1))
    expect(callsOf(api, 'saveForLater')[0].args.slice(0, 2)).toEqual([demoAlbumPick.id, 'created-album-session'])
    const toast = await screen.findByText('On your Listen later shelf.')
    fireEvent.click(within(toast.closest('.toast') as HTMLElement).getByRole('button', { name: 'Undo' }))
    await waitFor(() => expect(callsOf(api, 'unsaveForLater')).toHaveLength(1))
    expect(callsOf(api, 'unsaveForLater')[0].args[0]).toBe(demoAlbumPick.id)
    expect(within(panel()).getByRole('button', { name: 'Listen later' })).toHaveAttribute('aria-pressed', 'false')
  })

  it('unsaves quietly from the filled state', async () => {
    const { api } = renderApp()
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Listen later' }))
    await screen.findByText('On your Listen later shelf.')
    // Let the save's toast run out, so any toast after the unsave would be the unsave's own.
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 4100)) })
    expect(screen.queryByRole('status')).toBeNull()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Saved for later' }))
    await waitFor(() => expect(callsOf(api, 'unsaveForLater')).toHaveLength(1))
    expect(callsOf(api, 'unsaveForLater')[0].args[0]).toBe(demoAlbumPick.id)
    expect(within(panel()).getByRole('button', { name: 'Listen later' })).toHaveAttribute('aria-pressed', 'false')
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 50)) })
    expect(screen.queryByRole('status')).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
  }, 10_000)

  it('rolls back a failed save', async () => {
    const api = createFakeApi({ saveForLater: async () => { throw new Error('offline') } })
    renderApp({ api })
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Listen later' }))
    expect(await screen.findByText('Couldn’t save this album. Try again.')).toBeInTheDocument()
    expect(within(panel()).getByRole('button', { name: 'Listen later' })).toHaveAttribute('aria-pressed', 'false')
  })

  it('plays the album by its Apple id, connecting Apple Music first', async () => {
    const { musicKit } = renderApp()
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Play now' }))
    await waitFor(() => expect(musicKit.playAlbum).toHaveBeenCalledWith(demoAlbumPick.appleId))
    expect(musicKit.connect).toHaveBeenCalled()
    expect(vi.mocked(musicKit.connect).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(musicKit.playAlbum).mock.invocationCallOrder[0])
  })

  it('says so when Apple Music will not connect, or the album is not in Apple Music', async () => {
    const musicKit = createFakeMusicKit({ connect: vi.fn(async () => { throw new Error('denied') }) })
    renderApp({ musicKit })
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Play now' }))
    expect(await screen.findByText('Apple Music couldn’t play this album. Try again in a moment.')).toBeInTheDocument()
    expect(musicKit.playAlbum).not.toHaveBeenCalled()
  })

  it('says so when the pick has no Apple id', async () => {
    const base = createFakeApi()
    const api = createFakeApi({ createSession: async (...args) => {
      const created = await base.createSession(...args)
      return { ...created, pick: created.pick && { ...created.pick, appleId: null } }
    } })
    const { musicKit } = renderApp({ api })
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Play now' }))
    expect(await screen.findByText('Apple Music couldn’t play this album. Try again in a moment.')).toBeInTheDocument()
    expect(musicKit.playAlbum).not.toHaveBeenCalled()
  })

  it('says so when Apple Music cannot play the album', async () => {
    renderApp({ musicKit: createFakeMusicKit({ playAlbum: vi.fn(async () => { throw new Error('nope') }) }) })
    await createAlbum()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Play now' }))
    expect(await screen.findByText('Apple Music couldn’t play this album. Try again in a moment.')).toBeInTheDocument()
  })

  it('offers the Spotify search to a Spotify-only listener', async () => {
    const blank: OnboardingResponse = { userId: 'user-1', sources: [], hasLibrary: false, chosenService: 'spotify', markedRequestedAt: null, interviewCompletedAt: null, importCompletedAt: null, interview: null }
    const api = createFakeApi({ getOnboarding: async () => blank })
    renderApp({ api })
    await waitFor(() => expect(callsOf(api, 'getOnboarding')).toHaveLength(1))
    await createAlbum()
    expect(within(panel()).getByRole('link', { name: 'Open in Spotify' })).toBeInTheDocument()
    expect(within(panel()).queryByRole('button', { name: 'Play now' })).toBeNull()
  })

  it('refines with a message: new pick, passed row above the turn, and a lagging read changes nothing', async () => {
    const base = createFakeApi()
    let stale: Awaited<ReturnType<MixtapeApi['getSession']>> | null = null
    const api = createFakeApi({
      createSession: async (...args) => {
        const created = await base.createSession(...args)
        stale = await base.getSession(created.session.id)
        return created
      },
      sendMessage: base.sendMessage,
      // The post-turn read lands from a replica still at pick 1.
      getSession: async () => stale!,
    })
    renderApp({ api })
    await createAlbum()
    fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: demoAlbumRefinePrompt } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await screen.findByText(demoAlbumRefineReply)
    await waitFor(() => expect(callsOf(api, 'getSession')).toHaveLength(1))
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) })
    expect(within(panel()).getByText(demoAlbumRefinedPick.title).closest('.album-card')).not.toBeNull()
    expect(within(panel()).getByText('pick 2')).toBeInTheDocument()
    expect(screen.getByText(/^Pick 2 · /)).toBeInTheDocument()
    const passed = screen.getByText('Passed over').closest('.album-passed') as HTMLElement
    expect(passed).toHaveTextContent(demoAlbumPick.title)
    const turn = screen.getByText(demoAlbumRefinePrompt)
    expect(passed.compareDocumentPosition(turn) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('applies the pick state a failed album turn carries', async () => {
    const sendMessage = vi.fn(async () => {
      throw new ApiError(502, {
        error: 'catalog_unavailable', message: 'Could not reach Apple Music to check the album.',
        pick: { ...demoAlbumRefinedPick, version: 2 }, runnersUp: [], passed: [{ ...demoAlbumPick, version: 1 }], version: 2,
      })
    })
    const api = createFakeApi({ sendMessage })
    renderApp({ api })
    await createAlbum()
    fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'Older.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    expect(await screen.findByText('Could not reach Apple Music to check the album.')).toBeInTheDocument()
    await waitFor(() => expect(within(panel()).getByText('pick 2')).toBeInTheDocument())
    expect(within(panel()).getByText(demoAlbumRefinedPick.title).closest('.album-card')).not.toBeNull()
    expect(callsOf(api, 'getSession')).toHaveLength(0)
  })

  it('re-reads the session after a failed album turn with no pick state', async () => {
    const api = createFakeApi({ sendMessage: async () => { throw new ApiError(502, { error: 'model_failed', message: 'The DJ could not answer.' }) } })
    renderApp({ api })
    await createAlbum()
    fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'Older.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    expect(await screen.findByText('The DJ could not answer.')).toBeInTheDocument()
    await waitFor(() => expect(callsOf(api, 'getSession').map((call) => call.args[0])).toEqual(['created-album-session']))
  })

  it('folds the panel into the conversation under the reply below the shell width', async () => {
    stubNarrow(true)
    renderApp()
    await createAlbum()
    const conversation = screen.getByRole('main')
    const inline = within(conversation).getByRole('complementary', { name: 'The album' })
    expect(inline).toHaveClass('album-panel--inline')
    const reply = within(conversation).getByText(demoAlbumReply)
    expect(reply.compareDocumentPosition(inline) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getAllByRole('complementary', { name: 'The album' })).toHaveLength(1)
  })

  it('opens the Add music flow from the Add my music pill instead of sending it', async () => {
    const comfort = async (prompt: string): Promise<CreateSessionResponse> => ({
      session: { id: 'comfort-album', title: prompt, status: 'active', queueVersion: 0, notPersonal: false, updatedAt: new Date().toISOString(), kind: 'album' },
      messages: [{ id: 'd', role: 'dj', content: 'I do not see whole albums in your music yet.', createdAt: new Date().toISOString() }],
      pick: null, runnersUp: [], passed: [], version: 0,
      suggestions: ['Add my music', 'Something new is fine'],
    })
    const api = createFakeApi({ createSession: comfort })
    renderApp({ api })
    await createAlbum('One of my own albums')
    fireEvent.click(screen.getByRole('button', { name: 'Add my music' }))
    expect(await screen.findByRole('heading', { level: 1, name: 'Step 1 of 3, Which do you use?' })).toBeInTheDocument()
    expect(callsOf(api, 'sendMessage')).toHaveLength(0)
  })

  it('draws honest-failure pills under the reply and sends one as the next message', async () => {
    const failed = async (prompt: string): Promise<CreateSessionResponse> => ({
      session: { id: 'honest-album', title: prompt, status: 'active', queueVersion: 0, notPersonal: false, updatedAt: new Date().toISOString(), kind: 'album' },
      messages: [
        { id: 'u', role: 'user', content: prompt, createdAt: new Date().toISOString() },
        { id: 'd', role: 'dj', content: 'I will not point you at a record I cannot play.', createdAt: new Date().toISOString() },
      ],
      pick: null, runnersUp: [], passed: [], version: 0,
      suggestions: ['Any year', 'Something stranger I do know'],
    })
    const sendMessage = vi.fn(async () => ({
      djMessage: { id: 'd2', role: 'dj' as const, content: 'Any year, then.', queueVersion: 1, createdAt: new Date().toISOString() },
      pick: { ...demoAlbumPick, version: 1 }, runnersUp: [], passed: [], version: 1,
    }))
    renderApp({ api: createFakeApi({ createSession: failed, sendMessage }) })
    await createAlbum('loud and strange')
    expect(within(panel()).getByText('No album yet')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Any year' }))
    await waitFor(() => expect(sendMessage).toHaveBeenCalledOnce())
    expect(sendMessage.mock.calls[0].slice(0, 2)).toEqual(['honest-album', 'Any year'])
    await waitFor(() => expect(within(panel()).getByText('Low Tide Hours')).toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Something stranger I do know' })).toBeNull()
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) })
  })
})
