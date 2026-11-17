import { createMiddleware } from 'hono/factory'

// DJ_PAUSED (wrangler.jsonc) is the operator's switch; autoPaused is the
// automatic one (dj/auto-pause.ts: Anthropic refused us for billing). Mounted
// on the routes that reach the model; refuses their POSTs before any work so
// the listener gets one calm answer instead of a failed turn. Reads pass, and
// everything that calls no model (playing, playlists, sharing) stays open.
// Clients learn the state from GET /health (djPaused) and from this 503.
export function requireDjOpen(paused: boolean, autoPaused?: () => Promise<boolean>) {
  return createMiddleware(async (c, next) => {
    if (c.req.method === 'POST' && (paused || (autoPaused && (await autoPaused())))) {
      return c.json({ error: 'dj_paused' }, 503)
    }
    await next()
  })
}
