import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { requireSession } from './middleware/require-session'
import { requireAdmin } from './middleware/require-admin'
import { ingestRoutes } from './routes/ingest'
import { enrichRoutes } from './routes/enrich'
import { sessionRoutes } from './routes/sessions'
import { memoriesRoutes } from './routes/memories'
import { musicKitRoutes } from './routes/musickit'
import type { Db } from './db/types'
import type { EnrichDeps } from './enrich/pipeline'
import type { ArtworkDeps } from './artwork/runner'
import type { DjDeps } from './dj/loop'

// Minimal structural type so tests can stub auth
export type AuthLike = {
  handler: (req: Request) => Response | Promise<Response>
  api: {
    getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>
  }
}

export type AppVars = { user: { id: string } }

export type EnrichWiring = { deps?: EnrichDeps; artwork?: ArtworkDeps; adminToken: string }
export type DjWiring = { deps: DjDeps }
export type MusicKitWiring = {
  allowedOrigins: string[]
  issueDeveloperToken: (origin: string) => Promise<{ developerToken: string; expiresAt: number }>
}

export function createApp({
  auth,
  db,
  enrich,
  dj,
  musicKit,
  allowedOrigins = [],
}: {
  auth: AuthLike
  db?: Db
  enrich?: EnrichWiring
  dj?: DjWiring
  musicKit?: MusicKitWiring
  allowedOrigins?: string[]
}) {
  const app = new Hono<{ Variables: AppVars }>()

  app.onError((err, c) => {
    console.error(err)
    return c.json({ error: 'internal' }, 500)
  })

  if (allowedOrigins.length > 0) {
    app.use(
      '*',
      cors({
        origin: allowedOrigins,
        allowHeaders: ['Authorization', 'Content-Type'],
        allowMethods: ['GET', 'HEAD', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
        credentials: true,
        maxAge: 600,
      }),
    )
  }

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  // Route groups land per docs/superpowers/specs/2026-08-29-mixtape-v1-design.md:
  //   /api/auth/* [P1]  /me [P1]  /ingest/* [P1]  /enrich/* [P2 live]  /sessions/* [P3 live]
  //   /me/memories/* [P4 live]
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))
  app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))

  if (musicKit) {
    app.use('/musickit/*', requireSession(auth))
    app.route('/musickit', musicKitRoutes(musicKit))
  }

  if (db) {
    app.use('/ingest/*', requireSession(auth))
    app.route('/ingest', ingestRoutes(db))

    app.use('/me/memories/*', requireSession(auth))
    app.route('/me/memories', memoriesRoutes(db))

    if (enrich && (enrich.deps || enrich.artwork)) {
      app.use('/enrich/*', requireAdmin(enrich.adminToken))
      app.route('/enrich', enrichRoutes(db, enrich))
    }

    if (dj) {
      app.use('/sessions/*', requireSession(auth))
      app.route('/sessions', sessionRoutes(db, dj.deps))
    }
  }

  return app
}
