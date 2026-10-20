import { createMiddleware } from 'hono/factory'
import type { AuthLike, AppVars } from '../app'

export function requireSession(auth: AuthLike) {
  return createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers })
    if (!session) return c.json({ error: 'unauthorized' }, 401)
    // Normalize once so every route reads a real boolean.
    c.set('user', { ...session.user, isAnonymous: session.user.isAnonymous === true })
    if (session.session?.id) c.set('sessionId', session.session.id)
    await next()
  })
}
