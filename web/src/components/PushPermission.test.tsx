import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PUSH_BODY, PUSH_TITLE, PushNotificationsRow, PushOffer, PushPermission } from './PushPermission'
import { ControlModal } from './ControlModal'
import { PUSH_ASKED_KEY, urlBase64ToUint8Array } from '../lib/web-push'
import { installFakePush } from '../test/fake-push'

const KEY = 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U'

let fake: ReturnType<typeof installFakePush> | null = null
function push(options: Parameters<typeof installFakePush>[0] = {}) {
  fake = installFakePush(options)
  return fake
}
const fakeApi = () => ({ putPushDevice: vi.fn(async () => undefined), deletePushDevice: vi.fn(async () => undefined) })
const dialog = () => screen.queryByRole('dialog', { name: PUSH_TITLE })

beforeEach(() => window.localStorage.clear())
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  fake?.restore()
  fake = null
  window.localStorage.clear()
})

describe('PushPermission', () => {
  it('shows the approved copy, centred, with the two quiet buttons, and hides the art from assistive tech', () => {
    render(<PushPermission onTurnOn={vi.fn()} onNotNow={vi.fn()} />)
    const popup = screen.getByRole('dialog', { name: 'Want a ping when it’s ready?' })
    expect(popup).toHaveAttribute('aria-modal', 'true')
    expect(popup).toHaveAccessibleDescription(PUSH_BODY)
    expect(PUSH_BODY).toBe('Mixes take up to a minute. Close the tab, get on with your day, and we’ll tell you the moment yours is ready.')
    expect(within(popup).getByRole('heading', { name: PUSH_TITLE })).toHaveStyle({ textAlign: 'center', fontSize: '15px', fontWeight: '700' })
    expect(within(popup).getByText(PUSH_BODY)).toHaveStyle({ textAlign: 'center', fontSize: '13px' })
    const buttons = within(popup).getAllByRole('button')
    expect(buttons.map((button) => button.textContent)).toEqual(['Not now', 'Turn on notifications'])
    buttons.forEach((button) => expect(button).toHaveClass('wc-text'))
    expect(screen.getByTestId('push-art')).toHaveAttribute('aria-hidden', 'true')
    expect(screen.getByTestId('push-art')).toHaveTextContent('Your mix is ready')
    expect(popup.parentElement).toHaveClass('wc-overlay', 'wc-overlay--blur')
    expect(screen.getByRole('button', { name: 'Not now' })).toHaveFocus()
  })

  it('treats Escape and a tap outside as Not now', () => {
    const onNotNow = vi.fn()
    render(<PushPermission onTurnOn={vi.fn()} onNotNow={onNotNow} />)
    fireEvent.keyDown(document, { key: 'Escape' })
    fireEvent.mouseDown(screen.getByRole('dialog').parentElement!)
    expect(onNotNow).toHaveBeenCalledTimes(2)
  })
})

describe('PushOffer', () => {
  it('waits about 3 s, then shows once and sets the flag the moment it appears', async () => {
    vi.useFakeTimers()
    push()
    render(<PushOffer api={fakeApi()} readKey={async () => KEY} when />)
    await act(async () => {})
    act(() => { vi.advanceTimersByTime(2999) })
    expect(dialog()).toBeNull()
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBeNull()
    act(() => { vi.advanceTimersByTime(1) })
    expect(dialog()).not.toBeNull()
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBe('1')
  })

  it('never shows again in this browser once asked', async () => {
    push()
    window.localStorage.setItem(PUSH_ASKED_KEY, '1')
    const readKey = vi.fn(async () => KEY)
    render(<PushOffer api={fakeApi()} readKey={readKey} when delayMs={0} />)
    await waitFor(() => expect(readKey).toHaveBeenCalled())
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
  })

  it.each([
    ['reading', 'getItem'],
    ['writing', 'setItem'],
  ] as const)('never shows when storage throws on %s', async (_label, method) => {
    push()
    vi.spyOn(Storage.prototype, method).mockImplementation(() => { throw new Error('blocked') })
    render(<PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(dialog()).toBeNull()
  })

  it('is never offered without PushManager, and reads no key', async () => {
    push({ noPushManager: true })
    const readKey = vi.fn(async () => KEY)
    render(<PushOffer api={fakeApi()} readKey={readKey} when delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(readKey).not.toHaveBeenCalled()
    expect(dialog()).toBeNull()
  })

  it('is never offered when /health has no VAPID key', async () => {
    push()
    render(<PushOffer api={fakeApi()} readKey={async () => undefined} when delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBeNull()
  })

  it('is never offered once the browser has denied', async () => {
    const env = push({ permission: 'denied' })
    const api = fakeApi()
    render(<PushOffer api={api} readKey={async () => KEY} when delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
    expect(env.pushManager.subscribe).not.toHaveBeenCalled()
    expect(api.putPushDevice).not.toHaveBeenCalled()
  })

  it('registers silently when permission is already granted, with no pop-up', async () => {
    const env = push({ permission: 'granted' })
    const api = fakeApi()
    render(<PushOffer api={api} readKey={async () => KEY} when delayMs={0} />)
    await waitFor(() => expect(api.putPushDevice).toHaveBeenCalledOnce())
    expect(env.pushManager.subscribe).toHaveBeenCalledWith({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(KEY) })
    expect(api.putPushDevice).toHaveBeenCalledWith({ provider: 'webpush', platform: 'web', token: 'https://push.example/sub-new', keys: { p256dh: 'p256dh-key', auth: 'auth-key' } })
    expect(dialog()).toBeNull()
    expect(env.requestPermission).not.toHaveBeenCalled()
  })

  it('Turn on asks the browser, subscribes with the converted key, then PUTs the device', async () => {
    const env = push()
    const api = fakeApi()
    const onEnabled = vi.fn()
    render(<PushOffer api={api} readKey={async () => KEY} when delayMs={0} onEnabled={onEnabled} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Turn on notifications' }))
    // Inside the click: the ask goes out before anything is awaited.
    expect(env.requestPermission).toHaveBeenCalledOnce()
    await waitFor(() => expect(api.putPushDevice).toHaveBeenCalledOnce())
    expect(env.log).toEqual(['requestPermission', 'subscribe'])
    const [options] = env.pushManager.subscribe.mock.calls[0]
    expect(options.userVisibleOnly).toBe(true)
    expect(Array.from(options.applicationServerKey as Uint8Array)).toEqual(Array.from(urlBase64ToUint8Array(KEY)))
    expect(api.putPushDevice).toHaveBeenCalledWith({ provider: 'webpush', platform: 'web', token: 'https://push.example/sub-new', keys: { p256dh: 'p256dh-key', auth: 'auth-key' } })
    expect(onEnabled).toHaveBeenCalledOnce()
    expect(dialog()).toBeNull()
  })

  it('a refusal at the browser prompt subscribes nothing', async () => {
    const env = push({ answer: 'denied' })
    const api = fakeApi()
    render(<PushOffer api={api} readKey={async () => KEY} when delayMs={0} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Turn on notifications' }))
    await waitFor(() => expect(env.requestPermission).toHaveBeenCalled())
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(env.pushManager.subscribe).not.toHaveBeenCalled()
    expect(api.putPushDevice).not.toHaveBeenCalled()
  })

  it('swallows a failed subscribe', async () => {
    const env = push()
    env.pushManager.subscribe.mockRejectedValueOnce(new Error('push service down'))
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    const api = fakeApi()
    render(<PushOffer api={api} readKey={async () => KEY} when delayMs={0} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Turn on notifications' }))
    await waitFor(() => expect(warn).toHaveBeenCalledWith('Mix ready notifications: could not subscribe'))
    expect(api.putPushDevice).not.toHaveBeenCalled()
  })

  it.each([
    ['Not now', () => fireEvent.click(screen.getByRole('button', { name: 'Not now' }))],
    ['Escape', () => fireEvent.keyDown(document, { key: 'Escape' })],
    ['a tap outside', () => fireEvent.mouseDown(screen.getByRole('dialog').parentElement!)],
  ])('%s closes it, the flag stays set, and it never comes back', async (_label, close) => {
    const env = push()
    const { unmount } = render(<PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} />)
    await screen.findByRole('dialog', { name: PUSH_TITLE })
    close()
    expect(dialog()).toBeNull()
    expect(env.requestPermission).not.toHaveBeenCalled()
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBe('1')
    unmount()
    render(<PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
  })

  it('never stacks on the AI consent: it waits until that closes', async () => {
    push()
    const { rerender } = render(<PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} blocked />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
    rerender(<PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} blocked={false} />)
    expect(await screen.findByRole('dialog', { name: PUSH_TITLE })).toBeInTheDocument()
  })

  it('waits while another dialog is open', async () => {
    push()
    function Harness({ other }: { other: boolean }) {
      return <>
        {other ? <ControlModal title="Before your first mix" onClose={() => {}}><p>consent</p></ControlModal> : null}
        <PushOffer api={fakeApi()} readKey={async () => KEY} when delayMs={0} />
      </>
    }
    const { rerender } = render(<Harness other />)
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(dialog()).toBeNull()
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBeNull()
    rerender(<Harness other={false} />)
    expect(await screen.findByRole('dialog', { name: PUSH_TITLE }, { timeout: 2500 })).toBeInTheDocument()
  })

  it('stays away while the moment is not right', async () => {
    push()
    render(<PushOffer api={fakeApi()} readKey={async () => KEY} when={false} delayMs={0} />)
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(dialog()).toBeNull()
  })
})

describe('PushNotificationsRow', () => {
  it('is hidden where PushManager is absent', async () => {
    push({ noPushManager: true })
    render(<PushNotificationsRow api={fakeApi()} readKey={async () => KEY} />)
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(screen.queryByTestId('push-row')).toBeNull()
  })

  it('is hidden when the server has push off', async () => {
    push()
    render(<PushNotificationsRow api={fakeApi()} readKey={async () => undefined} />)
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(screen.queryByTestId('push-row')).toBeNull()
  })

  it('says it is blocked, with no switch, once the browser denied', async () => {
    push({ permission: 'denied' })
    render(<PushNotificationsRow api={fakeApi()} readKey={async () => KEY} />)
    const row = await screen.findByTestId('push-row')
    expect(row).toHaveTextContent('Mix ready notifications')
    expect(row).toHaveTextContent('Blocked in your browser settings')
    expect(within(row).queryByRole('checkbox')).toBeNull()
  })

  it('is off before asking, and turning it on runs the ask, the subscribe and the PUT', async () => {
    const env = push()
    const api = fakeApi()
    render(<PushNotificationsRow api={api} readKey={async () => KEY} />)
    const toggle = await screen.findByRole('checkbox', { name: /Mix ready notifications/ })
    expect(toggle).not.toBeChecked()
    fireEvent.click(toggle)
    expect(env.requestPermission).toHaveBeenCalledOnce()
    await waitFor(() => expect(screen.getByRole('checkbox', { name: /Mix ready notifications/ })).toBeChecked())
    expect(api.putPushDevice).toHaveBeenCalledOnce()
    // The pop-up never asks after this.
    expect(window.localStorage.getItem(PUSH_ASKED_KEY)).toBe('1')
  })

  it('is on with a subscription, and turning it off DELETEs the endpoint then unsubscribes', async () => {
    const env = push({ permission: 'granted', endpoint: 'https://push.example/sub-1' })
    const api = fakeApi()
    api.deletePushDevice.mockImplementation(async () => { env.log.push('delete') })
    render(<PushNotificationsRow api={api} readKey={async () => KEY} />)
    const toggle = await screen.findByRole('checkbox', { name: /Mix ready notifications/ })
    await waitFor(() => expect(toggle).toBeChecked())
    fireEvent.click(toggle)
    await waitFor(() => expect(screen.getByRole('checkbox', { name: /Mix ready notifications/ })).not.toBeChecked())
    expect(api.deletePushDevice).toHaveBeenCalledWith('https://push.example/sub-1')
    expect(env.log).toEqual(['delete', 'unsubscribe'])
  })
})
