// Share in the web app and shared rows in Mixes (spec 2026-11-13
// shared-mixes, Sender and Recipient on the web; plan task W3; board WM1).
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ShareNameRequiredError, type ApiSharedMix, type MixtapeApi } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { AuthUser } from './components/AuthGate'
import type { SharedMixRow } from './domain'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi, type FakeApi } from './test/fake-api'

vi.setConfig({ testTimeout: 15_000 })

const ada: AuthUser = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const tolu: AuthUser = { id: 'user-2', name: 'Tolu', email: 'tolu@example.com' }
const shareUrl = 'https://miixtape.netlify.app/m/fakebluehour0000000000'
const shareText = 'Listen to my mix “Blue hour, windows down” on Mixtape'
const token = '4fQ9xK2mZr7TbW1nLpY8sA'

const share: ApiSharedMix = {
  token,
  title: 'Late drive, windows down',
  caseColor: '#bc5734',
  sharerName: 'Ada',
  sharedAt: '2026-08-29T09:00:00.000Z',
  isOwner: false,
  tracks: [
    { title: 'Midnight City', artist: 'M83', album: null, durationMs: 243_000, artwork: null, appleId: '1', isrc: null },
    { title: 'Nightcall', artist: 'Kavinsky', album: null, durationMs: 258_000, artwork: null, appleId: '2', isrc: null },
  ],
}

// Between the first demo session (updated 2026-08-30) and the second (2026-08-29T00:00).
const row = (overrides: Partial<SharedMixRow> = {}): SharedMixRow => ({
  token, title: share.title, caseColor: share.caseColor, sharerName: 'Ada', savedAt: '2026-08-29T12:00:00.000Z',
  trackCount: 10, durationMs: 2_400_000, ...overrides,
})

function musicKit(): MusicKitClient {
  return {
    connect: vi.fn(async () => undefined),
    snapshot: vi.fn(async () => ({ storefront: 'ng', songs: [], playlists: [], playlistEntries: [], recentCatalogIds: [], excludedLibrarySongs: 0 })),
    play: vi.fn(async () => undefined),
    playAlbum: vi.fn(async () => undefined),
    pause: vi.fn(async () => undefined),
    createPlaylist: vi.fn(async () => undefined),
  }
}

function stubNavigator(name: 'share' | 'clipboard', value: unknown) {
  Object.defineProperty(window.navigator, name, { configurable: true, value })
}

/** A ClipboardItem that keeps what it was given, as Safari's takes a promise. */
class FakeClipboardItem {
  constructor(readonly items: Record<string, Promise<Blob> | Blob>) {}
}

/** A shareSession whose link changes on every call, as a new queue version's snapshot does. */
function versionedShares() {
  const base = createFakeApi()
  let made = 0
  return createFakeApi({
    shareSession: async (sessionId) => {
      await base.shareSession(sessionId)
      made += 1
      return { token: `tok${made}`, url: `https://miixtape.netlify.app/m/tok${made}` }
    },
  })
}

async function sendToDj(text: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), { target: { value: text } })
  fireEvent.click(screen.getByRole('button', { name: 'Send message' }))
  await screen.findByText('I kept the opening intact, then reshaped the middle around that feeling.')
}

function renderApp(options: { api?: FakeApi; user?: AuthUser; updateName?: AccountBridge['updateName'] } = {}) {
  const api = options.api ?? createFakeApi()
  const accountAuth: AccountBridge = {
    listAccounts: vi.fn(async () => []),
    linkProvider: vi.fn(async () => ({})),
    unlinkAccount: vi.fn(async () => ({})),
    updateName: options.updateName ?? vi.fn(async () => undefined),
    markNamePrompted: vi.fn(async () => undefined),
  }
  const props = { api, accountAuth, lastSignInProvider: 'apple' as const, musicKit: musicKit(), onSignOut: vi.fn(), refetchSession: vi.fn(async () => undefined) }
  const view = render(<App {...props} user={options.user ?? ada} />)
  return { api, accountAuth, view, props }
}

/** The row's count line, whose "From <name>" part is its own bold run. */
const subline = (pattern: RegExp) => (_: string, element: Element | null) => element?.tagName === 'SMALL' && pattern.test(element.textContent ?? '')

const callsOf = (api: FakeApi, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)

async function openBlueHour() {
  fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
  await screen.findByRole('heading', { name: 'Blue hour, windows down' })
  // The queue has loaded once the mix shows its song count from the read.
  await waitFor(() => expect(screen.getByRole('button', { name: 'Open your mix' })).toBeInTheDocument())
}

async function tapeOptions() {
  fireEvent.click(screen.getByRole('button', { name: 'Tape options' }))
  return screen.findByRole('group', { name: 'Tape options' })
}

async function openMixes() {
  fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
  return screen.findByRole('region', { name: 'Tape list' })
}

beforeEach(() => {
  localStorage.clear()
  sessionStorage.clear()
  window.history.replaceState(null, '', '/')
})
afterEach(() => {
  cleanup()
  stubNavigator('share', undefined)
  stubNavigator('clipboard', undefined)
  vi.unstubAllGlobals()
})

describe('Share in the tape options', () => {
  it('shares the link with the system share sheet, then offers Stop sharing', async () => {
    const shareSheet = vi.fn(async () => undefined)
    stubNavigator('share', shareSheet)
    const { api } = renderApp()
    await openBlueHour()
    const menu = await tapeOptions()
    expect(within(menu).queryByRole('button', { name: 'Stop sharing' })).toBeNull()
    fireEvent.click(within(menu).getByRole('button', { name: 'Share' }))

    await waitFor(() => expect(shareSheet).toHaveBeenCalledWith({ url: shareUrl, text: shareText }))
    expect(callsOf(api, 'shareSession')[0].args[0]).toBe('blue-hour')
    expect(screen.queryByText('Link copied')).toBeNull()
    expect(within(await tapeOptions()).getByRole('button', { name: 'Stop sharing' })).toBeInTheDocument()
  })

  it('copies the link and says so when the browser has no share sheet', async () => {
    const writeText = vi.fn(async () => undefined)
    stubNavigator('clipboard', { writeText })
    renderApp()
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(shareUrl))
    expect(await screen.findByText('Link copied')).toBeInTheDocument()
  })

  it('says nothing when the listener closes the share sheet', async () => {
    stubNavigator('share', vi.fn(async () => { throw new DOMException('cancelled', 'AbortError') }))
    const writeText = vi.fn(async () => undefined)
    stubNavigator('clipboard', { writeText })
    renderApp()
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(navigator.share).toHaveBeenCalled())
    await act(async () => { await Promise.resolve() })
    expect(writeText).not.toHaveBeenCalled()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByText('Link copied')).toBeNull()
  })

  it('reuses the link while the queue is unchanged, and asks for a new one once it changes', async () => {
    const shareSheet = vi.fn(async () => undefined)
    stubNavigator('share', shareSheet)
    const api = versionedShares()
    renderApp({ api })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(1))
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(2))
    expect(callsOf(api, 'shareSession')).toHaveLength(1)
    expect(shareSheet).toHaveBeenLastCalledWith({ url: 'https://miixtape.netlify.app/m/tok1', text: shareText })

    await sendToDj('More bass')
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(3))
    expect(callsOf(api, 'shareSession')).toHaveLength(2)
    expect(shareSheet).toHaveBeenLastCalledWith({ url: 'https://miixtape.netlify.app/m/tok2', text: shareText })
  })

  it('asks for a new link after a rename', async () => {
    const shareSheet = vi.fn(async () => undefined)
    stubNavigator('share', shareSheet)
    const api = versionedShares()
    renderApp({ api })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(1))

    fireEvent.click((await screen.findAllByRole('button', { name: 'Rename Blue hour, windows down' }))[0])
    fireEvent.change(screen.getByRole('textbox', { name: 'Mix name' }), { target: { value: 'Night swim' } })
    fireEvent.keyDown(screen.getByRole('textbox', { name: 'Mix name' }), { key: 'Enter' })
    await screen.findAllByRole('button', { name: 'Rename Night swim' })

    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(2))
    expect(callsOf(api, 'shareSession')).toHaveLength(2)
    expect(shareSheet).toHaveBeenLastCalledWith({ url: 'https://miixtape.netlify.app/m/tok2', text: 'Listen to my mix “Night swim” on Mixtape' })
  })

  it('starts the clipboard write inside the tap, before the link exists, where the browser takes a promised item', async () => {
    vi.stubGlobal('ClipboardItem', FakeClipboardItem)
    const write = vi.fn(async (_items: FakeClipboardItem[]) => undefined)
    const writeText = vi.fn(async () => undefined)
    stubNavigator('clipboard', { write, writeText })
    let release!: () => void
    const base = createFakeApi()
    const api = createFakeApi({
      shareSession: async (sessionId) => {
        await new Promise<void>((resolve) => { release = resolve })
        return base.shareSession(sessionId)
      },
    })
    renderApp({ api })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))

    // Still inside the tap: the link has not come back yet.
    expect(write).toHaveBeenCalledTimes(1)
    const item = write.mock.calls[0][0][0]
    await waitFor(() => expect(release).toBeTypeOf('function'))
    await act(async () => release())
    const blob = await item.items['text/plain']
    expect(await blob.text()).toBe(shareUrl)
    expect(await screen.findByText('Link copied')).toBeInTheDocument()
    expect(writeText).not.toHaveBeenCalled()
  })

  it('offers a Share button when the browser refuses the sheet after waiting for the link', async () => {
    const shareSheet = vi.fn()
      .mockRejectedValueOnce(new DOMException('no activation', 'NotAllowedError'))
      .mockResolvedValueOnce(undefined)
    stubNavigator('share', shareSheet)
    const writeText = vi.fn(async () => undefined)
    stubNavigator('clipboard', { writeText })
    renderApp()
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))

    expect(await screen.findByText('Link ready')).toBeInTheDocument()
    expect(screen.queryByText('Couldn’t share this mix. Try again.')).toBeNull()
    expect(writeText).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Share' }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledTimes(2))
    expect(shareSheet).toHaveBeenLastCalledWith({ url: shareUrl, text: shareText })
  })

  it('asks an anonymous listener for a first name, then opens the share sheet', async () => {
    const shareSheet = vi.fn(async () => undefined)
    stubNavigator('share', shareSheet)
    let refused = false
    const base = createFakeApi()
    const api = createFakeApi({
      shareSession: async (sessionId) => {
        if (!refused) { refused = true; throw new ShareNameRequiredError({ error: 'name_required' }) }
        return base.shareSession(sessionId)
      },
    })
    const updateName = vi.fn(async () => undefined)
    renderApp({ api, updateName, user: { id: 'anon-1', name: 'Listener', email: 'anon@example.com', isAnonymous: true } })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))

    expect(await screen.findByRole('heading', { name: 'What should we call you?' })).toBeInTheDocument()
    fireEvent.change(screen.getByRole('textbox', { name: 'Your name' }), { target: { value: 'Ada' } })
    fireEvent.click(screen.getByRole('button', { name: /Continue/ }))
    await waitFor(() => expect(shareSheet).toHaveBeenCalledWith({ url: shareUrl, text: shareText }))
    expect(updateName).toHaveBeenCalledWith('Ada')
  })

  it('asks for a first name with no Skip when the server needs one, then shares once it is saved', async () => {
    const shareSheet = vi.fn(async () => undefined)
    stubNavigator('share', shareSheet)
    let refused = false
    const base = createFakeApi()
    const api = createFakeApi({
      shareSession: async (sessionId) => {
        if (!refused) { refused = true; throw new ShareNameRequiredError({ error: 'name_required' }) }
        return base.shareSession(sessionId)
      },
    })
    const updateName = vi.fn(async () => undefined)
    renderApp({ api, updateName })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Share' }))

    expect(await screen.findByRole('heading', { name: 'What should we call you?' })).toBeInTheDocument()
    expect(screen.getByText('Whoever opens your link will see your first name.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Skip' })).toBeNull()
    expect(shareSheet).not.toHaveBeenCalled()

    fireEvent.change(screen.getByRole('textbox', { name: 'Your name' }), { target: { value: 'Ada' } })
    fireEvent.click(screen.getByRole('button', { name: /Continue/ }))

    await waitFor(() => expect(shareSheet).toHaveBeenCalledWith({ url: shareUrl, text: shareText }))
    expect(updateName).toHaveBeenCalledWith('Ada')
    expect(callsOf(api, 'shareSession')).toHaveLength(2)
    expect(screen.queryByRole('heading', { name: 'What should we call you?' })).toBeNull()
  })

  it('stops sharing after the confirm, and shows Stop sharing only while the mix is shared', async () => {
    const api = createFakeApi()
    await api.shareSession('blue-hour')
    renderApp({ api })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Stop sharing' }))

    const dialog = await screen.findByRole('alertdialog', { name: 'Stop sharing?' })
    expect(within(dialog).getByText('People with the link won’t be able to open it.')).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole('button', { name: 'Stop sharing' }))

    await waitFor(() => expect(callsOf(api, 'stopSharing')).toHaveLength(1))
    expect(callsOf(api, 'stopSharing')[0].args[0]).toBe('blue-hour')
    await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull())
    expect(within(await tapeOptions()).queryByRole('button', { name: 'Stop sharing' })).toBeNull()
  })

  it('keeps sharing when the confirm is cancelled', async () => {
    const api = createFakeApi()
    await api.shareSession('blue-hour')
    renderApp({ api })
    await openBlueHour()
    fireEvent.click(within(await tapeOptions()).getByRole('button', { name: 'Stop sharing' }))
    fireEvent.click(within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Cancel' }))
    expect(callsOf(api, 'stopSharing')).toHaveLength(0)
  })

  it('has no Share on a mix with no songs', async () => {
    renderApp()
    const list = await openMixes()
    fireEvent.click(within(list).getByRole('button', { name: 'Open Sunday kitchen radio' }))
    await screen.findByRole('heading', { name: 'Sunday kitchen radio' })
    await waitFor(() => expect(screen.queryByText('Opening this tape…')).toBeNull())
    const menu = await tapeOptions()
    expect(within(menu).getByRole('button', { name: 'Version history' })).toBeInTheDocument()
    expect(within(menu).queryByRole('button', { name: 'Share' })).toBeNull()
  })

  it('has no Share on an album', async () => {
    renderApp()
    const prompt = 'An album for the train home, nothing loud.'
    fireEvent.click(await screen.findByRole('radio', { name: 'Album' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: prompt } })
    fireEvent.click(screen.getByRole('button', { name: 'Find an album' }))
    await screen.findByRole('heading', { name: prompt })
    fireEvent.click(screen.getByRole('button', { name: 'Album options' }))
    const menu = await screen.findByRole('group', { name: 'Album options' })
    expect(within(menu).queryByRole('button', { name: 'Share' })).toBeNull()
  })
})

describe('Shared rows in Mixes', () => {
  it('merges shared rows among the mixes by time, labelled with who shared them', async () => {
    renderApp({ api: createFakeApi({ listSharedMixes: async () => [row()] }) })
    const list = await openMixes()
    await within(list).findByRole('button', { name: 'Open Late drive, windows down' })
    const titles = within(list).getAllByRole('button', { name: /^Open / }).map((button) => button.getAttribute('aria-label'))
    expect(titles.slice(0, 3)).toEqual(['Open Blue hour, windows down', 'Open Late drive, windows down', 'Open Sunday kitchen radio'])
    expect(within(list).getByText(subline(/^From Ada · 10 songs · /))).toBeInTheDocument()
  })

  it('says a friend when the sharer has no name', async () => {
    renderApp({ api: createFakeApi({ listSharedMixes: async () => [row({ sharerName: null })] }) })
    const list = await openMixes()
    expect(await within(list).findByText(subline(/^From a friend · 10 songs · /))).toBeInTheDocument()
  })

  it('offers only Remove in the row menu, which removes the save and the row', async () => {
    const api = createFakeApi({ listSharedMixes: async () => [row()] })
    renderApp({ api })
    const list = await openMixes()
    await within(list).findByRole('button', { name: 'Open Late drive, windows down' })
    fireEvent.click(within(list).getByRole('button', { name: 'Mix actions for Late drive, windows down' }))
    const menu = within(list).getByRole('group', { name: 'Mix actions' })
    expect(within(menu).getAllByRole('button').map((button) => button.textContent)).toEqual(['Remove'])
    fireEvent.click(within(menu).getByRole('button', { name: 'Remove' }))

    await waitFor(() => expect(callsOf(api, 'removeSharedMix')[0]?.args[0]).toBe(token))
    await waitFor(() => expect(within(list).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull())
  })

  it('opens a shared row read-only inside the app, with Back', async () => {
    const api = createFakeApi({ listSharedMixes: async () => [row()] }, { sharedMixes: { [token]: share } })
    renderApp({ api })
    const list = await openMixes()
    fireEvent.click(await within(list).findByRole('button', { name: 'Open Late drive, windows down' }))

    expect(await screen.findByRole('heading', { name: 'Late drive, windows down' })).toBeInTheDocument()
    expect(screen.getByText('Shared by Ada')).toBeInTheDocument()
    expect(screen.getByText('Midnight City')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Play' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Get the app' })).toBeNull()
    expect(screen.queryByRole('link', { name: 'Make your own mix' })).toBeNull()
    expect(screen.queryByRole('textbox', { name: 'Message your DJ' })).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Back to mixes' }))
    expect(await screen.findByRole('region', { name: 'Tape list' })).toBeInTheDocument()
    // It is already saved: the in-app view never saves it again.
    expect(callsOf(api, 'saveSharedMix')).toHaveLength(0)
  })

  it('plays an open shared mix through the app’s own Apple Music, recording nothing', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const api = createFakeApi({ listSharedMixes: async () => [row()], playbackPreferences: async () => ({ enabled: true, revision: 1 }) }, { sharedMixes: { [token]: share } })
    const { props } = renderApp({ api })
    const list = await openMixes()
    fireEvent.click(await within(list).findByRole('button', { name: 'Open Late drive, windows down' }))
    await screen.findByText('Shared by Ada')
    fireEvent.click(screen.getByRole('button', { name: 'Play' }))
    const connect = screen.queryByRole('button', { name: 'Connect Apple Music' })
    if (connect) fireEvent.click(connect)

    await waitFor(() => expect(props.musicKit.play).toHaveBeenCalledWith(['1', '2']))
    expect(props.musicKit.connect).toHaveBeenCalled()
    expect(callsOf(api, 'saveSharedMix')).toHaveLength(0)
    expect(callsOf(api, 'sendPlaybackEvidence')).toHaveLength(0)
  })

  it('shows a name with a dot in it whole', async () => {
    renderApp({ api: createFakeApi({ listSharedMixes: async () => [row({ sharerName: 'Ada · B' })] }) })
    const list = await openMixes()
    await within(list).findByText(subline(/^From Ada · B · 10 songs · /))
    expect(within(list).getByText('From Ada · B', { selector: 'b' })).toBeInTheDocument()
  })

  it('never brings back a removed row from a read that was already in flight', async () => {
    let calls = 0
    let releaseSecond!: (rows: SharedMixRow[]) => void
    const api = createFakeApi({
      listSharedMixes: () => {
        calls += 1
        if (calls === 1) return Promise.resolve([row()])
        return new Promise<SharedMixRow[]>((resolve) => { releaseSecond = resolve })
      },
    })
    renderApp({ api })
    let list = await openMixes()
    await within(list).findByRole('button', { name: 'Open Late drive, windows down' })
    fireEvent.click(screen.getByRole('button', { name: 'Home' }))
    list = await openMixes()
    await waitFor(() => expect(releaseSecond).toBeTypeOf('function'))

    fireEvent.click(within(list).getByRole('button', { name: 'Mix actions for Late drive, windows down' }))
    fireEvent.click(within(within(list).getByRole('group', { name: 'Mix actions' })).getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(within(list).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull())

    await act(async () => releaseSecond([row()]))
    expect(within(list).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull()
  })

  it('removes from the open shared mix’s menu and goes back to Mixes without the row', async () => {
    const api = createFakeApi({ listSharedMixes: async () => [row()] }, { sharedMixes: { [token]: share } })
    renderApp({ api })
    const list = await openMixes()
    fireEvent.click(await within(list).findByRole('button', { name: 'Open Late drive, windows down' }))
    await screen.findByText('Shared by Ada')
    fireEvent.click(screen.getByRole('button', { name: 'Shared mix options' }))
    const menu = screen.getByRole('group', { name: 'Shared mix options' })
    expect(within(menu).getAllByRole('button').map((button) => button.textContent)).toEqual(['Remove'])
    fireEvent.click(within(menu).getByRole('button', { name: 'Remove' }))

    await waitFor(() => expect(callsOf(api, 'removeSharedMix')[0]?.args[0]).toBe(token))
    const back = await screen.findByRole('region', { name: 'Tape list' })
    expect(within(back).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull()
  })

  it('says a share that has gone is not shared anymore, and offers Remove', async () => {
    const api = createFakeApi({ listSharedMixes: async () => [row()] }, { sharedMixes: { [token]: 'revoked' } })
    renderApp({ api })
    const list = await openMixes()
    fireEvent.click(await within(list).findByRole('button', { name: 'Open Late drive, windows down' }))

    expect(await screen.findByRole('heading', { name: 'This mix isn’t shared anymore.' })).toBeInTheDocument()
    // Remove is right there; the menu would only repeat it.
    expect(screen.queryByRole('button', { name: 'Shared mix options' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(callsOf(api, 'removeSharedMix')[0]?.args[0]).toBe(token))
    const back = await screen.findByRole('region', { name: 'Tape list' })
    expect(within(back).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull()
  })

  it('reads the list again for a different account, never showing the last one’s rows', async () => {
    const listSharedMixes = vi.fn(async () => [row()])
    const api = createFakeApi({ listSharedMixes })
    const { view, props } = renderApp({ api })
    const list = await openMixes()
    await within(list).findByRole('button', { name: 'Open Late drive, windows down' })

    const before = listSharedMixes.mock.calls.length
    listSharedMixes.mockImplementation(async () => [])
    view.rerender(<App {...props} user={tolu} />)
    // The new account's workspace never starts with the last one's rows, and reads its own.
    expect(screen.queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull()
    const next = await openMixes()
    await waitFor(() => expect(listSharedMixes.mock.calls.length).toBeGreaterThan(before))
    expect(within(next).queryByRole('button', { name: 'Open Late drive, windows down' })).toBeNull()
  })
})
