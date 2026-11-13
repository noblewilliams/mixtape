import { StrictMode } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, type ApiSharedMix } from '../api/client'
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
    { title: 'Midnight City', artist: 'M83', album: null, durationMs: 243_000, artwork: { url: 'https://img.test/{w}x{h}.{f}', width: 600, height: 600, bgColor: '222222' }, appleId: '1', isrc: null },
    { title: 'Nightcall', artist: 'Kavinsky', album: null, durationMs: 258_000, artwork: null, appleId: null, isrc: null },
  ],
}
const noSession: SharedMixSession = { isPending: false, userId: null }
const listener: SharedMixSession = { isPending: false, userId: 'listener-1' }

function setup(options: {
  shares?: Record<string, ApiSharedMix | 'revoked'>
  session?: SharedMixSession
  strict?: boolean
} = {}) {
  const api = createFakeApi({}, { sharedMixes: options.shares ?? { [token]: share } })
  const onOwner = vi.fn()
  const page = (session: SharedMixSession) => <SharedMixPage token={token} api={api} session={session} onOwner={onOwner} appUrl="/app/" downloadUrl="https://apps.test/mixtape" />
  const view = render(options.strict ? <StrictMode>{page(options.session ?? noSession)}</StrictMode> : page(options.session ?? noSession))
  const rerender = (session: SharedMixSession) => view.rerender(options.strict ? <StrictMode>{page(session)}</StrictMode> : page(session))
  return { api, onOwner, rerender }
}
const methods = (api: ReturnType<typeof createFakeApi>) => api.calls.map((call) => call.method)

describe('SharedMixPage', () => {
  afterEach(cleanup)

  it('shows the mix with no session: cassette, title, sharer, count, songs and the three actions', async () => {
    setup()

    expect(await screen.findByRole('heading', { level: 1, name: 'Late drive, windows down' })).toBeInTheDocument()
    expect(screen.getByText('Shared by Ada')).toBeInTheDocument()
    expect(screen.getByText('2 songs · 8 min')).toBeInTheDocument()
    const songs = screen.getAllByRole('listitem')
    expect(songs).toHaveLength(2)
    expect(songs[0]).toHaveTextContent('Midnight City')
    expect(songs[0]).toHaveTextContent('M83')
    expect(songs[0]).toHaveTextContent('4:03')
    expect(songs[1]).toHaveTextContent('Nightcall')
    expect(songs[1]).toHaveTextContent('4:18')
    expect(songs[0].querySelector('img')).toHaveAttribute('src', 'https://img.test/72x72.jpg')
    expect(screen.getByRole('link', { name: 'Get the app' })).toHaveAttribute('href', 'https://apps.test/mixtape')
    expect(screen.getByRole('link', { name: 'Make your own mix' })).toHaveAttribute('href', '/app/')

    expect(screen.getByRole('button', { name: 'Play' })).toBeEnabled()
  })

  it('shows a loading state until the share arrives', async () => {
    setup()
    expect(screen.getByRole('main')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Loading mix')
    // One announcement: the cassette is not a second labelled image.
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    expect(screen.getAllByText('Loading mix')).toHaveLength(1)
    expect(await screen.findByText('Shared by Ada')).toBeInTheDocument()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('says "a friend" when the sharer has no name', async () => {
    setup({ shares: { [token]: { ...share, sharerName: null } } })
    expect(await screen.findByText('Shared by a friend')).toBeInTheDocument()
  })

  it('waits for the session check before reading, so the owner can be told', async () => {
    const { api, rerender } = setup({ session: { isPending: true, userId: null } })
    expect(screen.getByRole('status')).toHaveTextContent('Loading mix')
    expect(api.calls).toHaveLength(0)
    rerender(noSession)
    expect(await screen.findByText('Shared by Ada')).toBeInTheDocument()
    expect(methods(api)).toEqual(['getSharedMix'])
  })

  it.each([
    ['revoked', { [token]: 'revoked' as const }],
    ['unknown', {}],
  ])('says a %s share is not shared anymore, with no song data', async (_label, shares) => {
    setup({ shares })
    expect(await screen.findByRole('heading', { name: 'This mix isn’t shared anymore.' })).toBeInTheDocument()
    expect(screen.queryByText(/Shared by/)).not.toBeInTheDocument()
    expect(screen.queryAllByRole('listitem')).toHaveLength(0)
    expect(screen.queryByRole('button', { name: 'Play' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Make your own mix' })).toHaveAttribute('href', '/app/')
    expect(screen.getByRole('link', { name: 'Get the app' })).toHaveAttribute('href', 'https://apps.test/mixtape')
  })

  it('offers a retry when the read fails for another reason', async () => {
    let fail = true
    const api = createFakeApi({}, { sharedMixes: { [token]: share } })
    const getSharedMix = api.getSharedMix
    api.getSharedMix = (...args) => (fail ? Promise.reject(new ApiError(429, { error: 'rate_limited' })) : getSharedMix(...args))
    render(<SharedMixPage token={token} api={api} session={noSession} appUrl="/app/" downloadUrl="/" />)
    expect(await screen.findByText('Couldn’t open this mix.')).toBeInTheDocument()
    fail = false
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Shared by Ada')).toBeInTheDocument()
  })

  it('never saves without a session', async () => {
    const { api } = setup({ session: noSession })
    await screen.findByText('Shared by Ada')
    expect(methods(api)).toEqual(['getSharedMix'])
  })

  it('saves exactly once with a session, even when React runs effects twice', async () => {
    const { api, rerender } = setup({ session: listener, strict: true })
    await screen.findByText('Shared by Ada')
    await waitFor(() => expect(methods(api)).toContain('saveSharedMix'))
    rerender({ ...listener })
    await screen.findByText('Shared by Ada')
    expect(methods(api).filter((method) => method === 'saveSharedMix')).toHaveLength(1)
    expect(methods(api).filter((method) => method === 'getSharedMix')).toHaveLength(1)
    expect(api.calls.find((call) => call.method === 'saveSharedMix')?.args[0]).toBe(token)
    expect((await api.listSharedMixes()).map((row) => row.token)).toEqual([token])
  })

  it('sends the owner to their own mix and saves nothing', async () => {
    const { api, onOwner } = setup({ session: listener, shares: { [token]: { ...share, isOwner: true, sessionId: 'session-7' } } })
    await waitFor(() => expect(onOwner).toHaveBeenCalledWith('listener-1', 'session-7'))
    expect(onOwner).toHaveBeenCalledTimes(1)
    expect(methods(api)).toEqual(['getSharedMix'])
  })

  it('reads once with the session and saves once when the pending session turns out signed in', async () => {
    const { api, rerender } = setup({ session: { isPending: true, userId: null } })
    expect(api.calls).toHaveLength(0)
    rerender(listener)
    await screen.findByText('Shared by Ada')
    await waitFor(() => expect(methods(api)).toContain('saveSharedMix'))
    expect(methods(api)).toEqual(['getSharedMix', 'saveSharedMix'])
  })

  it('saves exactly once when a user appears after a read with no session', async () => {
    const { api, rerender } = setup({ session: noSession })
    await screen.findByText('Shared by Ada')
    expect(methods(api)).toEqual(['getSharedMix'])
    rerender(listener)
    await waitFor(() => expect(methods(api)).toContain('saveSharedMix'))
    rerender({ ...listener })
    await screen.findByText('Shared by Ada')
    expect(methods(api).filter((method) => method === 'saveSharedMix')).toHaveLength(1)
  })

  it('renders none of the mix while sending the owner to it', async () => {
    const { onOwner } = setup({ session: listener, shares: { [token]: { ...share, isOwner: true, sessionId: 'session-7' } } })
    await waitFor(() => expect(onOwner).toHaveBeenCalled())
    expect(screen.queryByRole('heading', { name: 'Late drive, windows down' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Shared by/)).not.toBeInTheDocument()
    expect(screen.queryAllByRole('listitem')).toHaveLength(0)
    expect(screen.queryByRole('button', { name: 'Play' })).not.toBeInTheDocument()
  })

  it('by default opens the app at its own mix, replacing the share page in history', async () => {
    const replace = vi.fn()
    vi.stubGlobal('location', { ...window.location, replace })
    try {
      const api = createFakeApi({}, { sharedMixes: { [token]: { ...share, isOwner: true, sessionId: 'session-7' } } })
      render(<SharedMixPage token={token} api={api} session={listener} appUrl="/app/" downloadUrl="/" />)
      await waitFor(() => expect(replace).toHaveBeenCalledWith('/app/'))
      expect(replace).toHaveBeenCalledTimes(1)
    } finally {
      vi.unstubAllGlobals()
    }
  })

  it('calls nothing but the public share endpoints', async () => {
    const { api } = setup({ session: listener })
    await screen.findByText('Shared by Ada')
    await waitFor(() => expect(methods(api)).toContain('saveSharedMix'))
    expect(new Set(methods(api))).toEqual(new Set(['getSharedMix', 'saveSharedMix']))
  })
})
