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
