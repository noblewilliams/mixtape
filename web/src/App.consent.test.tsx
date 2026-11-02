import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { ApiError, type MeResponse, type MixtapeApi } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const TITLE = 'Before your first mix'

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

function me(aiConsent: boolean): MeResponse {
  return { user: { id: user.id, isAnonymous: false }, merged: null, albumPicks: true, neverRefuse: false, aiConsent, askName: false }
}

function renderApp(overrides: Partial<MixtapeApi> = {}, aiConsent = false, anonymous = false) {
  const api = createFakeApi({ getMe: vi.fn(async () => me(aiConsent)), ...overrides })
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={anonymous ? { ...user, isAnonymous: true } : user} onSignOut={vi.fn()} />)
  return api
}

/** The server's answer to a gated request without consent (AI_CONSENT=enforce). */
const consentRequired = () => new ApiError(403, { error: 'ai_consent_required' })

function stubRecorder() {
  const getUserMedia = vi.fn().mockResolvedValue({ getTracks: () => [{ stop: vi.fn() }] })
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
  class Recorder {
    static isTypeSupported() { return true }
    state = 'inactive'; mimeType = 'audio/webm'; ondataavailable: ((event: { data: Blob }) => void) | null = null; onstop: (() => void) | null = null; onerror: (() => void) | null = null
    start() { this.state = 'recording' }
    stop() { this.state = 'inactive'; this.ondataavailable?.({ data: new Blob(['x'.repeat(2048)]) }); this.onstop?.() }
  }
  vi.stubGlobal('MediaRecorder', Recorder)
}

const calls = (api: ReturnType<typeof createFakeApi>, method: keyof MixtapeApi) => api.calls.filter((call) => call.method === method)
const consent = () => screen.findByRole('dialog', { name: TITLE })
const notNow = () => fireEvent.click(within(screen.getByRole('dialog', { name: TITLE })).getByRole('button', { name: 'Not now' }))

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('AI consent over the app', () => {
  it('stays away when /me says consent is granted', async () => {
    const api = renderApp({}, true)
    await waitFor(() => expect(calls(api, 'getMe')).toHaveLength(1))
    await screen.findByRole('textbox', { name: 'Describe your mix' })
    expect(screen.queryByRole('dialog', { name: TITLE })).not.toBeInTheDocument()
  })

  it('shows once when /me says no, with the policy link, and Not now dismisses it', async () => {
    const api = renderApp()
    expect(await consent()).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Privacy policy' })).toHaveAttribute('href', 'https://miixtape.netlify.app/privacy/')
    notNow()
    await waitFor(() => expect(screen.queryByRole('dialog', { name: TITLE })).not.toBeInTheDocument())
    expect(calls(api, 'grantAiConsent')).toHaveLength(0)
  })

  it('re-opens instead of making a mix while consent is missing, keeping the prompt', async () => {
    const api = renderApp()
    await consent()
    notNow()
    const input = await screen.findByRole('textbox', { name: 'Describe your mix' })
    fireEvent.change(input, { target: { value: 'Slow train' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))

    expect(await consent()).toBeInTheDocument()
    expect(calls(api, 'createSession')).toHaveLength(0)
    notNow()
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('Slow train'))
  })

  it('re-opens instead of starting voice while consent is missing', async () => {
    const getUserMedia = vi.fn()
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
    vi.stubGlobal('MediaRecorder', class {})
    const api = renderApp()
    await consent()
    notNow()
    fireEvent.click(await screen.findByRole('button', { name: 'Record a voice prompt' }))

    expect(await consent()).toBeInTheDocument()
    expect(getUserMedia).not.toHaveBeenCalled()
    expect(calls(api, 'transcribe')).toHaveLength(0)
  })

  it('re-opens instead of sending a message in a mix, keeping the text', async () => {
    const api = renderApp()
    await consent()
    notNow()
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    const input = await screen.findByRole('textbox', { name: 'Message your DJ' })
    fireEvent.change(input, { target: { value: 'More bass' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    expect(await consent()).toBeInTheDocument()
    expect(calls(api, 'sendMessage')).toHaveLength(0)
    notNow()
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('More bass'))
  })

  it('Agree records consent, closes, and the next prompt goes through', async () => {
    const api = renderApp()
    await consent()
    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    await waitFor(() => expect(screen.queryByRole('dialog', { name: TITLE })).not.toBeInTheDocument())
    expect(calls(api, 'grantAiConsent')).toHaveLength(1)

    fireEvent.change(await screen.findByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Slow train' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await waitFor(() => expect(calls(api, 'createSession')).toHaveLength(1))
  })

  it('says so inline when the answer cannot be saved, and stays', async () => {
    const api = renderApp({ grantAiConsent: vi.fn(async () => { throw new TypeError('Failed to fetch') }) })
    await consent()
    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    const dialog = await consent()
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Couldn’t save that. Try again.')
    expect(calls(api, 'createSession')).toHaveLength(0)
  })
})

// A listener /me never asked (anonymous, or consent withdrawn by a new version)
// meets the server's 403 instead: the dialog answers and what they wrote stays.
describe('the server asking for AI consent', () => {
  it('opens the dialog for a new mix and keeps the prompt, with no error and no re-send after Agree', async () => {
    const createSession = vi.fn(async () => { throw consentRequired() })
    const api = renderApp({ createSession }, true, true)
    fireEvent.change(await screen.findByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Slow train' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))

    expect(await consent()).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('Slow train')
    expect(screen.queryByText(/Couldn’t make your mix/)).not.toBeInTheDocument()
    expect(document.querySelector('.app-error')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    await waitFor(() => expect(screen.queryByRole('dialog', { name: TITLE })).not.toBeInTheDocument())
    expect(calls(api, 'grantAiConsent')).toHaveLength(1)
    expect(createSession).toHaveBeenCalledOnce()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('Slow train')
  })

  it('opens the dialog for a message in a mix and puts the text back, with no error turn', async () => {
    const sendMessage = vi.fn(async () => { throw consentRequired() })
    renderApp({ sendMessage }, true)
    fireEvent.click(await screen.findByRole('button', { name: 'Mixes' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Open Blue hour, windows down' }))
    fireEvent.change(await screen.findByRole('textbox', { name: 'Message your DJ' }), { target: { value: 'More bass' } })
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }))

    expect(await consent()).toBeInTheDocument()
    expect(sendMessage).toHaveBeenCalledOnce()
    notNow()
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Message your DJ' })).toHaveValue('More bass'))
    expect(screen.queryByText('More bass', { selector: ':not(textarea)' })).not.toBeInTheDocument()
    expect(screen.queryByText(/Something interrupted|Couldn’t send/)).not.toBeInTheDocument()
  })

  it('opens the dialog for a voice clip instead of a transcription error', async () => {
    stubRecorder()
    const transcribe = vi.fn(async () => { throw consentRequired() })
    renderApp({ transcribe }, true)
    fireEvent.click(await screen.findByRole('button', { name: 'Record a voice prompt' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Stop recording' }))

    expect(await consent()).toBeInTheDocument()
    expect(transcribe).toHaveBeenCalledOnce()
    expect(screen.queryByText(/Couldn’t transcribe/)).not.toBeInTheDocument()
  })

  it('keeps other 403s as they were', async () => {
    const createSession = vi.fn(async () => { throw new ApiError(403, { error: 'forbidden' }) })
    renderApp({ createSession }, true)
    fireEvent.change(await screen.findByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'Slow train' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    expect(await screen.findByText(/Couldn’t make your mix/)).toBeInTheDocument()
    expect(screen.queryByRole('dialog', { name: TITLE })).not.toBeInTheDocument()
  })
})
