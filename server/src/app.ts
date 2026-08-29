import { Hono } from 'hono'
import { requireSession } from './middleware/require-session'

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

  app.onError((err, c) => {
    console.error(err)
    return c.json({ error: 'internal' }, 500)
  })

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  // Route groups land per docs/superpowers/specs/2026-08-29-mixtape-v1-design.md:
  //   /api/auth/* [P1]  /ingest/* [P1]  /enrich/* [P2]  /sessions/* [P3-P4]
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))
  app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))

  return app
}
