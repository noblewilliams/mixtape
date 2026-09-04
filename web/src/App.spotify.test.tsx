import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, type ApiMusicSource, type MixtapeApi, type OnboardingResponse } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { writeServiceChoice } from './lib/service-preference'
import { createFakeApi } from './test/fake-api'

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const DAY_MS = 24 * 60 * 60 * 1000

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
    <App api={api} accountAuth={accountAuth} lastSignInProvider="google" musicKit={musicKit} user={user} onSignOut={onSignOut} />,
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
    expect(screen.getByText('Apple Music')).toBeInTheDocument()
  })

  it('never shows for a Spotify listener', async () => {
    const api = apiWithOnboarding({ chosenService: 'spotify' })
    renderApp({ api })

    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Spotify · not requested yet')).toBeInTheDocument()
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

    expect(await screen.findByRole('heading', { name: 'Get your listening data' })).toBeInTheDocument()
    expect(gate()).not.toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'chose_spotify', surface: 'web' },
    ])
    expect(await screen.findByText('Spotify · not requested yet')).toBeInTheDocument()
  })

  it('sends the Apple choice into the existing connect flow', async () => {
    const { musicKit } = renderApp()

    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Apple Music/ }))

    expect(gate()).not.toBeInTheDocument()
    expect(musicKit.connect).toHaveBeenCalledTimes(1)
  })
})

describe('service gate persistence', () => {
  afterEach(cleanup)
  afterEach(() => vi.restoreAllMocks())

  it('remembers an Apple choice on this device so the gate does not come back', async () => {
    renderApp()
    fireEvent.click(within(await screen.findByRole('dialog', { name: 'Which do you use?' })).getByRole('button', { name: /^Apple Music/ }))
    expect(localStorage.getItem('mixtape:service-choice:user-1')).toBe('apple')
    expect(screen.getByText('Apple Music')).toBeInTheDocument()
    cleanup()

    const api = createFakeApi()
    renderApp({ api })
    await settled(api)
    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Apple Music')).toBeInTheDocument()
  })

  it('honours a remembered Spotify choice before the server has it', async () => {
    writeServiceChoice('user-1', 'spotify')
    const api = createFakeApi()
    renderApp({ api })
    await settled(api)

    expect(gate()).not.toBeInTheDocument()
    expect(screen.getByText('Spotify · not requested yet')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    expect(await screen.findByRole('heading', { name: 'Get your listening data' })).toBeInTheDocument()
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
    expect(musicKit.connect).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Apple Music')).toBeInTheDocument()
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

describe('Spotify request page', () => {
  afterEach(cleanup)

  async function openRequestPage(api = apiWithOnboarding({ chosenService: 'spotify' })) {
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    await screen.findByRole('heading', { name: 'Get your listening data' })
    return api
  }

  it('shows the eight steps word for word with the privacy link in a new tab', async () => {
    await openRequestPage()

    const view = screen.getByRole('main', { name: 'Your music' })
    expect(within(view).getByText('Your music · Spotify')).toBeInTheDocument()
    expect(within(view).getByText('Spotify prepares it and emails you. Mixtape reads the file on this device and keeps only your plays and playlists.')).toBeInTheDocument()
    expect(within(view).getByRole('status')).toHaveTextContent('Not requested')

    const steps = within(view).getAllByRole('listitem')
    expect(steps).toHaveLength(8)
    expect(steps[0]).toHaveTextContent('Open spotify.com/account/privacy and log in with the account that has your listening history. A laptop is easier than a phone for this part.')
    expect(steps[1]).toHaveTextContent('Scroll to Download your data.')
    expect(steps[2]).toHaveTextContent('Select Account data and Extended streaming history. Leave Technical log information unselected.')
    expect(steps[3]).toHaveTextContent('Press Request data.')
    expect(steps[4]).toHaveTextContent('Check your email. Spotify sends a confirmation message first. Open it and press Confirm. Nothing is prepared until you do, and this is the step most people miss.')
    expect(steps[4].querySelector('b')).toHaveTextContent('confirmation')
    expect(steps[5]).toHaveTextContent('Wait. The two packages arrive as separate emails, each with a Download button, usually within days; the extended history can take up to 30. Each link expires after about two weeks, so download it when you see it.')
    expect(steps[6]).toHaveTextContent('Save the ZIPs as they are. Don’t unzip them.')
    expect(steps[7]).toHaveTextContent('Come back to Mixtape and give it each ZIP as it arrives. You don’t have to wait for both.')

    const link = within(view).getByRole('link', { name: 'spotify.com/account/privacy' })
    expect(link).toHaveAttribute('href', 'https://www.spotify.com/account/privacy/')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
    expect(within(view).getByText('Marks today so Mixtape can show how long you’ve waited. No email from Mixtape; Spotify’s two emails are the signal.')).toBeInTheDocument()
    expect(within(view).queryByText('Drop a Spotify ZIP here')).not.toBeInTheDocument()
  })

  it('marks the request and turns into the waiting card', async () => {
    let marked: string | null = null
    const api = createFakeApi({
      getOnboarding: async () => ({ ...blank, chosenService: 'spotify', markedRequestedAt: marked }),
      postFunnelEvent: async (event) => {
        if (event.type === 'marked_requested') marked = new Date().toISOString()
        return { ok: true }
      },
    })
    await openRequestPage(api)

    fireEvent.click(screen.getByRole('button', { name: 'I’ve requested it' }))

    expect(await screen.findByRole('heading', { name: 'Today' })).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'marked_requested', surface: 'web' },
    ])
    const view = screen.getByRole('main', { name: 'Your music' })
    expect(within(view).getByText('Waiting for Spotify')).toBeInTheDocument()
    expect(within(view).getByText(/^Requested \w+\. Confirmation email clicked\? If not, nothing is being prepared\.$/)).toBeInTheDocument()
    expect(within(view).getAllByText('Waiting')).toHaveLength(2)
    expect(within(view).getByRole('button', { name: /^Tell the DJ about your taste/ })).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: /^Paste songs from Spotify/ })).toHaveClass('mini--desktop')
    expect(within(view).getByRole('button', { name: /^Try a demo tape/ })).toBeDisabled()
    expect(within(view).getByText('Demo tape coming soon.')).toBeInTheDocument()
    expect(within(view).queryByRole('alert')).not.toBeInTheDocument()
    const drop = view.querySelector('[data-todo="import-page"]') as HTMLElement
    expect(drop).toHaveTextContent('Drop a Spotify ZIP here')
    expect(drop).toHaveTextContent('or choose a file · either package, in any order')
    expect(within(view).queryByRole('button', { name: 'Make a mix' })).not.toBeInTheDocument()
    expect(screen.getByText('Spotify · waiting for your data')).toBeInTheDocument()
    expect(document.querySelector('.app-shell')).toHaveClass('app-shell--home')
  })

  it('says so when marking the request fails, and stays on the steps', async () => {
    const api = createFakeApi({
      getOnboarding: async () => ({ ...blank, chosenService: 'spotify' }),
      postFunnelEvent: async () => {
        throw new ApiError(500, { error: 'internal' })
      },
    })
    await openRequestPage(api)
    const reads = api.calls.filter((call) => call.method === 'getOnboarding').length

    fireEvent.click(screen.getByRole('button', { name: 'I’ve requested it' }))

    const view = screen.getByRole('main', { name: 'Your music' })
    expect(await within(view).findByRole('alert')).toHaveTextContent('Couldn’t save that. Check your connection and try again.')
    expect(within(view).getByRole('button', { name: 'I’ve requested it' })).toBeEnabled()
    expect(within(view).queryByText('Waiting for Spotify')).not.toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'getOnboarding').length).toBe(reads)
  })

  it('offers the interview and the demo before the checkpoint, with a way to the steps', async () => {
    await openRequestPage()
    const view = screen.getByRole('main', { name: 'Your music' })

    const quiet = within(view).getByRole('region', { name: 'Not requested' })
    const steps = within(view).getByRole('region', { name: 'How to get your listening data' })
    expect(quiet.compareDocumentPosition(steps) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(within(quiet).getByText('The DJ can’t make a personal mix until your data arrives. Ask Spotify now; it takes two minutes.')).toBeInTheDocument()
    expect(within(quiet).getByText('Five short questions. Required before any mix.')).toBeInTheDocument()
    expect(within(quiet).getByText('Not personal yet')).toBeInTheDocument()
    expect(within(quiet).getByText('Once the interview is done, the DJ can offer a mix from what it already knows, clearly labeled.')).toBeInTheDocument()
    expect(within(quiet).getByRole('button', { name: /^Try a demo tape/ })).toBeDisabled()
    expect(within(quiet).getByText('Demo tape coming soon.')).toBeInTheDocument()
    expect(within(quiet).queryByRole('button', { name: /^Paste songs/ })).not.toBeInTheDocument()
    expect(within(steps).getAllByRole('listitem')).toHaveLength(8)

    fireEvent.click(within(quiet).getByRole('button', { name: 'Show me the steps' }))
    expect(steps).toHaveFocus()

    fireEvent.click(within(quiet).getByRole('button', { name: /^Tell the DJ about your taste/ }))
    expect(screen.getByRole('dialog', { name: 'Artists you would never skip' })).toBeInTheDocument()
  })

  it('reflects the interview and a package that arrived', async () => {
    const api = apiWithOnboarding({
      chosenService: 'spotify',
      markedRequestedAt: new Date(Date.now() - 2 * DAY_MS).toISOString(),
      interviewCompletedAt: '2026-09-03T10:00:00.000Z',
      importCompletedAt: '2026-09-04T09:30:00.000Z',
      sources: [accountPackage],
      interview: { artists: 6, notes: 4 },
    })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))

    const view = await screen.findByRole('main', { name: 'Your music' })
    expect(within(view).getByRole('heading', { name: 'Your Spotify data' })).toBeInTheDocument()
    expect(within(view).getByRole('heading', { name: '2 days' })).toBeInTheDocument()
    expect(within(view).getAllByText('1 of 2 in')).toHaveLength(2)
    expect(within(view).getByText(/^Account data imported \w+\. Still waiting for the extended history; it can take up to 30 days\.$/)).toBeInTheDocument()
    expect(within(view).getByText('Interview done')).toBeInTheDocument()
    expect(within(view).getByText('4 notes, 6 artists. The DJ can already make a mix from your likes and playlists.')).toBeInTheDocument()
    expect(within(view).queryByRole('button', { name: /^Tell the DJ about your taste/ })).not.toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Make a mix' })).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Drop the other ZIP' })).toBeInTheDocument()
    expect(within(view).getByText('Spotify · account data')).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Import again' })).toBeInTheDocument()
    expect(screen.getByText('Spotify · imported 4 Sep')).toBeInTheDocument()

    fireEvent.click(within(view).getByRole('button', { name: 'Make a mix' }))
    expect(screen.getByRole('dialog', { name: 'Make a new tape' })).toBeInTheDocument()
  })

  it('stops nudging once both packages are in', async () => {
    const api = apiWithOnboarding({
      chosenService: 'spotify',
      markedRequestedAt: '2026-08-20T08:00:00.000Z',
      interviewCompletedAt: '2026-09-03T10:00:00.000Z',
      importCompletedAt: '2026-09-04T09:30:00.000Z',
      sources: [bothPackages],
    })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))

    const view = await screen.findByRole('main', { name: 'Your music' })
    expect(within(view).getAllByText('Both in')).toHaveLength(2)
    expect(within(view).getByRole('heading', { name: 'Data in' })).toBeInTheDocument()
    expect(within(view).queryByText(/Still waiting/)).not.toBeInTheDocument()
    expect(within(view).getByText(/^Both packages imported .+\. Drop a newer ZIP any time to bring it up to date\.$/)).toBeInTheDocument()
    expect(within(view).getByText('Spotify · both packages')).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Drop a newer ZIP' })).toBeInTheDocument()
    expect(within(view).getByText('Interview done')).toBeInTheDocument()
    expect(within(view).getByText('The DJ can already make a mix from your likes and playlists.')).toBeInTheDocument()
  })

  it('opens the paste box from its tile', async () => {
    const api = apiWithOnboarding({ chosenService: 'spotify', markedRequestedAt: new Date().toISOString() })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))

    const view = await screen.findByRole('main', { name: 'Your music' })
    fireEvent.click(within(view).getByRole('button', { name: /^Paste songs from Spotify/ }))

    expect(within(view).getByRole('heading', { name: 'Seed the DJ with songs you love' })).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: /^Paste songs from Spotify/ })).toHaveAttribute('aria-expanded', 'true')
  })

  it('runs the interview from the tile and refreshes the card with the saved counts', async () => {
    const api = createFakeApi()
    await api.postFunnelEvent({ type: 'chose_spotify', surface: 'web' })
    await api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })

    fireEvent.click(within(view).getByRole('button', { name: /^Tell the DJ about your taste/ }))
    const dialog = screen.getByRole('dialog', { name: 'Artists you would never skip' })
    fireEvent.change(within(dialog).getByLabelText('Artist'), { target: { value: 'Ivory Kestrel' } })
    fireEvent.keyDown(within(dialog).getByLabelText('Artist'), { key: 'Enter' })
    for (let step = 0; step < 4; step += 1) fireEvent.click(within(dialog).getByRole('button', { name: 'Next' }))
    fireEvent.click(within(dialog).getByRole('button', { name: 'Finish' }))

    expect(await screen.findByText('Saved 1 note, 1 artist')).toBeInTheDocument()
    expect(screen.queryByRole('dialog', { name: 'Artists you would never skip' })).not.toBeInTheDocument()
    expect(await within(view).findByText('Interview done')).toBeInTheDocument()
    expect(within(view).getByText('1 note, 1 artist. The DJ can already make a mix from what it knows, clearly labeled.')).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'getOnboarding').length).toBeGreaterThanOrEqual(2)
  })

  it('removes a source after confirmation and refreshes the view', async () => {
    let sources: ApiMusicSource[] = [accountPackage]
    const deleteListeningSource = vi.fn(async () => {
      sources = []
      return { deletedDays: 0, deletedTracks: 0, unlibraried: 0 }
    })
    const api = createFakeApi({
      getOnboarding: async () => ({ ...blank, chosenService: 'spotify', markedRequestedAt: '2026-09-01T08:00:00.000Z', sources }),
      deleteListeningSource,
    })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })

    fireEvent.click(within(view).getByRole('button', { name: 'Remove Spotify · account data' }))
    expect(within(view).getByRole('alertdialog', { name: 'Remove your Spotify data?' })).toBeInTheDocument()
    fireEvent.click(within(view).getByRole('button', { name: 'Confirm remove' }))

    await waitFor(() => expect(deleteListeningSource).toHaveBeenCalledWith('spotify_export'))
    await waitFor(() => expect(within(view).queryByText('Spotify · account data')).not.toBeInTheDocument())
    expect(await screen.findByText('Your Spotify data is gone from Mixtape.')).toBeInTheDocument()
    expect(screen.getByText('Spotify · waiting for your data')).toBeInTheDocument()
  })

  it('announces a failed removal with fixed copy, never the server message', async () => {
    const api = createFakeApi({
      getOnboarding: async () => ({ ...blank, chosenService: 'spotify', markedRequestedAt: '2026-09-01T08:00:00.000Z', sources: [accountPackage] }),
      deleteListeningSource: async () => {
        throw new ApiError(500, { message: 'db exploded' })
      },
    })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })

    fireEvent.click(within(view).getByRole('button', { name: 'Remove Spotify · account data' }))
    fireEvent.click(within(view).getByRole('button', { name: 'Confirm remove' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t remove that source. Try again.')
    expect(screen.queryByText('db exploded')).not.toBeInTheDocument()
    expect(within(view).getByText('Spotify · account data')).toBeInTheDocument()
  })

  it('gives every control in the view an accessible name', async () => {
    const api = apiWithOnboarding({
      chosenService: 'spotify',
      markedRequestedAt: '2026-09-01T08:00:00.000Z',
      sources: [accountPackage],
    })
    renderApp({ api })
    await settled(api)
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })
    fireEvent.click(within(view).getByRole('button', { name: /^Paste songs from Spotify/ }))

    for (const control of within(view).getAllByRole('button')) expect(control).toHaveAccessibleName()
    for (const control of screen.getAllByRole('button')) expect(control).toHaveAccessibleName()
  })
})
