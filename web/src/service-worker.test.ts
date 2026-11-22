import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it, vi } from 'vitest'

// public/sw.js run in a small harness: a fake `self` (registration, clients),
// caches and fetch. Only the handlers it registers are driven.
const SOURCE = readFileSync(resolve(__dirname, '../public/sw.js'), 'utf8')
const SCOPE = 'https://miixtape.test/app/'

type Handler = (event: Record<string, unknown>) => void

/** A MessageChannel whose port2 answers synchronously into port1.onmessage. */
class FakeChannel {
  port1: { onmessage: ((event: { data: unknown }) => void) | null } = { onmessage: null }
  port2 = { postMessage: (data: unknown) => this.port1.onmessage?.({ data }) }
}

type FakeClient = {
  url: string
  focused: boolean
  focus: ReturnType<typeof vi.fn>
  postMessage: ReturnType<typeof vi.fn>
}

function client(url: string, { focused = false, showing = false, silent = false } = {}): FakeClient {
  return {
    url,
    focused,
    focus: vi.fn(async () => undefined),
    postMessage: vi.fn((message: { type: string; sessionId: string }, ports?: Array<{ postMessage: (data: unknown) => void }>) => {
      if (message.type === 'mixtape:showing-mix' && !silent) ports?.[0]?.postMessage({ showing })
    }),
  }
}

function boot(windows: FakeClient[] = []) {
  const handlers: Record<string, Handler> = {}
  const showNotification = vi.fn(async () => undefined)
  const openWindow = vi.fn(async () => null)
  const matchAll = vi.fn(async () => windows)
  const self = {
    registration: { scope: SCOPE, showNotification },
    clients: { matchAll, openWindow, claim: vi.fn(async () => undefined) },
    skipWaiting: vi.fn(),
    addEventListener: (type: string, handler: Handler) => { handlers[type] = handler },
  }
  const fetch = vi.fn()
  new Function('self', 'caches', 'fetch', 'MessageChannel', SOURCE)(self, {}, fetch, FakeChannel)
  return { handlers, showNotification, openWindow, matchAll, fetch }
}

async function dispatch(handler: Handler, fields: Record<string, unknown>) {
  let work: Promise<unknown> = Promise.resolve()
  const event: Record<string, unknown> = { ...fields, waitUntil: (promise: Promise<unknown>) => { work = promise } }
  handler(event)
  await work
  return event
}

const payload = { kind: 'ready', title: 'Your mix is ready', body: 'Sunday kitchen soul', sessionId: 'session-1', turnId: 'turn-9' }
const pushEvent = (body: unknown) => ({ data: { json: () => (typeof body === 'string' ? JSON.parse(body) : body) } })

describe('service worker push', () => {
  it('shows the notification, tagged by turn, with the mix in its data and the app icon', async () => {
    const sw = boot([client(`${SCOPE}`, { focused: false })])
    await dispatch(sw.handlers.push, pushEvent(payload))
    expect(sw.showNotification).toHaveBeenCalledWith('Your mix is ready', {
      body: 'Sunday kitchen soul',
      tag: 'turn-9',
      data: { sessionId: 'session-1', kind: 'ready' },
      icon: `${SCOPE}icons/icon-192.png`,
    })
    expect(sw.matchAll).toHaveBeenCalledWith({ type: 'window', includeUncontrolled: true })
  })

  it('carries a failed turn through as failed', async () => {
    const sw = boot()
    await dispatch(sw.handlers.push, pushEvent({ ...payload, kind: 'failed', title: 'Oops, the tape got tangled', body: 'Tap to try again.' }))
    expect(sw.showNotification).toHaveBeenCalledWith('Oops, the tape got tangled', expect.objectContaining({ data: { sessionId: 'session-1', kind: 'failed' } }))
  })

  it('skips it when a focused window already shows that mix', async () => {
    const focused = client(SCOPE, { focused: true, showing: true })
    const sw = boot([focused])
    await dispatch(sw.handlers.push, pushEvent(payload))
    expect(focused.postMessage).toHaveBeenCalledWith({ type: 'mixtape:showing-mix', sessionId: 'session-1' }, expect.any(Array))
    expect(sw.showNotification).not.toHaveBeenCalled()
  })

  it('shows it when the focused window is elsewhere, and asks no unfocused window', async () => {
    const focused = client(SCOPE, { focused: true, showing: false })
    const background = client(SCOPE, { focused: false, showing: true })
    const sw = boot([focused, background])
    await dispatch(sw.handlers.push, pushEvent(payload))
    expect(background.postMessage).not.toHaveBeenCalled()
    expect(sw.showNotification).toHaveBeenCalledOnce()
  })

  it('shows it when a focused window does not answer in time', async () => {
    vi.useFakeTimers()
    try {
      const sw = boot([client(SCOPE, { focused: true, silent: true })])
      let work: Promise<unknown> = Promise.resolve()
      sw.handlers.push({ ...pushEvent(payload), waitUntil: (promise: Promise<unknown>) => { work = promise } })
      await vi.advanceTimersByTimeAsync(600)
      await work
      expect(sw.showNotification).toHaveBeenCalledOnce()
    } finally {
      vi.useRealTimers()
    }
  })

  it('ignores windows outside the app scope', async () => {
    const other = client('https://miixtape.test/', { focused: true, showing: true })
    const sw = boot([other])
    await dispatch(sw.handlers.push, pushEvent(payload))
    expect(other.postMessage).not.toHaveBeenCalled()
    expect(sw.showNotification).toHaveBeenCalledOnce()
  })

  it('shows nothing for a payload it cannot read', async () => {
    const sw = boot()
    const event = await dispatch(sw.handlers.push, { data: { json: () => { throw new SyntaxError('bad') } } })
    expect(event).toBeDefined()
    expect(sw.showNotification).not.toHaveBeenCalled()
  })
})

describe('service worker notificationclick', () => {
  const click = (data: unknown) => ({ notification: { data, close: vi.fn() } })

  it('closes it, focuses an open app window and tells it to open the mix', async () => {
    const window = client(SCOPE)
    const sw = boot([window])
    const event = await dispatch(sw.handlers.notificationclick, click({ sessionId: 'session-1', kind: 'ready' }))
    expect((event.notification as { close: ReturnType<typeof vi.fn> }).close).toHaveBeenCalledOnce()
    expect(window.focus).toHaveBeenCalledOnce()
    expect(window.postMessage).toHaveBeenCalledWith({ type: 'mixtape:open-mix', sessionId: 'session-1' })
    expect(sw.openWindow).not.toHaveBeenCalled()
  })

  it('prefers the focused window when there are several', async () => {
    const first = client(SCOPE)
    const focused = client(`${SCOPE}?x=1`, { focused: true })
    const sw = boot([first, focused])
    await dispatch(sw.handlers.notificationclick, click({ sessionId: 'session-1' }))
    expect(focused.postMessage).toHaveBeenCalledWith({ type: 'mixtape:open-mix', sessionId: 'session-1' })
    expect(first.postMessage).not.toHaveBeenCalled()
  })

  it('opens /app/ on the mix when no app window is open', async () => {
    const sw = boot([client('https://miixtape.test/privacy/')])
    await dispatch(sw.handlers.notificationclick, click({ sessionId: 'session 1' }))
    expect(sw.openWindow).toHaveBeenCalledWith(`${SCOPE}?mix=session+1`)
  })
})

describe('service worker fetch (unchanged)', () => {
  it('never touches an API, auth or cross-origin request', () => {
    const sw = boot()
    for (const url of ['https://api.miixtape.test/sessions', 'https://miixtape.test/api/auth/session']) {
      const respondWith = vi.fn()
      sw.handlers.fetch({ request: { method: 'GET', url, mode: 'cors' }, respondWith })
      expect(respondWith).not.toHaveBeenCalled()
    }
    const respondWith = vi.fn()
    sw.handlers.fetch({ request: { method: 'POST', url: `${SCOPE}assets/x.js`, mode: 'cors' }, respondWith })
    expect(respondWith).not.toHaveBeenCalled()
  })
})
