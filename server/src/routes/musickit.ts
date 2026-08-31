import { Hono } from 'hono'
import type { AppVars, MusicKitWiring } from '../app'

export function musicKitRoutes({ allowedOrigins, issueDeveloperToken }: MusicKitWiring) {
  const app = new Hono<{ Variables: AppVars }>()
  const allowed = new Set(allowedOrigins)

  app.get('/token', async (c) => {
    const origin = c.req.header('Origin')
    if (!origin || !allowed.has(origin)) return c.json({ error: 'origin_not_allowed' }, 403)

    const result = await issueDeveloperToken(origin)
    c.header('Cache-Control', 'private, no-store')
    return c.json(result)
  })

  return app
}
