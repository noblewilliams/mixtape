import { vi } from 'vitest'

type Permission = NotificationPermission

export type FakePushOptions = {
  permission?: Permission
  /** What Notification.requestPermission resolves to (and then becomes). */
  answer?: Permission
  /** An existing subscription's endpoint; none by default. */
  endpoint?: string | null
  /** Leave PushManager out (a Safari tab on iPhone, an old browser). */
  noPushManager?: boolean
}

/**
 * A browser with web push: Notification, PushManager and a service worker
 * registration whose pushManager records subscribe calls. Undo with
 * vi.unstubAllGlobals() and `restore()`.
 */
export function installFakePush({ permission = 'default', answer = 'granted', endpoint = null, noPushManager = false }: FakePushOptions = {}) {
  const log: string[] = []
  const state = { permission, endpoint }
  const subscription = () => state.endpoint ? {
    endpoint: state.endpoint,
    toJSON: () => ({ endpoint: state.endpoint!, keys: { p256dh: 'p256dh-key', auth: 'auth-key' } }),
    unsubscribe: vi.fn(async () => { log.push('unsubscribe'); state.endpoint = null; current = null; return true }),
  } : null
  let current = subscription()
  const pushManager = {
    getSubscription: vi.fn(async () => current),
    subscribe: vi.fn(async (_options: PushSubscriptionOptionsInit) => {
      log.push('subscribe')
      state.endpoint = 'https://push.example/sub-new'
      current = subscription()
      return current
    }),
  }
  const registration = { pushManager, scope: 'http://localhost:3000/' }
  const requestPermission = vi.fn(async () => {
    log.push('requestPermission')
    state.permission = answer
    return answer
  })
  class FakeNotification {
    static get permission() { return state.permission }
    static requestPermission = requestPermission
  }
  vi.stubGlobal('Notification', FakeNotification)
  if (!noPushManager) vi.stubGlobal('PushManager', class {})
  const listeners = new Set<(event: MessageEvent) => void>()
  const container = {
    ready: Promise.resolve(registration),
    getRegistration: vi.fn(async () => registration),
    addEventListener: (type: string, listener: (event: MessageEvent) => void) => { if (type === 'message') listeners.add(listener) },
    removeEventListener: (type: string, listener: (event: MessageEvent) => void) => { if (type === 'message') listeners.delete(listener) },
    startMessages: () => undefined,
  }
  Object.defineProperty(navigator, 'serviceWorker', { configurable: true, value: container })
  return {
    log,
    state,
    pushManager,
    requestPermission,
    subscription: () => current,
    /** The service worker posting to the page. */
    post(data: unknown, ports: MessagePort[] = []) {
      const event = new MessageEvent('message', { data })
      // jsdom wants real MessagePorts in the constructor; a test's fake reply port goes on directly.
      Object.defineProperty(event, 'ports', { value: ports })
      listeners.forEach((listener) => listener(event))
    },
    restore() {
      delete (navigator as { serviceWorker?: unknown }).serviceWorker
    },
  }
}
