import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import type { MeResponse, MixtapeApi } from './api/client'
import type { AccountBridge } from './components/AccountDialog'
import type { MusicKitClient } from './musickit/client'
import { createFakeApi } from './test/fake-api'
import { installFakePush } from './test/fake-push'
import { PUSH_TITLE } from './components/PushPermission'
import { Making } from './components/first-run/Making'

// Whole-app renders run long on a loaded machine; the default 5 s is too tight there.
vi.setConfig({ testTimeout: 15_000 })

const user = { id: 'user-1', name: 'Noble', email: 'noble@example.com' }
const KEY = 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U'
const CONSENT = 'Before your first mix'

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

const me = (aiConsent: boolean): MeResponse => ({ user: { id: user.id, isAnonymous: false }, merged: null, albumPicks: true, neverRefuse: false, aiConsent, askName: false })

let fake: ReturnType<typeof installFakePush> | null = null

function renderApp({ aiConsent = true, overrides = {} as Partial<MixtapeApi>, onSignOut = vi.fn() } = {}) {
  const api = createFakeApi({ getMe: vi.fn(async () => me(aiConsent)), ...overrides })
  render(<App api={api} accountAuth={accountAuth} lastSignInProvider="apple" musicKit={musicKit} user={user} onSignOut={onSignOut} readPushKey={async () => KEY} />)
  return { api, onSignOut }
}

beforeEach(() => window.localStorage.clear())
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  fake?.restore()
  fake = null
  window.localStorage.clear()
})

describe('Mix ready notifications in the app', () => {
  it('asks once on Home for a listener who was never asked', async () => {
    fake = installFakePush()
    renderApp()
    expect(await screen.findByRole('dialog', { name: PUSH_TITLE }, { timeout: 4000 })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(screen.queryByRole('dialog', { name: PUSH_TITLE })).not.toBeInTheDocument()
  })

  it('never stacks on the AI consent: it comes once the consent closes', async () => {
    fake = installFakePush()
    renderApp({ aiConsent: false })
    const consent = await screen.findByRole('dialog', { name: CONSENT })
    await new Promise((resolve) => setTimeout(resolve, 1800))
    expect(screen.queryByRole('dialog', { name: PUSH_TITLE })).not.toBeInTheDocument()
    fireEvent.click(within(consent).getByRole('button', { name: 'Not now' }))
    expect(await screen.findByRole('dialog', { name: PUSH_TITLE }, { timeout: 4000 })).toBeInTheDocument()
  })

  it('says nothing on a browser without push', async () => {
    fake = installFakePush({ noPushManager: true })
    renderApp()
    await screen.findByRole('textbox', { name: 'Describe your mix' })
    await new Promise((resolve) => setTimeout(resolve, 1800))
    expect(screen.queryByRole('dialog', { name: PUSH_TITLE })).not.toBeInTheDocument()
  })

  it('forgets this browser on the server before the session is dropped at sign-out', async () => {
    fake = installFakePush({ permission: 'granted', endpoint: 'https://push.example/sub-1' })
    let finish!: () => void
    const order: string[] = []
    const deletePushDevice = vi.fn((token: string) => {
      order.push(`delete:${token}`)
      return new Promise<void>((resolve) => { finish = resolve })
    })
    const onSignOut = vi.fn(() => { order.push('signOut') })
    renderApp({ overrides: { deletePushDevice }, onSignOut })
    fireEvent.click(await screen.findByRole('button', { name: 'Settings' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))
    await waitFor(() => expect(deletePushDevice).toHaveBeenCalledOnce())
    expect(onSignOut).not.toHaveBeenCalled()
    finish()
    await waitFor(() => expect(onSignOut).toHaveBeenCalledOnce())
    expect(order).toEqual(['delete:https://push.example/sub-1', 'signOut'])
  })

  it('signs out at once where push is absent', async () => {
    const onSignOut = vi.fn()
    renderApp({ onSignOut })
    fireEvent.click(await screen.findByRole('button', { name: 'Settings' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))
    expect(onSignOut).toHaveBeenCalledOnce()
  })

  it('shows the settings row in This device', async () => {
    fake = installFakePush({ permission: 'denied' })
    renderApp()
    fireEvent.click(await screen.findByRole('button', { name: 'Settings' }))
    const row = await screen.findByTestId('push-row')
    expect(row).toHaveTextContent('Blocked in your browser settings')
  })

  it('opens the mix a notification tap names, and answers whether it shows a mix', async () => {
    fake = installFakePush({ permission: 'denied' })
    renderApp()
    await screen.findByRole('textbox', { name: 'Describe your mix' })
    fake.post({ type: 'mixtape:open-mix', sessionId: 'blue-hour' })
    expect(await screen.findByRole('heading', { name: 'Blue hour, windows down' })).toBeInTheDocument()

    const answers: unknown[] = []
    const port = { postMessage: (data: unknown) => answers.push(data) } as unknown as MessagePort
    const ask = (sessionId: string) => fake!.post({ type: 'mixtape:showing-mix', sessionId }, [port])
    ask('blue-hour')
    ask('another-mix')
    expect(answers).toEqual([{ showing: true }, { showing: false }])
  })
})

describe('Making your mix after Allow', () => {
  it('adds the quiet ping line only once notifications are on', () => {
    const { rerender } = render(<Making />)
    expect(screen.queryByText('We’ll ping you when it’s ready.')).not.toBeInTheDocument()
    rerender(<Making ping />)
    expect(screen.getByText('We’ll ping you when it’s ready.')).toBeInTheDocument()
  })
})
