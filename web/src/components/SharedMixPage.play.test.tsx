// Play on the public shared mix page (spec 2026-11-13 shared-mixes,
// "Recipient on the web" → Play; board W4/W5). The MusicKit client and the
// playback controller are the real ones over a fake MusicKit global, so the
// order of session, token and authorize is the order production runs.
//
// Safari opens Apple's sign-in window only while the tap's user activation
// lasts, so authorize() must run inside the click, before any await
// (decisions 2026-11-13, "a first Apple Music play takes a second tap").
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ApiSharedMix } from '../api/client'
import { createMusicKitClient, type MusicKitGlobal, type MusicKitInstance } from '../musickit/client'
import { PlaybackController } from '../playback/controller'
import { createFakeApi } from '../test/fake-api'
import { SharedMixPage, type SharedMixSession } from './SharedMixPage'

const token = '4fQ9xK2mZr7TbW1nLpY8sA'
const share: ApiSharedMix = {
  token,
  title: 'Late drive, windows down',
  caseColor: '#bc5734',
  sharerName: 'Ada',
  sharedAt: '2026-11-13T09:00:00.000Z',
  isOwner: false,
  tracks: [
    { title: 'Midnight City', artist: 'M83', album: null, durationMs: 243_000, artwork: null, appleId: '1', isrc: null },
    { title: 'Nightcall', artist: 'Kavinsky', album: null, durationMs: 258_000, artwork: null, appleId: null, isrc: null },
    { title: 'Electric Feel', artist: 'MGMT', album: null, durationMs: 229_000, artwork: null, appleId: '3', isrc: null },
  ],
}
const noSession: SharedMixSession = { isPending: false, userId: null }
const listener: SharedMixSession = { isPending: false, userId: 'listener-1' }

function stubClipboard(writeText: ((text: string) => Promise<void>) | null) {
  Object.defineProperty(window.navigator, 'clipboard', { configurable: true, value: writeText ? { writeText } : undefined })
}

function setup(options: {
  share?: ApiSharedMix
  session?: SharedMixSession
  sessionFails?: boolean
  authorized?: boolean
  prepareFails?: boolean
} = {}) {
  const log: string[] = []
  const api = createFakeApi({}, { sharedMixes: { [token]: options.share ?? share } })
  const instance: MusicKitInstance = {
    isAuthorized: false,
    authorize: vi.fn(async () => {
      log.push('authorize')
      return options.authorized === false ? undefined : 'music-user-token'
    }),
    setQueue: vi.fn(async () => undefined),
    play: vi.fn(async () => { log.push('play') }),
    pause: vi.fn(),
  }
  const global: MusicKitGlobal = { configure: vi.fn(async () => instance), getInstance: vi.fn(() => instance) }
  const musicKit = createMusicKitClient({
    getDeveloperToken: async () => {
      log.push('token')
      return api.getMusicKitToken()
    },
    loadMusicKit: async () => {
      if (options.prepareFails) throw new Error('script blocked')
      return global
    },
    nowSeconds: () => 1_788_000_000,
  })
  const prepare = vi.spyOn(musicKit, 'prepare')
  const preload = vi.fn()
  const ensureSession = vi.fn(async () => {
    log.push('ensureSession')
    if (options.sessionFails) throw new Error('Too many requests')
  })
  const player = { ensureSession, preload, musicKit, playback: new PlaybackController(api, musicKit, 'shared-test') }
  const page = (session: SharedMixSession) => (
    <SharedMixPage token={token} api={api} session={session} player={player} appUrl="/app/" downloadUrl="https://apps.test/mixtape" />
  )
  const { rerender } = render(page(options.session ?? noSession))
  const saves = () => api.calls.filter((call) => call.method === 'saveSharedMix').length
  const reads = () => api.calls.filter((call) => call.method === 'getSharedMix').length
  return { api, log, instance, ensureSession, prepare, preload, saves, reads, rerender: (session: SharedMixSession) => rerender(page(session)) }
}

/** Waits until MusicKit's load-time prepare has settled and the page knows it. */
async function prepared(prepare: { mock: { results: { value: unknown }[] } }) {
  await waitFor(() => expect(prepare.mock.results.length).toBeGreaterThan(0))
  await act(async () => { await prepare.mock.results[0].value })
}

async function pressPlay() {
  fireEvent.click(await screen.findByRole('button', { name: 'Play' }))
}

describe('Play on the shared mix page', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    stubClipboard(null)
    localStorage.clear()
  })

  it('asks where they listen when this browser has no answer, and Cancel leaves everything as it was', async () => {
    const { ensureSession } = setup()
    await pressPlay()

    const dialog = screen.getByRole('dialog', { name: 'Where do you listen?' })
    expect(within(dialog).getByText('We’ll remember it on this browser.')).toBeInTheDocument()
    const choices = within(dialog).getAllByRole('button').map((button) => button.textContent)
    expect(choices).toEqual(['Apple Music', 'Spotify', 'Cancel'])

    fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(localStorage.getItem('mixtape.plays-on')).toBeNull()
    expect(ensureSession).not.toHaveBeenCalled()
  })

  it('visiting never makes a session, and prepares MusicKit only for a browser that already has one', async () => {
    const visitor = setup()
    await screen.findByRole('button', { name: 'Play' })
    expect(visitor.ensureSession).not.toHaveBeenCalled()
    expect(visitor.prepare).not.toHaveBeenCalled()
    // The script needs no session, so it starts loading on any visit.
    expect(visitor.preload).toHaveBeenCalledOnce()
    cleanup()

    const returning = setup({ session: listener })
    await screen.findByRole('button', { name: 'Play' })
    await waitFor(() => expect(returning.prepare).toHaveBeenCalledOnce())
    expect(returning.ensureSession).not.toHaveBeenCalled()
  })

  it('never loads MusicKit for a browser that plays on Spotify', async () => {
    localStorage.setItem('mixtape.plays-on', 'spotify')
    const { prepare, preload } = setup({ session: listener })
    await screen.findByRole('button', { name: 'Play' })
    expect(prepare).not.toHaveBeenCalled()
    expect(preload).not.toHaveBeenCalled()
  })

  it('a returning listener with MusicKit prepared plays in one tap, authorizing inside the click', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { log, instance, ensureSession, prepare } = setup({ session: listener })
    await prepared(prepare)
    fireEvent.click(screen.getByRole('button', { name: 'Play' }))

    // Synchronously, before any awaited promise: Safari keeps the window.
    expect(instance.authorize).toHaveBeenCalledOnce()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(log).toContain('play'))
    expect(ensureSession).not.toHaveBeenCalled()
    expect(instance.setQueue).toHaveBeenCalledExactlyOnceWith({ songs: ['1', '3'] })
  })

  it('first-time Apple Music: gets ready in the dialog, then Connect Apple Music authorizes inside its click and plays only the Apple songs in order', async () => {
    const { log, instance } = setup()
    await pressPlay()
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Apple Music' }))
    expect(localStorage.getItem('mixtape.plays-on')).toBe('apple')

    const ready = screen.getByRole('dialog')
    expect(within(ready).getByRole('status')).toHaveTextContent('Getting Apple Music ready…')
    const connect = await screen.findByRole('button', { name: 'Connect Apple Music' })
    expect(log).toEqual(['ensureSession', 'token'])
    expect(instance.authorize).not.toHaveBeenCalled()

    fireEvent.click(connect)
    expect(instance.authorize).toHaveBeenCalledOnce()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(log).toContain('play'))
    expect(log).toEqual(['ensureSession', 'token', 'authorize', 'play'])
    expect(instance.setQueue).toHaveBeenCalledExactlyOnceWith({ songs: ['1', '3'] })
  })

  it('a remembered Apple Music answer without a session opens straight at getting ready', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { ensureSession, instance } = setup()
    await pressPlay()

    expect(within(screen.getByRole('dialog')).getByRole('status')).toHaveTextContent('Getting Apple Music ready…')
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(instance.setQueue).toHaveBeenCalled())
    expect(ensureSession).toHaveBeenCalledOnce()
  })

  it('returns focus to Play once the dialog closes', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { instance } = setup()
    const play = await screen.findByRole('button', { name: 'Play' })
    play.focus()
    fireEvent.click(play)
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))

    // Play stays focusable while it starts (aria-disabled, not disabled).
    expect(play).toHaveFocus()
    expect(play).toHaveAttribute('aria-disabled', 'true')
    await waitFor(() => expect(instance.play).toHaveBeenCalled())
  })

  it('starts the choice dialog on its heading', async () => {
    setup()
    await pressPlay()
    expect(screen.getByRole('heading', { name: 'Where do you listen?' })).toHaveFocus()
  })

  it('says Apple Music couldn’t play a mix with no Apple Music songs, without a session or sign-in', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { ensureSession, instance } = setup({ share: { ...share, tracks: share.tracks.map((track) => ({ ...track, appleId: null })) } })
    await pressPlay()

    expect(await screen.findByRole('alert')).toHaveTextContent('Apple Music couldn’t play this mix.')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(ensureSession).not.toHaveBeenCalled()
    expect(instance.authorize).not.toHaveBeenCalled()
  })

  it('keeps the loaded mix when the session Play made arrives, with no second read', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { api, instance, reads, rerender } = setup()
    await pressPlay()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(instance.play).toHaveBeenCalled())

    vi.spyOn(api, 'getSharedMix').mockRejectedValue(new Error('rate limited'))
    rerender(listener)
    await act(async () => {})
    expect(screen.getByRole('heading', { name: 'Late drive, windows down' })).toBeInTheDocument()
    expect(screen.queryByText('Couldn’t open this mix.')).not.toBeInTheDocument()
    expect(reads()).toBe(1)
  })

  it('saves the share once the session it made exists, and only once', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { instance, saves } = setup()
    await pressPlay()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(instance.play).toHaveBeenCalledTimes(1))
    expect(saves()).toBe(1)

    // The session and MusicKit are ready now: one tap, no dialog.
    fireEvent.click(screen.getByRole('button', { name: 'Play' }))
    expect(instance.authorize).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(instance.play).toHaveBeenCalledTimes(2))
    expect(saves()).toBe(1)
  })

  it('does not save again for a browser that already had a session (it saved on open)', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { instance, saves, prepare } = setup({ session: listener })
    await prepared(prepare)
    await pressPlay()
    await waitFor(() => expect(instance.play).toHaveBeenCalled())
    expect(saves()).toBe(1)
  })

  it('never saves the owner’s own share', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { instance, saves } = setup({ share: { ...share, isOwner: true, sessionId: 'mix-1' } })
    await pressPlay()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))
    await waitFor(() => expect(instance.play).toHaveBeenCalled())
    expect(saves()).toBe(0)
  })

  it('says so in the dialog, without the raw error, when no session can be made (the anonymous limit), and Try again retries', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { log, saves, ensureSession } = setup({ sessionFails: true })
    await pressPlay()

    expect(await screen.findByRole('alert')).toHaveTextContent('Apple Music couldn’t play this mix. Try again in a moment.')
    expect(screen.queryByText(/Too many requests/)).not.toBeInTheDocument()
    expect(log).toEqual(['ensureSession'])
    expect(saves()).toBe(0)

    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Try again' }))
    await waitFor(() => expect(ensureSession).toHaveBeenCalledTimes(2))
    expect(await screen.findByRole('alert')).toBeInTheDocument()

    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Play' })).toBeEnabled()
  })

  it('says so in the dialog when MusicKit can’t be prepared', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    setup({ prepareFails: true })
    await pressPlay()

    expect(await screen.findByRole('alert')).toHaveTextContent('Apple Music couldn’t play this mix. Try again in a moment.')
    expect(screen.queryByText(/script blocked/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Connect Apple Music' })).not.toBeInTheDocument()
  })

  it('says Apple Music didn’t connect when authorization does not finish', async () => {
    localStorage.setItem('mixtape.plays-on', 'apple')
    const { instance } = setup({ authorized: false })
    await pressPlay()
    fireEvent.click(await screen.findByRole('button', { name: 'Connect Apple Music' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Apple Music didn’t connect. Try again.')
    expect(instance.setQueue).not.toHaveBeenCalled()
  })

  it('Spotify: remembers it, explains once, then copies the share’s songs and opens TuneMyMusic', async () => {
    const writeText = vi.fn(async (_text: string) => undefined)
    stubClipboard(writeText)
    const open = vi.spyOn(window, 'open').mockImplementation(() => null)
    const { ensureSession } = setup()
    await pressPlay()
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Spotify' }))

    expect(localStorage.getItem('mixtape.plays-on')).toBe('spotify')
    const explainer = screen.getByRole('dialog', { name: 'Make it a Spotify playlist' })
    expect(within(explainer).getByText(/We’ll copy your 3 songs and open TuneMyMusic/)).toBeInTheDocument()
    expect(open).not.toHaveBeenCalled()

    fireEvent.click(within(explainer).getByRole('button', { name: 'Copy songs and open TuneMyMusic' }))
    expect(writeText).toHaveBeenCalledWith('M83 - Midnight City\nKavinsky - Nightcall\nMGMT - Electric Feel')
    expect(open).toHaveBeenCalledWith('https://www.tunemymusic.com/transfer/freetext-to-spotify', '_blank', 'noopener')
    expect(await screen.findByRole('status')).toHaveTextContent('Copied 3 songs · paste them in, then rename “My Playlist”')

    // Remembered and explained: the next Play goes straight there.
    fireEvent.click(screen.getByRole('button', { name: 'Play' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(open).toHaveBeenCalledTimes(2)
    expect(ensureSession).not.toHaveBeenCalled()
  })
})
