import { Hono } from 'hono'

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  ANTHROPIC_API_KEY: string
}

const app = new Hono<{ Bindings: Bindings }>()

app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))

// Route groups land per the v1 design spec (docs/superpowers/specs/2026-08-29-mixtape-v1-design.md):
//   /auth/*     — Better Auth (Sign in with Apple)        [P1]
//   /ingest/*   — library / play counts / recents intake  [P1]
//   /enrich/*   — enrichment waterfall internals          [P2]
//   /sessions/* — prompt → queue, refine, history, convert [P3–P4]

export default app
