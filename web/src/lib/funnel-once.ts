// Funnel events that fire once per listener (`first_personal_mix`,
// `first_output`). "Once" is a per-user, per-device flag in localStorage,
// written only after the post lands so an offline or failed post is tried
// again on the next occasion; the server tolerates duplicates, so a blocked
// store (private mode, disabled site data) simply posts again.
// Fire-and-forget, never blocking UI.

import type { FunnelEventType, MixtapeApi } from '../api/client'

export function funnelFlagKey(type: FunnelEventType, userId: string) {
  return `mixtape:funnel:${type}:${userId}`
}

/** Posts the event unless this user already has; returns whether it posted. */
export function postFunnelEventOnce(
  api: Pick<MixtapeApi, 'postFunnelEvent'>,
  userId: string,
  type: FunnelEventType,
): boolean {
  const key = funnelFlagKey(type, userId)
  try {
    if (window.localStorage.getItem(key)) return false
  } catch {
    // Storage blocked: post anyway.
  }
  void api.postFunnelEvent({ type, surface: 'web' }).then(
    () => {
      try {
        window.localStorage.setItem(key, new Date().toISOString())
      } catch {
        // Storage blocked: nothing to remember.
      }
    },
    () => undefined,
  )
  return true
}

/** Whether this user's post of the event has already landed on this device. */
export function hasPostedFunnelEvent(userId: string, type: FunnelEventType): boolean {
  try {
    return Boolean(window.localStorage.getItem(funnelFlagKey(type, userId)))
  } catch {
    return false
  }
}

export type DeferredFunnel = {
  /** Records the event once; held in memory until flush() has run. */
  record: (type: FunnelEventType) => void
  /** The session now exists: posts what was held, and posts later events at once. */
  flush: () => void
}

/**
 * The first run's events. They start before any session exists, and a
 * session is never created just to post one, so they wait in memory until
 * the listener's first server action has run ensureSession(). The flow
 * lives only while its own anonymous user is being made, so "once" is per
 * flow, kept in memory: a reload with that session goes straight to the
 * shell and never shows the flow again.
 */
export function createDeferredFunnel(api: Pick<MixtapeApi, 'postFunnelEvent'>): DeferredFunnel {
  const seen = new Set<FunnelEventType>()
  const held: FunnelEventType[] = []
  let ready = false
  const post = (type: FunnelEventType) => {
    void Promise.resolve()
      .then(() => api.postFunnelEvent({ type, surface: 'web' }))
      .catch(() => undefined)
  }
  return {
    record(type) {
      if (seen.has(type)) return
      seen.add(type)
      if (ready) post(type)
      else held.push(type)
    },
    flush() {
      ready = true
      for (const type of held.splice(0)) post(type)
    },
  }
}
