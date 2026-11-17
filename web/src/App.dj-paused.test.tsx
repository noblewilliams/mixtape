import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, type MeResponse, type MixtapeApi, type PublicConfig } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { DJ_PAUSED_DETAIL, DJ_PAUSED_LINE, DjStatusProvider } from './lib/dj-status'
import { createFakeApi } from './test/fake-api'

vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const musicKit = {
  connect: vi.fn(async () => undefined),
  snapshot: vi.fn(),
  play: vi.fn(async () => undefined),
  playAlbum: vi.fn(async () => undefined),
  pause: vi.fn(async () => undefined),
  createPlaylist: vi.fn(async () => undefined),
} as unknown as MusicKitClient
const accountAuth: AccountBridge = {
  listAccounts: vi.fn(async () => []),
  linkProvider: vi.fn(async () => ({})),
  unlinkAccount: vi.fn(async () => ({})),
}
const me: MeResponse = { user: { id: user.id, isAnonymous: false }, merged: null, albumPicks: true, neverRefuse: false, aiConsent: true, askName: false }
const djPaused = () => new ApiError(503, { error: 'dj_paused' })

function renderApp(overrides: Partial<MixtapeApi> = {}, health: PublicConfig = { neverRefuse: false, djPaused: false }) {
  const getConfig = vi.fn(async () => health)
  const api = createFakeApi({ getMe: vi.fn(async () => me), getConfig, ...overrides })
  render(<DjStatusProvider api={{ getConfig }}><App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={vi.fn()} /></DjStatusProvider>)
  return { api, getConfig }
}
const calls = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)

afterEach(() => { cleanup(); vi.unstubAllGlobals() })

describe('the DJ paused over the app', () => {
  it('a new mix refused with dj_paused keeps the prompt, pauses Home, and shows no error', async () => {
    const createSession = vi.fn(async () => { throw djPaused() })
    renderApp({ createSession })
    fireEvent.change(await screen.findByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Slow train' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))

    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toBeDisabled())
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('Slow train')
    expect(screen.getByText(`${DJ_PAUSED_LINE}. ${DJ_PAUSED_DETAIL}`)).toBeInTheDocument()
    expect(screen.queryByText(/Couldn’t make your mix/)).not.toBeInTheDocument()
    expect(document.querySelector('.app-error')).toBeNull()
    expect(createSession).toHaveBeenCalledOnce()
  })

  it('a turn refused with dj_paused puts the text back with no error turn', async () => {
    const sendMessage = vi.fn(async () => { throw djPaused() })
    renderApp({ sendMessage })
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    fireEvent.change(await screen.findByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'More bass' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toBeDisabled())
    expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('More bass')
    expect(screen.queryByText('More bass', { selector: ':not(textarea)' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Something interrupted|Couldn’t send/)).not.toBeInTheDocument()
  })

  it('paused by /health on load: Home sends nothing, and opening a mix still works', async () => {
    const { api } = renderApp({}, { neverRefuse: false, djPaused: true })
    const input = await screen.findByRole('textbox', { name: 'Describe your mix' })
    await waitFor(() => expect(input).toBeDisabled())
    expect(input).toHaveAttribute('placeholder', DJ_PAUSED_LINE)
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(calls(api, 'createSession')).toHaveLength(0)

    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    expect(await screen.findByRole('textbox', { name: 'Message your DJ' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Open your mix' })).toBeEnabled()
    expect(calls(api, 'sendMessage')).toHaveLength(0)
  })
})
