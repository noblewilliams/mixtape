// The name page (2026-11-02 profile name) is decided by GET /me's askName;
// the client never recomputes it. This only decides whether the workspace
// waits for that answer behind the sign-in image, so an account that will be
// asked never sees the workspace flash first. A session with a usable name is
// never asked; an account this browser already saw settled (answered, or
// /me said no) is not held either, and still gets the page if /me says so.
import { normalizeProfileName } from './profile-name'

type SessionUser = { id: string; name: string; isAnonymous?: boolean }

const key = (userId: string) => `mixtape:name-page-settled:${userId}`

export function mayAskName(user: SessionUser): boolean {
  if (user.isAnonymous) return false
  const name = normalizeProfileName(user.name)
  if (name !== '' && name !== 'Listener') return false
  try {
    return window.localStorage.getItem(key(user.id)) === null
  } catch {
    return true
  }
}

export function markNamePageSettled(userId: string) {
  try {
    window.localStorage.setItem(key(userId), '1')
  } catch {
    // Storage blocked: the next launch waits for /me again.
  }
}
