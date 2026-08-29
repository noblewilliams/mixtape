import { Hono } from 'hono'

// Minimal structural type so tests can stub auth
export type AuthLike = {
  handler: (req: Request) => Response | Promise<Response>
  api: {
    getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>
  }
}

export type AppVars = { user: { id: string } }

export function createApp({ auth }: { auth: AuthLike }) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))

  return app
}
