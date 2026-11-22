import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AuthPreferenceStore } from '../../lib/auth-provider'
import { createdSession, fakeServices } from '../../test/first-run-fakes'
import { installFakePush } from '../../test/fake-push'
import { PUSH_TITLE } from '../PushPermission'
import { FirstRun } from './FirstRun'

vi.setConfig({ testTimeout: 15_000 })

const KEY = 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U'
const preferences: AuthPreferenceStore = { lastUsed: () => null, begin: vi.fn(), promotePending: () => null, clearPending: vi.fn(), forget: vi.fn() }

let fake: ReturnType<typeof installFakePush> | null = null
beforeEach(() => {
  window.history.replaceState(null, '', '/')
  window.localStorage.clear()
})
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  fake?.restore()
  fake = null
  window.localStorage.clear()
  document.title = ''
})

async function toMaking() {
  const fakes = fakeServices()
  fakes.api.getConfig.mockImplementation(async () => ({ neverRefuse: false, djPaused: false, vapidPublicKey: KEY }))
  fakes.api.createSession.mockImplementationOnce(() => new Promise<ReturnType<typeof createdSession>>(() => {}))
  render(<FirstRun services={fakes.services} signIn={{ auth: { signIn: vi.fn(async () => ({})) }, preferences, lastUsed: null, error: '' }} onDone={vi.fn()} />)
  fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'late night drive' } })
  fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
  await screen.findByRole('heading', { level: 1, name: 'Who do you love?' })
  ;['First artist', 'Second artist', 'Third artist'].forEach((label, index) =>
    fireEvent.change(screen.getByRole('textbox', { name: label }), { target: { value: ['Burna Boy', 'Tems', 'Sade'][index] } }))
  fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Agree and continue' }))
  await screen.findByRole('heading', { level: 1, name: 'Making your mix.' })
  return fakes
}

describe('the push pop-up on Making your mix', () => {
  it('shows about 3 s in, and after Allow subscribes and adds the ping line', async () => {
    fake = installFakePush()
    const { api } = await toMaking()
    expect(screen.queryByRole('dialog', { name: PUSH_TITLE })).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: 'Turn on notifications' }, { timeout: 4500 }))
    await waitFor(() => expect(api.putPushDevice).toHaveBeenCalledOnce())
    expect(await screen.findByText('We’ll ping you when it’s ready.')).toBeInTheDocument()
  })

  it('never shows where push is absent', async () => {
    fake = installFakePush({ noPushManager: true })
    await toMaking()
    await new Promise((resolve) => setTimeout(resolve, 3400))
    expect(screen.queryByRole('dialog', { name: PUSH_TITLE })).not.toBeInTheDocument()
  })
})
