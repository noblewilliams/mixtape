import { createMiddleware } from 'hono/factory'

export function requireAdmin(adminToken: string) {
  return createMiddleware(async (c, next) => {
    const provided = c.req.header('X-Admin-Token')
    if (!adminToken || !provided || provided !== adminToken) return c.json({ error: 'unauthorized' }, 401)
    await next()
  })
}
