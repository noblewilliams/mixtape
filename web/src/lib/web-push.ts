import type { MixtapeApi, WebPushDevice } from '../api/client'

// Web push for Mix ready notifications (spec 2026-11-21 durable turns, "Web
// push"; approved pop-up docs/mockups/approved/2026-11-21-push-permission-modal.md).
// Everything here fails quietly: a browser that cannot or will not take push
// simply gets no ping, and the mix is there when the listener comes back.

export type PushApi = Pick<MixtapeApi, 'putPushDevice' | 'deletePushDevice'>
/** The VAPID public key from /health; null or undefined means push is off on the server. */
export type ReadPushKey = () => Promise<string | null | undefined>

/** "Asked once in this browser", set the moment the pop-up appears, however it closes. */
export const PUSH_ASKED_KEY = 'mixtape.pushAsked.v1'

/** The service worker's messages to a page (public/sw.js). */
export const SW_OPEN_MIX = 'mixtape:open-mix'
export const SW_SHOWING_MIX = 'mixtape:showing-mix'
/** The query a notification opens a new window with: /app/?mix=<sessionId>. */
export const MIX_LINK_PARAM = 'mix'

/** Push is possible here: Chromium, Firefox, desktop Safari, and the iOS Home Screen web app (never a Safari tab). */
export function pushSupported(): boolean {
  return typeof window !== 'undefined'
    && 'PushManager' in window
    && 'Notification' in window
    && typeof navigator !== 'undefined'
    && 'serviceWorker' in navigator
}

export function pushPermission(): NotificationPermission | 'unsupported' {
  if (!pushSupported()) return 'unsupported'
  try {
    return Notification.permission
  } catch {
    return 'unsupported'
  }
}

/** 'unknown' when storage throws: the pop-up then never shows, since "once" cannot be kept. */
export function pushAskState(): 'unasked' | 'asked' | 'unknown' {
  try {
    return window.localStorage.getItem(PUSH_ASKED_KEY) ? 'asked' : 'unasked'
  } catch {
    return 'unknown'
  }
}

/** True when the flag was written. */
export function markPushAsked(): boolean {
  try {
    window.localStorage.setItem(PUSH_ASKED_KEY, '1')
    return true
  } catch {
    return false
  }
}

/** The VAPID key as the bytes pushManager.subscribe wants (base64url, padding optional). */
export function urlBase64ToUint8Array(base64Url: string): Uint8Array<ArrayBuffer> {
  const padded = `${base64Url}${'='.repeat((4 - (base64Url.length % 4)) % 4)}`
  const raw = atob(padded.replace(/-/g, '+').replace(/_/g, '/'))
  const bytes = new Uint8Array(new ArrayBuffer(raw.length))
  for (let index = 0; index < raw.length; index += 1) bytes[index] = raw.charCodeAt(index)
  return bytes
}

function warn(what: string) {
  // Never the endpoint, keys or error text: they identify the browser.
  console.warn(`Mix ready notifications: ${what}`)
}

function timeout<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise<T>((resolve) => {
    const timer = setTimeout(() => resolve(fallback), ms)
    promise.then(
      (value) => { clearTimeout(timer); resolve(value) },
      () => { clearTimeout(timer); resolve(fallback) },
    )
  })
}

/** The registration that controls this page, if any; never waits for one (dev builds register none). */
async function currentRegistration(): Promise<ServiceWorkerRegistration | undefined> {
  if (!pushSupported()) return undefined
  return timeout(navigator.serviceWorker.getRegistration().catch(() => undefined), 3000, undefined)
}

/** This browser's push subscription, or null. */
export async function currentPushSubscription(): Promise<PushSubscription | null> {
  const registration = await currentRegistration()
  if (!registration) return null
  try {
    return await registration.pushManager.getSubscription()
  } catch {
    return null
  }
}

export function webPushDevice(subscription: PushSubscription): WebPushDevice | null {
  const json = subscription.toJSON()
  const p256dh = json.keys?.p256dh
  const auth = json.keys?.auth
  const token = json.endpoint ?? subscription.endpoint
  if (!token || !p256dh || !auth) return null
  return { provider: 'webpush', platform: 'web', token, keys: { p256dh, auth } }
}

/**
 * With permission already granted: the subscription (made if missing) and
 * PUT /push/devices. True once the server has the device.
 */
export async function registerPush(api: PushApi, vapidPublicKey: string): Promise<boolean> {
  try {
    const registration = await timeout(navigator.serviceWorker.ready, 10_000, null)
    if (!registration) return false
    const subscription = (await registration.pushManager.getSubscription())
      ?? await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(vapidPublicKey) })
    const device = webPushDevice(subscription)
    if (!device) return false
    await api.putPushDevice(device)
    return true
  } catch {
    warn('could not subscribe')
    return false
  }
}

/**
 * The CTA: asks the browser (this must run inside the click), then registers.
 * Resolves to the permission the listener gave.
 */
export function enablePush(api: PushApi, vapidPublicKey: string): Promise<NotificationPermission> {
  let asked: Promise<NotificationPermission>
  try {
    // First, before any await: browsers only ask from a user gesture.
    asked = Promise.resolve(Notification.requestPermission())
  } catch {
    return Promise.resolve('default')
  }
  return asked.then(
    async (permission) => {
      if (permission === 'granted') await registerPush(api, vapidPublicKey)
      return permission
    },
    () => {
      warn('the permission request failed')
      return 'default' as NotificationPermission
    },
  )
}

/** Settings' off: the server forgets the device, then the browser drops the subscription. */
export async function disablePush(api: PushApi): Promise<void> {
  const subscription = await currentPushSubscription()
  if (!subscription) return
  try {
    await api.deletePushDevice(subscription.endpoint)
  } catch {
    warn('could not forget this device')
  }
  try {
    await subscription.unsubscribe()
  } catch {
    warn('could not unsubscribe')
  }
}

/**
 * Sign-out: the server forgets this browser before the session is dropped,
 * so the next account here is never pinged with the last one's mixes. The
 * subscription stays; the next sign-in registers it for its own account.
 * Never takes longer than `ms`.
 */
export function forgetPushDevice(api: PushApi, ms = 2500): Promise<void> {
  const work = (async () => {
    const subscription = await currentPushSubscription()
    if (!subscription) return
    try {
      await api.deletePushDevice(subscription.endpoint)
    } catch {
      warn('could not forget this device')
    }
  })()
  return timeout(work, ms, undefined)
}

/** The mix a notification opened this window on (/app/?mix=<id>), removed from the address bar. */
export function takeLinkedMix(): string | null {
  if (typeof window === 'undefined') return null
  try {
    const url = new URL(window.location.href)
    const id = url.searchParams.get(MIX_LINK_PARAM)
    if (!id) return null
    url.searchParams.delete(MIX_LINK_PARAM)
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`)
    return id
  } catch {
    return null
  }
}
