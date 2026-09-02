import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { HTTPException } from 'hono/http-exception'
import { requireSession } from './middleware/require-session'
import { requireAdmin } from './middleware/require-admin'
import { ingestRoutes } from './routes/ingest'
import { libraryIngestRoutes } from './routes/library-ingest'
import { listeningIngestRoutes } from './routes/listening-ingest'
import { playlistIngestRoutes } from './routes/playlist-ingest'
import { playlistsRoutes } from './routes/playlists'
import { enrichRoutes } from './routes/enrich'
import { sessionRoutes } from './routes/sessions'
import { memoriesRoutes } from './routes/memories'
import { musicSourcesRoutes } from './routes/music-sources'
import { onboardingRoutes } from './routes/onboarding'
import { artistSeedsRoutes } from './routes/artist-seeds'
import { seedTracksRoutes, type SeedsWiring } from './routes/seed-tracks'
import { interviewRoutes } from './routes/interview'
import { funnelEventsRoutes } from './routes/funnel-events'
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
export type { SeedsWiring }
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
  seeds,
  allowedOrigins = [],
}: {
  auth: AuthLike
  db?: Db
  enrich?: EnrichWiring
  dj?: DjWiring
  musicKit?: MusicKitWiring
  seeds?: SeedsWiring
  allowedOrigins?: string[]
}) {
  const app = new Hono<{ Variables: AppVars }>()

  app.onError((err, c) => {
    // Hono's own request errors (a body that is not JSON under an
    // application/json content type, for one) already carry the right status
    // and a fixed message: hand them back rather than turning a caller's
    // mistake into a 500.
    // Hono's own request rejections (malformed JSON, validator failures)
    // keep their status but take the app's JSON envelope so clients parse
    // one error shape everywhere.
    if (err instanceof HTTPException) return c.json({ error: 'invalid_request' }, err.status)
    // Request errors may wrap upstream response bodies, user input, or
    // credentials. Keep production logs useful as a failure signal without
    // serializing the error object itself.
    console.error('app request failed')
    return c.json({ error: 'internal' }, 500)
  })

  if (allowedOrigins.length > 0) {
    app.use(
      '*',
      cors({
        origin: allowedOrigins,
        allowHeaders: ['Authorization', 'Content-Type'],
        allowMethods: ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
        credentials: true,
        maxAge: 600,
      }),
    )
  }

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  // Route groups land per docs/superpowers/specs/2026-08-29-mixtape-v1-design.md:
  //   /api/auth/* [P1]  /me [P1]  /ingest/* [P1]  /enrich/* [P2 live]  /sessions/* [P3 live]
  //   /me/memories/* [P4 live]  /me/music-sources  /me/onboarding [listening import]
  //   /me/artist-seeds  /me/seed-tracks/*  /me/interview  /me/funnel-events [taste seeds]
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))
  app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))

  if (musicKit) {
    app.use('/musickit/*', requireSession(auth))
    app.route('/musickit', musicKitRoutes(musicKit))
  }

  if (db) {
    app.use('/ingest/*', requireSession(auth))
    app.route('/ingest', ingestRoutes(db))
    app.route('/ingest', libraryIngestRoutes(db))
    app.route('/ingest', playlistIngestRoutes(db))
    app.route('/ingest', listeningIngestRoutes(db))

    app.use('/playlists', requireSession(auth))
    app.use('/playlists/*', requireSession(auth))
    app.route('/playlists', playlistsRoutes(db))

    app.use('/me/memories/*', requireSession(auth))
    app.route('/me/memories', memoriesRoutes(db))

    app.use('/me/music-sources/*', requireSession(auth))
    app.route('/me/music-sources', musicSourcesRoutes(db))

    app.use('/me/onboarding/*', requireSession(auth))
    app.route('/me/onboarding', onboardingRoutes(db))

    app.use('/me/artist-seeds/*', requireSession(auth))
    app.route('/me/artist-seeds', artistSeedsRoutes(db))

    app.use('/me/seed-tracks/*', requireSession(auth))
    app.route('/me/seed-tracks', seedTracksRoutes(db, seeds))

    app.use('/me/interview/*', requireSession(auth))
    app.route('/me/interview', interviewRoutes(db))

    app.use('/me/funnel-events/*', requireSession(auth))
    app.route('/me/funnel-events', funnelEventsRoutes(db))

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
