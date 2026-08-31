import { createMiddleware } from 'hono/factory'
import { createHash, timingSafeEqual } from 'node:crypto'

export function requireAdmin(adminToken: string) {
  // Hashing makes both operands a fixed length before timingSafeEqual. The
  // node:crypto surface is available in Workers through nodejs_compat.
  const expectedDigest = createHash('sha256').update(adminToken, 'utf8').digest()

  return createMiddleware(async (c, next) => {
    const provided = c.req.header('X-Admin-Token')
    if (!adminToken || !provided) return c.json({ error: 'unauthorized' }, 401)
    const providedDigest = createHash('sha256').update(provided, 'utf8').digest()
    if (!timingSafeEqual(providedDigest, expectedDigest)) return c.json({ error: 'unauthorized' }, 401)
    await next()
  })
}
