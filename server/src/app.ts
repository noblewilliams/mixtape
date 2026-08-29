import { Hono } from 'hono'
import { requireSession } from './middleware/require-session'
import { requireAdmin } from './middleware/require-admin'
import { ingestRoutes } from './routes/ingest'
import { enrichRoutes } from './routes/enrich'
import { sessionRoutes } from './routes/sessions'
import type { Db } from './db/types'
import type { EnrichDeps } from './enrich/pipeline'
import type { DjDeps } from './dj/loop'

// Minimal structural type so tests can stub auth
export type AuthLike = {
  handler: (req: Request) => Response | Promise<Response>
  api: {
    getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>
  }
}

export type AppVars = { user: { id: string } }

export type EnrichWiring = { deps: EnrichDeps; adminToken: string }
export type DjWiring = { deps: DjDeps }

export function createApp({ auth, db, enrich, dj }: { auth: AuthLike; db?: Db; enrich?: EnrichWiring; dj?: DjWiring }) {
  const app = new Hono<{ Variables: AppVars }>()

  app.onError((err, c) => {
    console.error(err)
    return c.json({ error: 'internal' }, 500)
  })

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  // Route groups land per docs/superpowers/specs/2026-08-29-mixtape-v1-design.md:
  //   /api/auth/* [P1]  /me [P1]  /ingest/* [P1]  /enrich/* [P2 live]  /sessions/* [P3 live]
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))
  app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))

  if (db) {
    app.use('/ingest/*', requireSession(auth))
    app.route('/ingest', ingestRoutes(db))

    if (enrich) {
      app.use('/enrich/*', requireAdmin(enrich.adminToken))
      app.route('/enrich', enrichRoutes(db, enrich.deps))
    }

    if (dj) {
      app.use('/sessions/*', requireSession(auth))
      app.route('/sessions', sessionRoutes(db, dj.deps))
    }
  }

  return app
}
