import { createMiddleware } from 'hono/factory'
import type { AuthLike, AppVars } from '../app'

// Public routes that behave differently for a signed-in caller (spec
// 2026-11-13 shared-mixes: /shared/*). Sets user and sessionId exactly as
// requireSession does when a valid bearer or cookie session is present;
// without one the request goes on with no user, never 401.
export function optionalSession(auth: AuthLike) {
  return createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    // A failed lookup (auth store down) serves the caller as anonymous: the
    // public read must not 500 because an optional session couldn't load.
    const session = await auth.api.getSession({ headers: c.req.raw.headers }).catch(() => null)
    if (session) {
      c.set('user', { ...session.user, isAnonymous: session.user.isAnonymous === true })
      if (session.session?.id) c.set('sessionId', session.session.id)
    }
    await next()
  })
}
