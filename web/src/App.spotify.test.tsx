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
    const drop = within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    expect(drop).toHaveTextContent('Drop a Spotify ZIP here')
    expect(drop).toHaveTextContent('or choose a file · either package, in any order')
    expect(within(drop).getByLabelText('choose a file')).toHaveAttribute('type', 'file')
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
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })
    const sync = screen.getByRole('button', { name: 'Sync music library' })
    expect(sync).toBeEnabled()

    const drop = within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(drop).getByLabelText('choose a file'), { target: { files: [extendedZip()] } })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })
    expect(sync).toBeDisabled()
    expect(within(panel()).queryByLabelText('choose a file')).not.toBeInTheDocument()

    release()
    await within(panel()).findByText('Extended history imported')
    await waitFor(() => expect(sync).toBeEnabled())
    expect(await within(view).findByText('1 of 2 in', { selector: 'header .status-chip' })).toBeInTheDocument()
    expect(within(view).getByText(/^Extended history imported \w+\. Still waiting for the account data/)).toBeInTheDocument()
    expect(within(view).getByText('Spotify · extended history')).toBeInTheDocument()
    expect(screen.getByText(/^Spotify · imported /)).toBeInTheDocument()

    fireEvent.click(within(panel()).getByRole('button', { name: 'Make your first mix' }))
    expect(screen.getByRole('dialog', { name: /new tape/i })).toBeInTheDocument()
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
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(screen.getByRole('main', { name: 'Your music' })).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(view).getByLabelText('choose a file'), { target: { files: [extendedZip()] } })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })

    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    expect(screen.queryByRole('main', { name: 'Your music' })).not.toBeInTheDocument()
    const leaving = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(leaving)
    expect(leaving.defaultPrevented).toBe(true)
    expect(screen.getByRole('button', { name: 'Sync music library' })).toBeDisabled()

    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
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
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(view).getByLabelText('choose a file'), { target: { files: [extendedZip()] } })
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
    fireEvent.click(screen.getByRole('button', { name: /^Your music/ }))
    const view = await screen.findByRole('main', { name: 'Your music' })
    const panel = () => within(view).getByRole('region', { name: 'Import a Spotify ZIP' })
    fireEvent.change(within(panel()).getByLabelText('choose a file'), { target: { files: [extendedZip()] } })
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Upload' }))
    await within(panel()).findByText('Extended history imported')

    fireEvent.click(await within(view).findByRole('button', { name: 'Drop the other ZIP' }))
    await waitFor(() => expect(panel()).toHaveClass('drop'))
    expect(panel()).toHaveFocus()

    fireEvent.change(within(panel()).getByLabelText('choose a file'), { target: { files: [extendedZip()] } })
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
