import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import { z } from 'zod'
import type { Db } from '../db/types'
import { AppleCatalogError, type AppleCatalogSeedClient } from '../musickit/catalog'
import { APPLE_CATALOG_ID_PATTERN } from '../musickit/apple-id'
import { addCatalogueSongs, type CatalogueQueue } from '../dj/catalogue-fill'
import { runTwinCopy } from '../enrich/twin-copy'
import { MAX_CHART_PAGE, MAX_PLAYLIST_PAGE, MAX_PLAYLIST_SEARCH } from '../enrich/seed-limits'

// The catalogue seed (spec 2026-10-21 everyone-gets-a-mix, step 3), driven
// by scripts/seed-catalogue.ts. Each request makes exactly one Apple call
// and never enriches: new rows join the ordinary backlog for POST
// /enrich/run and the hourly cron. Seeded rows are ordinary Apple catalogue
// rows (artist_source 'apple_catalog'), the same as the prompt-time fill's.
export type EnrichSeedDeps = { catalog: AppleCatalogSeedClient }

export { MAX_CHART_PAGE, MAX_PLAYLIST_PAGE, MAX_PLAYLIST_SEARCH }
const MAX_OFFSET = 100_000

// Normal priority, and a row already held keeps the priority it has.
const SEED_QUEUE: CatalogueQueue = { priority: () => 0, heldFloor: null }

const storefront = z.string().regex(/^[a-z]{2}$/)
const offset = z.number().int().min(0).max(MAX_OFFSET).optional()

export const seedRequestSchema = z.discriminatedUnion('source', [
  z.strictObject({
    storefront,
    source: z.literal('chart'),
    // Null or absent: the overall chart.
    genreId: z.string().regex(/^\d{1,12}$/).nullable().optional(),
    limit: z.number().int().min(1).max(MAX_CHART_PAGE),
    offset,
  }),
  z.strictObject({
    storefront,
    source: z.literal('playlist'),
    playlistId: z.string().regex(APPLE_CATALOG_ID_PATTERN).refine((id) => !/^\.+$/.test(id)),
    limit: z.number().int().min(1).max(MAX_PLAYLIST_PAGE),
    offset,
  }),
])

export const playlistSearchSchema = z.strictObject({
  storefront,
  term: z.string().trim().min(1).max(120),
  limit: z.number().int().min(1).max(MAX_PLAYLIST_SEARCH),
})

export type SeedResponse = { fetched: number; inserted: number; duplicates: number; twins: number; next: number | null }

// 429 tells the script to cool down and retry, and so does 503 for a
// transient Apple failure (upstream, timeout, network). A broken token or an
// unreadable response is 502, which the script treats as a hard stop rather
// than retrying it as a limit. Fixed categories only, never a response body.
function appleFailure(error: unknown): { body: Record<string, string>; status: 429 | 502 | 503 } | null {
  if (!(error instanceof AppleCatalogError)) return null
  if (error.category === 'rate_limit' || error.status === 429) {
    return { body: { error: 'apple_rate_limited' }, status: 429 }
  }
  const status = error.category === 'authorization' || error.category === 'response' ? 502 : 503
  return { body: { error: 'apple_unavailable', category: error.category }, status }
}

export function enrichSeedRoutes(db: Db, deps: EnrichSeedDeps) {
  const app = new Hono()

  app.post('/seed', zValidator('json', seedRequestSchema), async (c) => {
    const body = c.req.valid('json')
    const from = body.offset ?? 0
    let page
    try {
      page = body.source === 'chart'
        ? await deps.catalog.chartSongs(body.storefront, body.genreId ?? null, body.limit, from)
        : await deps.catalog.playlistTracks(body.storefront, body.playlistId, body.limit, from)
    } catch (error) {
      const failure = appleFailure(error)
      if (failure) return c.json(failure.body, failure.status)
      throw error
    }
    const inserted = await addCatalogueSongs(db, page.songs, body.storefront, SEED_QUEUE)
    // Same recording held under another id (a Spotify export's row): its
    // features and meaning are copied now, for free, before the drain.
    const twins = await runTwinCopy(db, inserted.length, inserted)
    const result: SeedResponse = {
      fetched: page.songs.length,
      inserted: inserted.length,
      duplicates: page.songs.length - inserted.length,
      twins: Math.max(twins.features, twins.meanings),
      next: page.next,
    }
    return c.json(result)
  })

  app.post('/seed/playlists', zValidator('json', playlistSearchSchema), async (c) => {
    const body = c.req.valid('json')
    try {
      const playlists = await deps.catalog.searchPlaylists(body.storefront, body.term, body.limit)
      return c.json({ playlists })
    } catch (error) {
      const failure = appleFailure(error)
      if (failure) return c.json(failure.body, failure.status)
      throw error
    }
  })

  return app
}
