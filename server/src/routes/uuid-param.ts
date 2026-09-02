import type { Env } from 'hono'
import { z } from 'zod'
import { zValidator, type Hook } from '@hono/zod-validator'

// Staging-run ids (library syncs, playlist syncs, listening imports) are uuid
// columns. A malformed path segment must resolve to the same 404 as a run the
// caller cannot see: never a raw Postgres uuid error, and not a zod 400 either,
// which would let a client tell "not an id" apart from "not your run". One
// convention across all three staging protocols, so a single client helper
// covers them. The hook never reads app variables, so it is typed on Hono's
// base Env, which is what a standalone zValidator infers.
export function uuidParam<Name extends string>(name: Name) {
  const schema = z.object({ [name]: z.string().uuid() } as { [K in Name]: z.ZodString })
  const notFoundOnMalformed: Hook<z.infer<typeof schema>, Env, string, 'param'> = (result, c) => {
    if (!result.success) return c.json({ error: 'not_found' }, 404)
  }
  return zValidator('param', schema, notFoundOnMalformed)
}
