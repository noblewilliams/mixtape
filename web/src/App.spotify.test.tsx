import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, type ApiMusicSource, type MixtapeApi, type OnboardingResponse, type QueueOpsResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { writeServiceChoice } from './lib/service-preference'
import { createDirectParser } from './import/direct-parser'
import { createFakeApi } from './test/fake-api'
import { readFixtureArchiveBytes } from './test/listening-export-fixtures'

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }

const blank: OnboardingResponse = {
  userId: 'user-1',
  sources: [],
  hasLibrary: false,
  chosenService: null,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
  interview: null,
}

const accountPackage: ApiMusicSource = {
  source: 'spotify_export',
  connectedAt: '2026-09-04T09:00:00.000Z',
  lastImportedAt: '2026-09-04T09:30:00.000Z',
  ledgerFrom: null,
  ledgerTo: null,
  packages: ['spotify_account'],
}

const bothPackages: ApiMusicSource = {
  ...accountPackage,
  ledgerFrom: '2018-03-02',
  ledgerTo: '2026-08-29',
  packages: ['spotify_account', 'spotify_extended'],
}

function createFakeMusicKit(overrides: Partial<MusicKitClient> = {}): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({
      storefront: 'ng',
      songs: [],
      playlists: [],
      playlistEntries: [],
      recentCatalogIds: [],
      excludedLibrarySongs: 0,
    })),
    play: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
    ...overrides,
  }
}

const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}

function renderApp(
  options: { api?: ReturnType<typeof createFakeApi>; musicKit?: MusicKitClient; onSignOut?: () => void } = {},
) {
  const api = options.api ?? createFakeApi()
  const musicKit = options.musicKit ?? createFakeMusicKit()
  const onSignOut = options.onSignOut ?? vi.fn()
  render(
    <App
      api={api}
      accountAuth={accountAuth}
      lastSignInProvider="google"
      musicKit={musicKit}
      user={user}
      onSignOut={onSignOut}
      importParser={createDirectParser()}
    />,
  )
  return { api, musicKit, onSignOut }
}

beforeEach(() => localStorage.clear())

function apiWithOnboarding(state: Partial<OnboardingResponse>, overrides: Partial<MixtapeApi> = {}) {
  return createFakeApi({ getOnboarding: async () => ({ ...blank, ...state }), ...overrides })
}

async function settled(api: ReturnType<typeof createFakeApi>) {
  await screen.findByRole('heading', { name: 'Blue hour, windows down' })
  await waitFor(() => expect(api.calls.some((call) => call.method === 'getOnboarding')).toBe(true))
}

const gate = () => screen.queryByRole('dialog', { name: 'Which do you use?' })

async function openSpotify() {
  fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
  if (screen.queryByRole('region', { name: 'Spotify import' })) return
  fireEvent.click(await screen.findByRole('button', { name: 'Sources' }))
  fireEvent.click(await screen.findByRole('button', { name: /^(Get started|Continue Spotify import)$/ }))
  await screen.findByRole('region', { name: 'Spotify import' })
}

describe('service gate', () => {
  afterEach(cleanup)

  it('asks a blank listener which service they use, with the approved copy', async () => {
    renderApp()

    const dialog = await screen.findByRole('dialog', { name: 'Which do you use?' })
    expect(within(dialog).getByText('Before your first tape')).toBeInTheDocument()
    expect(within(dialog).getByText('Mixtape builds mixes from what you actually listen to. Tell it where that lives.')).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: /^Apple Music/ })).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: /^Apple Music/ })).toHaveFocus()
    expect(within(dialog).getByRole('button', { name: /^Spotify/ })).toBeInTheDocument()
    expect(within(dialog).getByText('You can add the other later from Your music.')).toBeInTheDocument()
  })

  it('never shows for an Apple listener', async () => {
    const api = apiWithOnboarding({ chosenService: 'apple', hasLibrary: true })
    renderApp({ api })

    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(within(screen.getByRole('complementary', { name: 'Mixtape navigation' })).getByText('Apple Music')).toBeInTheDocument()
  })

  it('never shows for a Spotify listener', async () => {
    const api = apiWithOnboarding({ chosenService: 'spotify' })
    renderApp({ api })

    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Spotify · ready to import')).toBeInTheDocument()
  })

  it('never shows while onboarding is still loading', async () => {
    const api = createFakeApi({ getOnboarding: () => new Promise<OnboardingResponse>(() => undefined) })
    renderApp({ api })

    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Not connected yet')).toBeInTheDocument()
  })

  it('records the Spotify choice and opens the request page', async () => {
    const { api } = renderApp()

    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Spotify/ }))

    expect(await screen.findByRole('heading', { name: 'Bring your Spotify music' })).toBeInTheDocument()
    expect(gate()).not.toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'chose_spotify', surface: 'web' },
    ])
    expect(await screen.findByText('Spotify · ready to import')).toBeInTheDocument()
  })

  it('sends the Apple choice into the existing connect flow', async () => {
    const { musicKit } = renderApp()

    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Apple Music/ }))

    expect(gate()).not.toBeInTheDocument()
    expect(musicKit.connect).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(musicKit.connect).toHaveBeenCalledTimes(1))
  })
})

describe('service gate persistence', () => {
  afterEach(cleanup)
  afterEach(() => vi.restoreAllMocks())

  it('remembers an Apple choice on this device so the gate does not come back', async () => {
    renderApp()
    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Apple Music/ }))
    expect(localStorage.getItem('mixtape:service-choice:user-1')).toBe('apple')
    expect(within(screen.getByRole('complementary', { name: 'Mixtape navigation' })).getByText('Apple Music')).toBeInTheDocument()
    cleanup()

    const api = createFakeApi()
    renderApp({ api })
    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(within(screen.getByRole('complementary', { name: 'Mixtape navigation' })).getByText('Apple Music')).toBeInTheDocument()
  })

  it('honours a remembered Spotify choice before the server has it', async () => {
    writeServiceChoice('user-1', 'spotify')
    const api = createFakeApi()
    renderApp({ api })
    await settled(api)

    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Spotify · ready to import')).toBeInTheDocument()
    await openSpotify()
    expect(await screen.findByRole('heading', { name: 'Bring your Spotify music' })).toBeInTheDocument()
  })

  it('forgets the remembered choice on sign-out', async () => {
    writeServiceChoice('user-1', 'apple')
    const api = createFakeApi()
    const { onSignOut } = renderApp({ api, onSignOut: vi.fn() })
    await settled(api)

    fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))

    expect(onSignOut).toHaveBeenCalledTimes(1)
    expect(localStorage.getItem('mixtape:service-choice:user-1')).toBeNull()
  })

  it('still gates and still takes the choice when storage throws', async () => {
    const blocked = () => {
      throw new Error('blocked')
    }
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(blocked)
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(blocked)
    const { musicKit } = renderApp()

    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Apple Music/ }))

    expect(gate()).not.toBeInTheDocument()
    expect(musicKit.connect).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(musicKit.connect).toHaveBeenCalledTimes(1))
    expect(within(screen.getByRole('complementary', { name: 'Mixtape navigation' })).getByText('Apple Music')).toBeInTheDocument()
  })

  it('signs out when the onboarding read says the session has ended', async () => {
    const api = createFakeApi({
      getOnboarding: async () => {
        throw new ApiError(401, { error: 'unauthorized' })
      },
    })
    const { onSignOut } = renderApp({ api, onSignOut: vi.fn() })

    await waitFor(() => expect(onSignOut).toHaveBeenCalled())
    expect(gate()).not.toBeInTheDocument()
  })
})

describe('Spotify quick import and optional history',()=>{
 afterEach(cleanup)
 async function open(api=apiWithOnboarding({chosenService:'spotify'})) {renderApp({api});await settled(api);await openSpotify();return api}
 it('leads with Exportify and a file picker while keeping official requests optional',async()=>{
  const api=await open()
  const link=screen.getByRole('link',{name:'Open Exportify ↗'})
  expect(link).toHaveAttribute('href','https://exportify.app/')
  expect(link).toHaveAttribute('target','_blank')
  expect(screen.getByLabelText('choose files')).toHaveAttribute('multiple')
  expect(screen.queryByRole('link',{name:'spotify.com/account/privacy'})).not.toBeInTheDocument()
  expect(api.calls.filter(c=>c.method==='postFunnelEvent')).toHaveLength(0)
  fireEvent.click(screen.getByRole('button',{name:'Go deeper →'}))
  expect(screen.getByRole('link',{name:'spotify.com/account/privacy'})).toHaveAttribute('target','_blank')
  expect(screen.getByText('Save the ZIPs as they are. Don’t unzip them.')).toBeInTheDocument()
 })
 it('marks an optional history request while keeping quick import available',async()=>{
  let marked:string|null=null
  const api=apiWithOnboarding({chosenService:'spotify'},{getOnboarding:async()=>({...blank,chosenService:'spotify',markedRequestedAt:marked}),postFunnelEvent:async()=>{marked=new Date().toISOString();return {ok:true}}})
  await open(api)
  fireEvent.click(screen.getByRole('button',{name:'Go deeper →'}))
  fireEvent.click(screen.getByRole('button',{name:'I’ve requested it'}))
  expect(await screen.findByText(/You can import saved music above while Spotify prepares/)).toBeInTheDocument()
  expect(screen.getByLabelText('choose files')).toBeInTheDocument()
 })
 it('keeps the request retryable when saving its checkpoint fails',async()=>{
  await open(apiWithOnboarding({chosenService:'spotify'},{postFunnelEvent:async()=>{throw new ApiError(500,{error:'internal'})}}))
  fireEvent.click(screen.getByRole('button',{name:'Go deeper →'}))
  fireEvent.click(screen.getByRole('button',{name:'I’ve requested it'}))
  expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t save that.')
  expect(screen.getByRole('button',{name:'I’ve requested it'})).toBeEnabled()
 })
 it('offers the required taste interview before any import',async()=>{
  await open()
  fireEvent.click(screen.getByRole('button',{name:'Tell the DJ about your taste'}))
  expect(screen.getByRole('dialog',{name:'Artists you would never skip'})).toBeInTheDocument()
 })
 it('shows imported music as a manual refresh with history optional',async()=>{
  await open(apiWithOnboarding({chosenService:'spotify',sources:[bothPackages],interviewCompletedAt:'2026-09-03T10:00:00.000Z'}))
  expect(screen.getByRole('heading',{name:'Your Spotify music'})).toBeInTheDocument()
  expect(screen.getByText('Manual refresh')).toBeInTheDocument()
  expect(screen.getByRole('button',{name:'Import again'})).toBeInTheDocument()
  expect(screen.queryByText(/Still waiting/)).not.toBeInTheDocument()
 })
 it('removes a source only after explicit confirmation',async()=>{
  let sources:ApiMusicSource[]=[accountPackage]
  const remove=vi.fn(async()=>{sources=[];return {deletedDays:0,deletedTracks:0,unlibraried:0}})
  await open(apiWithOnboarding({chosenService:'spotify'},{getOnboarding:async()=>({...blank,chosenService:'spotify',sources}),deleteListeningSource:remove}))
  fireEvent.click(screen.getByRole('button',{name:'Remove Spotify · account data'}))
  expect(remove).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button',{name:'Confirm remove'}))
  await waitFor(()=>expect(remove).toHaveBeenCalledWith('spotify_export'))
 })
 it('keeps controls named for assistive technology',async()=>{
  await open()
  fireEvent.click(screen.getByRole('button',{name:'Go deeper →'}))
  for(const button of screen.getAllByRole('button'))expect(button).toHaveAccessibleName()
 })
})

describe('Spotify import page', () => {
  afterEach(cleanup)

  function extendedZip() {
    return new File([readFixtureArchiveBytes('extended-basic')], 'my_spotify_data_extended.zip', { type: 'application/zip' })
  }

  it('gates the Apple sync while an upload is in flight, then refreshes the chip, sources, and nudge', async () => {
    let release!: () => void
    const held = new Promise<void>((resolve) => {
      release = resolve
    })
    const api = createFakeApi({
      putListeningTracks: async (_importId, tracks) => {
        await held
        return { accepted: tracks.length }
      },
    })
    await api.postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
    await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
    renderApp({ api })
    await settled(api)
    await openSpotify()
    const view = await screen.findByRole('main', { name: 'Your music' })
    const sync = screen.getByRole('button', { name: 'Sync music library' })
    expect(sync).toBeEnabled()

    const drop = within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(drop).getByLabelText('choose files'), { target: { files: [extendedZip()] } })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })
    expect(sync).toBeDisabled()
    expect(within(panel()).queryByLabelText('choose files')).not.toBeInTheDocument()

    release()
    await within(panel()).findByText('Extended history imported')
    await waitFor(() => expect(sync).toBeEnabled())
    expect(await within(view).findByText('Imported')).toBeInTheDocument()
    expect(within(view).getByText('Spotify · extended history')).toBeInTheDocument()
    expect(screen.getByText(/^Spotify · imported /)).toBeInTheDocument()

    fireEvent.click(within(panel()).getByRole('button', { name: 'Tell the DJ about your taste' }))
    expect(screen.getByRole('dialog', { name: 'Artists you would never skip' })).toBeInTheDocument()
  })

  it('keeps an upload running across Home and back, and warns before unload while it runs', async () => {
    let release!: () => void
    const held = new Promise<void>((resolve) => {
      release = resolve
    })
    const api = createFakeApi({
      putListeningTracks: async (_importId, tracks) => {
        await held
        return { accepted: tracks.length }
      },
    })
    await api.postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
    await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
    renderApp({ api })
    await settled(api)
    await openSpotify()
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(screen.getByRole('main', { name: 'Your music' })).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(view).getByLabelText('choose files'), { target: { files: [extendedZip()] } })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })

    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    expect(screen.queryByRole('main', { name: 'Your music' })).not.toBeInTheDocument()
    const leaving = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(leaving)
    expect(leaving.defaultPrevented).toBe(true)
    expect(screen.getByRole('button', { name: 'Sync music library' })).toBeDisabled()

    await openSpotify()
    await screen.findByRole('main', { name: 'Your music' })
    expect(within(panel()).getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
    expect(within(panel()).getByRole('status')).toHaveTextContent('Uploading')

    release()
    await within(panel()).findByText('Extended history imported')
    expect(api.calls.filter((call) => call.method === 'beginListeningImport')).toHaveLength(1)
    expect(api.calls.some((call) => call.method === 'completeListeningImport')).toBe(true)
    const staying = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(staying)
    expect(staying.defaultPrevented).toBe(false)
  })

  it('aborts and forgets the run on sign-out', async () => {
    let release!: () => void
    const held = new Promise<void>((resolve) => {
      release = resolve
    })
    let uploadSignal: AbortSignal | undefined
    const api = createFakeApi({
      putListeningTracks: async (_importId, tracks, signal) => {
        uploadSignal = signal
        await held
        return { accepted: tracks.length }
      },
    })
    await api.postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
    await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
    const { onSignOut } = renderApp({ api, onSignOut: vi.fn() })
    await settled(api)
    await openSpotify()
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(view).getByLabelText('choose files'), { target: { files: [extendedZip()] } })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })
    await waitFor(() => expect(uploadSignal).toBeDefined())

    fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
    expect(onSignOut).toHaveBeenCalledTimes(1)
    expect(uploadSignal!.aborted).toBe(true)
    await waitFor(() => expect(panel()).toHaveClass('drop'))
    release()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(api.calls.some((call) => call.method === 'completeListeningImport')).toBe(false)
    expect(panel()).toHaveClass('drop')
  })

  it('brings the drop zone back from Import again and Drop the other ZIP', async () => {
    const api = createFakeApi()
    await api.postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
    await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
    renderApp({ api })
    await settled(api)
    await openSpotify()
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(panel()).getByLabelText('choose files'), { target: { files: [extendedZip()] } })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByText('Extended history imported')

    fireEvent.click(await within(view).findByRole('button', { name: 'Import again' }))
    await waitFor(() => expect(panel()).toHaveClass('drop'))
    expect(panel()).toHaveFocus()

    fireEvent.change(within(panel()).getByLabelText('choose files'), { target: { files: [extendedZip()] } })
    await within(panel()).findByRole('button', { name: 'Upload' })
    fireEvent.click(within(view).getByRole('button', { name: 'Import again' }))
    await waitFor(() => expect(panel()).toHaveClass('drop'))
  })
})

describe('Spotify mix outputs', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    Object.defineProperty(window.navigator, 'clipboard', { configurable: true, value: undefined })
  })

  function funnelTypes(api: ReturnType<typeof createFakeApi>, type: string) {
    return api.calls.filter((call) => call.method === 'postFunnelEvent' && (call.args[0] as { type: string }).type === type)
  }

  async function createTape(prompt: string) {
    fireEvent.click(await screen.findByRole('button', { name: 'Make a new tape' }))
    fireEvent.change(screen.getByLabelText('What should this tape feel like?'), { target: { value: prompt } })
    fireEvent.click(screen.getByRole('button', { name: 'Start tape' }))
    await screen.findByRole('heading', { name: prompt })
  }

  async function sendMessage(text: string) {
    fireEvent.change(await screen.findByLabelText('Message your DJ'), { target: { value: text } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
    await screen.findByText(/reshaped the middle around that feeling/)
  }

  it('refetches the session after a message turn so a corpus-mode answer shows the banner', async () => {
    const base = createFakeApi()
    let corpusMode = false
    const api = apiWithOnboarding(
      { chosenService: 'spotify' },
      {
        getSession: async (sessionId) => {
          const detail = await base.getSession(sessionId)
          return { ...detail, session: { ...detail.session, notPersonal: corpusMode } }
        },
        sendMessage: async (sessionId, text) => {
          corpusMode = true
          return base.sendMessage(sessionId, text)
        },
      },
    )
    renderApp({ api })
    await settled(api)
    expect(screen.queryByText('Not personal yet')).not.toBeInTheDocument()
    const reads = api.calls.filter((call) => call.method === 'getSession').length

    await sendMessage('Make the middle brighter.')

    await waitFor(() => expect(api.calls.filter((call) => call.method === 'getSession').length).toBe(reads + 1))
    expect(await screen.findByText('Not personal yet')).toBeInTheDocument()
  })

  /** An API whose `getSession` changes behaviour once a message turn has happened. */
  function apiWithPostTurnRefetch(
    afterTurn: (detail: Awaited<ReturnType<MixtapeApi['getSession']>>) => ReturnType<MixtapeApi['getSession']>,
    overrides: Partial<MixtapeApi> = {},
  ) {
    const base = createFakeApi()
    let turned = false
    return apiWithOnboarding(
      { chosenService: 'spotify' },
      {
        getSession: async (sessionId) => {
          const detail = await base.getSession(sessionId)
          return turned ? afterTurn(detail) : detail
        },
        sendMessage: async (sessionId, text) => {
          turned = true
          return base.sendMessage(sessionId, text)
        },
        ...overrides,
      },
    )
  }

  const djTurns = () => document.querySelectorAll('.conversation-turn--dj').length
  const trackTitles = () => [...document.querySelectorAll('.track-row .track-copy strong')].map((element) => element.textContent)

  it('keeps the turn’s tape version through the post-turn refetch and sends it with the next queue op', async () => {
    const applyQueueOps = vi.fn(() => new Promise<QueueOpsResponse>(() => undefined))
    const api = apiWithPostTurnRefetch(
      async (detail) => ({ ...detail, session: { ...detail.session, queueVersion: 1, notPersonal: true } }),
      { applyQueueOps },
    )
    renderApp({ api })
    await settled(api)

    await sendMessage('Make the middle brighter.')
    expect(await screen.findByText('Not personal yet')).toBeInTheDocument()

    expect(screen.getByText(/Tape version 4/)).toBeInTheDocument()
    fireEvent.keyDown(screen.getByRole('button', { name: 'Move Sweetest Taboo, track 1' }), { key: 'ArrowDown' })
    await waitFor(() => expect(applyQueueOps).toHaveBeenCalledWith('blue-hour', [{ op: 'move', from: 0, to: 1 }], 4))
  })

  it('leaves the queue alone when the post-turn refetch returns a different one', async () => {
    const api = apiWithPostTurnRefetch(async (detail) => ({
      ...detail,
      session: { ...detail.session, notPersonal: true },
      queue: detail.queue.slice(0, 1),
    }))
    renderApp({ api })
    await settled(api)
    const before = trackTitles()
    expect(before.length).toBeGreaterThan(1)

    await sendMessage('Make the middle brighter.')
    expect(await screen.findByText('Not personal yet')).toBeInTheDocument()

    expect(trackTitles()).toEqual(before)
  })

  it('adds no DJ error bubble when the post-turn refetch fails', async () => {
    const api = apiWithPostTurnRefetch(async () => {
      throw new Error('offline')
    })
    renderApp({ api })
    await settled(api)
    const reads = api.calls.filter((call) => call.method === 'getSession').length
    const turns = djTurns()

    await sendMessage('Make the middle brighter.')
    await waitFor(() => expect(api.calls.filter((call) => call.method === 'getSession').length).toBe(reads + 1))
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0))
    })

    expect(djTurns()).toBe(turns + 1)
    expect(screen.queryByText('Something interrupted the connection. Please try again.')).not.toBeInTheDocument()
  })

  it('signs out when the post-turn refetch says the session has ended', async () => {
    const api = apiWithPostTurnRefetch(async () => {
      throw new ApiError(401, { error: 'unauthorized' })
    })
    const { onSignOut } = renderApp({ api, onSignOut: vi.fn() })
    await settled(api)

    await sendMessage('Make the middle brighter.')

    await waitFor(() => expect(onSignOut).toHaveBeenCalled())
  })

  it('posts first_personal_mix once, and only after an import has completed', async () => {
    const api = apiWithOnboarding({ chosenService: 'spotify' })
    renderApp({ api })
    await settled(api)

    await createTape('Dinner after the rain')
    expect(funnelTypes(api, 'first_personal_mix')).toHaveLength(0)
    cleanup()

    const imported = apiWithOnboarding({
      chosenService: 'spotify',
      sources: [accountPackage],
      importCompletedAt: '2026-09-04T09:30:00.000Z',
    })
    renderApp({ api: imported })
    await settled(imported)

    await createTape('Dinner after the rain')
    await waitFor(() => expect(funnelTypes(imported, 'first_personal_mix')).toHaveLength(1))
    expect(funnelTypes(imported, 'first_personal_mix')[0].args[0]).toEqual({ type: 'first_personal_mix', surface: 'web' })

    await sendMessage('Make the middle brighter.')
    await createTape('Slow start')
    await waitFor(() => expect(imported.calls.filter((call) => call.method === 'createSession')).toHaveLength(2))
    expect(funnelTypes(imported, 'first_personal_mix')).toHaveLength(1)
  })

  it('does not post first_personal_mix for a corpus-mode tape', async () => {
    const base = createFakeApi()
    const api = apiWithOnboarding(
      { chosenService: 'spotify', sources: [accountPackage], importCompletedAt: '2026-09-04T09:30:00.000Z' },
      {
        createSession: async (prompt) => {
          const created = await base.createSession(prompt)
          return { ...created, session: { ...created.session, notPersonal: true } }
        },
      },
    )
    renderApp({ api })
    await settled(api)

    await createTape('Something for a rainy desk')

    expect(await screen.findByText('Not personal yet')).toBeInTheDocument()
    expect(funnelTypes(api, 'first_personal_mix')).toHaveLength(0)
  })

  it('never counts an Apple library sync as a completed import for first_personal_mix', async () => {
    const appleLibrary: ApiMusicSource = {
      source: 'apple_live',
      connectedAt: '2026-09-04T09:00:00.000Z',
      lastImportedAt: '2026-09-04T09:30:00.000Z',
      ledgerFrom: null,
      ledgerTo: null,
      packages: [],
    }
    writeServiceChoice(user.id, 'apple')
    const api = apiWithOnboarding({ sources: [appleLibrary], hasLibrary: true, importCompletedAt: null })
    renderApp({ api })
    await settled(api)

    await createTape('Dinner after the rain')

    expect(api.calls.filter((call) => call.method === 'createSession')).toHaveLength(1)
    expect(funnelTypes(api, 'first_personal_mix')).toHaveLength(0)
  })

  it('counts a listening export source with an import date as completed for first_personal_mix', async () => {
    const api = apiWithOnboarding({ chosenService: 'spotify', sources: [accountPackage], importCompletedAt: null })
    renderApp({ api })
    await settled(api)

    await createTape('Dinner after the rain')

    await waitFor(() => expect(funnelTypes(api, 'first_personal_mix')).toHaveLength(1))
  })

  it('posts first_output once across Open in Spotify, Copy for Spotify, and the transfer handoff', async () => {
    const base = createFakeApi()
    const api = apiWithOnboarding(
      { chosenService: 'spotify' },
      {
        getSession: async (sessionId) => {
          const detail = await base.getSession(sessionId)
          return {
            ...detail,
            queue: detail.queue.map((track) => ({ ...track, appleId: null, spotifyId: `sp-${track.trackId}` })),
          }
        },
      },
    )
    const writeText = vi.fn(async (_text: string) => undefined)
    Object.defineProperty(window.navigator, 'clipboard', { configurable: true, value: { writeText } })
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    renderApp({ api })
    await settled(api)

    const link = await screen.findByRole('link', { name: 'Open in Spotify: Sweetest Taboo' })
    link.addEventListener('click', (event) => event.preventDefault())
    fireEvent.click(link)
    await waitFor(() => expect(funnelTypes(api, 'first_output')).toHaveLength(1))

    fireEvent.click(screen.getByRole('button', { name: 'Copy for Spotify' }))
    await waitFor(() => expect(writeText).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('button', { name: 'Send to a transfer tool' }))
    await waitFor(() => expect(open).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(writeText).toHaveBeenCalledTimes(2))

    expect(funnelTypes(api, 'first_output')).toHaveLength(1)
    expect(screen.queryByRole('button', { name: 'Connect Apple Music' })).not.toBeInTheDocument()
  })
})
