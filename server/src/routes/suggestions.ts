import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  readSuggestions,
  saveSuggestionPreference,
  dismissSuggestion,
} from '../suggestions/store'
const zone = z
  .string()
  .min(1)
  .max(100)
  .refine((value) => {
    try {
      new Intl.DateTimeFormat('en', { timeZone: value })
      return true
    } catch {
      return false
    }
  })
const selection = z
  .object({
    timeZone: zone,
    id: z.string().regex(/^[0-6]-[0-3]-(rise|fall|arc|steady)$/),
  })
  .strict()
export function suggestionRoutes(db: Db, clock = () => new Date()) {
  const app = new Hono<{ Variables: AppVars }>()
  app.onError((_, c) => c.json({ error: 'suggestions_unavailable' }, 500))
  app.get('/', zValidator('query', z.object({ timeZone: zone })), async (c) =>
    c.json(
      await readSuggestions(
        db,
        c.get('user').id,
        c.req.valid('query').timeZone,
        clock(),
      ),
    ),
  )
  app.post(
    '/preferences',
    zValidator('json', z.object({ enabled: z.boolean() }).strict()),
    async (c) =>
      c.json(
        await saveSuggestionPreference(
          db,
          c.get('user').id,
          c.req.valid('json').enabled,
        ),
      ),
  )
  app.post('/dismiss', zValidator('json', selection), async (c) => {
    await dismissSuggestion(
      db,
      c.get('user').id,
      c.req.valid('json').id,
      clock(),
    )
    return c.json({ ok: true })
  })
  app.post('/select', zValidator('json', selection), async (c) => {
    const { id, timeZone } = c.req.valid('json')
    const current = await readSuggestions(
      db,
      c.get('user').id,
      timeZone,
      clock(),
    )
    if (current.suggestion?.id !== id)
      return c.json({ error: 'suggestion_expired' }, 409)
    return c.json({ prompt: current.suggestion.prompt })
  })
  return app
}
