import { createMiddleware } from 'hono/factory'
import type { AuthLike, AppVars } from '../app'

export function requireSession(auth: AuthLike) {
  return createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers })
    if (!session) return c.json({ error: 'unauthorized' }, 401)
    c.set('user', session.user)
    await next()
  })
}
