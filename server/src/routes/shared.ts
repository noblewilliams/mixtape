import { Hono, type Context } from 'hono'
import type { AppVars, ShareRateLimiter } from '../app'
import type { Db } from '../db/types'
import { findShare, readShare, saveShare, unsaveShare } from '../shares/store'

// The public read of a shared mix and the recipient's save (spec 2026-11-13
// shared-mixes, API table). Mounted behind optionalSession: user is set only
// when the caller has a valid session.
//
// The body is built field by field from the share snapshot and the tracks
// catalogue: never reasons, prompts, messages, energy data, the sharer's
// full name, email or user id (decision 2).

type Vars = { Variables: AppVars }

function caller(c: Context<Vars>): AppVars['user'] | undefined {
  return c.get('user') as AppVars['user'] | undefined
}

export function sharedRoutes(db: Db, limiter: ShareRateLimiter) {
  const app = new Hono<Vars>()

  app.get('/:token', async (c) => {
    // Per IP, before the share read (optionalSession has already looked up a
    // session, and treats a failed lookup as none). Workers always sets CF-Connecting-IP;
    // one shared bucket for requests without it (local tools) is the safe side.
    const ip = c.req.header('CF-Connecting-IP') ?? 'unknown'
    const { success } = await limiter.limit({ key: ip })
    if (!success) return c.json({ error: 'rate_limited' }, 429)

    const read = await readShare(db, c.req.param('token'))
    if (read.kind === 'not_found') return c.json({ error: 'not_found' }, 404)
    if (read.kind === 'revoked') return c.json({ error: 'revoked' }, 410)

    const isOwner = caller(c)?.id === read.share.sharerId
    return c.json({
      token: read.share.token,
      title: read.share.title,
      caseColor: read.share.caseColor,
      sharerName: read.sharerName,
      sharedAt: read.share.createdAt.toISOString(),
      isOwner,
      ...(isOwner ? { sessionId: read.share.sessionId } : {}),
      tracks: read.tracks,
    })
  })

  app.post('/:token/save', async (c) => {
    const user = caller(c)
    if (!user) return c.json({ error: 'unauthorized' }, 401)
    const share = await findShare(db, c.req.param('token'))
    if (!share) return c.json({ error: 'not_found' }, 404)
    if (share.revoked) return c.json({ error: 'revoked' }, 410)
    await saveShare(db, share, user.id)
    return c.body(null, 204)
  })

  // Removing works on a revoked share too, so a dead row can be cleared.
  app.delete('/:token/save', async (c) => {
    const user = caller(c)
    if (!user) return c.json({ error: 'unauthorized' }, 401)
    await unsaveShare(db, c.req.param('token'), user.id)
    return c.body(null, 204)
  })

  return app
}
