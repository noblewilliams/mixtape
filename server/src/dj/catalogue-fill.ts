import { sql, type SQL } from 'drizzle-orm'
import type { Db } from '../db/types'
import { tracks } from '../db/schema'
import {
  AppleCatalogError,
  type AppleCatalogArtistClient,
  type AppleCatalogSearchClient,
  type CatalogSong,
} from '../musickit/catalog'
import { catalogTrackValue } from '../playlist-editing/catalog'
import { enrichTrack, type EnrichDeps } from '../enrich/pipeline'
import { runTwinCopy } from '../enrich/twin-copy'
import { dueTracks, FRONT_OF_QUEUE_PRIORITY, type DueTrack } from '../enrich/runner'
import { failureExhausted } from '../enrich/failures'
import { artistKey, creditedKeys } from './artist-keys'
import type { NamedSong } from './contracts'

// Fill from Apple at prompt time (spec 2026-10-21 everyone-gets-a-mix, step
// 2). A seed artist with fewer than FILL_FLOOR enriched catalogue rows gets
// up to FILL_PER_ARTIST of Apple's top songs added as ordinary catalogue
// rows, and as many of them as FILL_BUDGET subrequests allow are enriched in
// the same request. The rest wait at the front of the enrichment queue for
// the hourly cron and the next prompt.
export const FILL_FLOOR = 12
export const FILL_PER_ARTIST = 10
// A turn with two curation calls plus database reconnects has reached the
// free plan's 50 subrequests with 24 here.
export const FILL_BUDGET = 20
// Measured from the start of fillForSeeds and checked before every Apple
// call and every row: the iOS client gives up at 120 s and the model calls
// still have to run after the fill.
export const FILL_DEADLINE_MS = 12_000
// Filled rows this request does not enrich wait ahead of ordinary backlog
// (an import's pool candidates sit at 1 + a recent play count) without
// claiming the front of the queue, which is kept for the rows enriched
// in-line (FRONT_OF_QUEUE_PRIORITY, enrich/runner.ts).
export const FILL_QUEUE_BOOST = 1_000
// Apple lookups per turn. Each artist costs 2 subrequests and each song 1;
// without a cap a long seed list would spend the whole budget on Apple and
// leave nothing to enrich with, and unenriched rows do not count toward
// the floor.
export const FILL_MAX_ARTISTS = 3
export const FILL_MAX_SONGS = 3
// Apple ranks the right artist first nearly always; a few more candidates
// let the key match skip a similarly named one ("Jay Electronica").
const ARTIST_SEARCH_LIMIT = 5
const SONG_SEARCH_LIMIT = 5
// Due rows read for enrichment; the budget runs out well before this.
const ENRICH_CANDIDATES = 60

// Worst-case subrequests per call. ReccoBeats is a search then an
// audio-features fetch (enrich/reccobeats.ts); LRCLIB is an exact get then a
// search fallback (enrich/lrclib.ts). A row is only started when its worst
// case fits what is left, so the budget is never exceeded.
export const STAGE_SUBREQUESTS = { apple: 1, itunes: 1, features: 2, lyrics: 2, embed: 1 } as const

export type FillDeps = {
  catalog: AppleCatalogArtistClient & AppleCatalogSearchClient
  enrich: EnrichDeps
  // For a listener whose profile names no storefront.
  defaultStorefront: string
  // Fetches made so far through enrich.features and enrich.lyrics, when the
  // caller can count them (index.ts does). Those two stages are then charged
  // what they actually fetched; without it, their worst case.
  enrichFetches?: () => number
  // Milliseconds, for the deadline; Date.now when absent.
  now?: () => number
}

export type FillOptions = {
  userId: string
  // Overrides the listener's own storefront (profile, else the default).
  storefront?: string
  namedSongs?: NamedSong[]
  budget?: number
  // false inserts and queues the rows (twin copy included) but enriches none
  // in this request: the never-refuse path (dj/propose.ts) spends the turn's
  // subrequests on Apple searches instead. Absent is true.
  enrich?: boolean
}

export type FillResult = {
  inserted: number
  enriched: number
  // New rows that took features or meaning from an ISRC twin, for free.
  twins: number
  subrequests: number
  // Seed names whose artist was found and whose top songs were added. Not
  // logged: the loop logs counts only.
  artists: string[]
  // The last Apple failure's category, when one happened.
  appleError?: string
  // Set when FILL_DEADLINE_MS stopped the fill early.
  timedOut?: true
}

type ThinSeed = { name: string; key: string; needsApple: boolean }
type FillPlan = { personal: boolean; storefront: string | null; thin: ThinSeed[] }

function rowsOf(res: unknown): Record<string, unknown>[] {
  if (Array.isArray(res)) return res as Record<string, unknown>[]
  const rows = (res as { rows?: unknown } | null | undefined)?.rows
  return Array.isArray(rows) ? (rows as Record<string, unknown>[]) : []
}

const truthy = (v: unknown): boolean => v === true || v === 't' || v === 'true'
const STOREFRONT = /^[a-z]{2}$/

// One query: whether the listener is personal (resolvePoolMode's rule: a
// landed import or any library row), their storefront, and each seed key
// with fewer than FILL_FLOOR enriched rows, newest seed first so the artists
// this prompt named are filled before older ones. A seed needs Apple only
// while the catalogue holds fewer than FILL_FLOOR live rows for it in all
// and fewer than FILL_PER_ARTIST live Apple rows (an earlier fill's rows
// waiting for enrichment need no second lookup). A live row is enriched or
// can still be; one with an exhausted stage and nothing enriched is not.
async function readFillPlan(db: Db, userId: string): Promise<FillPlan> {
  const [row] = rowsOf(await db.execute(sql`
    WITH seeds AS (
      SELECT DISTINCT ON (artist_key(s.name)) s.name, artist_key(s.name) AS key, s.created_at
      FROM user_artist_seeds s
      WHERE s.user_id = ${userId} AND artist_key(s.name) <> ''
      ORDER BY artist_key(s.name), s.created_at, s.name
    ), counted AS (
      SELECT s.name, s.key, s.created_at,
        COUNT(t.id) FILTER (WHERE t.live)::int AS total,
        COUNT(t.id) FILTER (WHERE t.live AND t.apple_id IS NOT NULL)::int AS apple,
        COUNT(t.id) FILTER (WHERE t.enriched)::int AS enriched
      FROM seeds s
      LEFT JOIN LATERAL (
        -- A row counts while it is enriched or can still be: an unenriched
        -- row with a stage whose attempts are exhausted will never reach the
        -- pool, so it must not stand in for a fill.
        SELECT x.id, x.apple_id, x.enriched,
          x.enriched OR NOT (${failureExhausted('ff')} OR ${failureExhausted('fm')}) AS live
        FROM (
          SELECT t.id, t.apple_id,
            EXISTS (SELECT 1 FROM track_features f WHERE f.track_id = t.id)
              OR EXISTS (SELECT 1 FROM track_meanings m WHERE m.track_id = t.id) AS enriched
          FROM tracks t
          WHERE t.artist_keys @> ARRAY[s.key]
        ) x
        LEFT JOIN enrichment_failures ff ON ff.track_id = x.id AND ff.stage = 'features'
        LEFT JOIN enrichment_failures fm ON fm.track_id = x.id AND fm.stage = 'meaning'
      ) t ON true
      GROUP BY s.name, s.key, s.created_at
    )
    SELECT
      (EXISTS (SELECT 1 FROM user_music_sources WHERE user_id = ${userId} AND last_imported_at IS NOT NULL)
        OR EXISTS (SELECT 1 FROM user_tracks WHERE user_id = ${userId} AND in_library = true)) AS personal,
      (SELECT coalesce(p.apple_storefront, lower(p.country)) FROM user_music_profiles p WHERE p.user_id = ${userId}) AS storefront,
      coalesce((
        SELECT json_agg(json_build_object(
          'name', c.name, 'key', c.key,
          'needsApple', c.total < ${FILL_FLOOR} AND c.apple < ${FILL_PER_ARTIST}
        ) ORDER BY c.created_at DESC, c.name)
        FROM counted c WHERE c.enriched < ${FILL_FLOOR}
      ), '[]'::json) AS thin
  `))
  const thinRaw = typeof row.thin === 'string' ? JSON.parse(row.thin) : row.thin
  const storefront = typeof row.storefront === 'string' && STOREFRONT.test(row.storefront) ? row.storefront : null
  return {
    personal: truthy(row.personal),
    storefront,
    thin: (thinRaw as { name: string; key: string; needsApple: unknown }[])
      .map((s) => ({ name: s.name, key: s.key, needsApple: truthy(s.needsApple) })),
  }
}

const upperIsrc = (isrc: string | null | undefined): string | null => (isrc ? isrc.trim().toUpperCase() || null : null)

// How addCatalogueSongs queues what it touches. The fill's default puts new
// rows ahead of ordinary backlog in the order given and raises held rows to
// the same boost; the catalogue seed (routes/enrich-seed.ts) inserts at
// normal priority and leaves held rows alone.
export type CatalogueQueue = {
  // Priority for the new row at rank (0-based) among total songs.
  priority: (rank: number, total: number) => number
  // Floor raised onto held rows, or null to leave them as they are.
  heldFloor: number | null
}

const FILL_QUEUE: CatalogueQueue = {
  // Top songs first within the fill.
  priority: (rank, total) => FILL_QUEUE_BOOST + (total - rank),
  heldFloor: FILL_QUEUE_BOOST,
}

// Inserts the songs the catalogue does not hold yet and queues them (the
// fill's default: every one of them, new or already held, ahead of
// ordinary backlog in the order given). Dedupe is by ISRC, then Apple id: within the list, and
// against rows that already carry an Apple id (the same Apple recording,
// perhaps under another id). A row with the same ISRC and no Apple id (a
// Spotify export's row) is a peer identity, not a duplicate (schema.ts,
// tracks.spotify_id): the Apple row is added and twin copy fills it.
// Returns the new rows' ids.
export async function addCatalogueSongs(
  db: Db,
  found: CatalogSong[],
  storefront: string,
  queue: CatalogueQueue = FILL_QUEUE,
): Promise<string[]> {
  const songs: CatalogSong[] = []
  const seenIsrc = new Set<string>()
  const seenApple = new Set<string>()
  for (const song of found) {
    const isrc = upperIsrc(song.isrc)
    if ((isrc && seenIsrc.has(isrc)) || seenApple.has(song.appleId)) continue
    if (isrc) seenIsrc.add(isrc)
    seenApple.add(song.appleId)
    songs.push(song)
  }
  if (songs.length === 0) return []

  const appleIds = songs.map((s) => s.appleId)
  const isrcs = songs.flatMap((s) => (upperIsrc(s.isrc) ? [upperIsrc(s.isrc)!] : []))
  const list = (values: string[]): SQL => sql.join(values.map((v) => sql`${v}`), sql`, `)
  const matchHeld = sql`(t.apple_id IN (${list(appleIds)})${isrcs.length > 0
    ? sql` OR (t.apple_id IS NOT NULL AND upper(t.isrc) IN (${list(isrcs)}))`
    : sql``})`
  const held = rowsOf(await db.execute(sql`SELECT t.apple_id, upper(t.isrc) AS isrc FROM tracks t WHERE ${matchHeld}`))
  const heldApple = new Set(held.map((r) => String(r.apple_id)))
  const heldIsrc = new Set(held.flatMap((r) => (r.isrc ? [String(r.isrc)] : [])))

  let inserted: string[] = []
  const fresh = songs
    .map((song, rank) => ({ song, rank }))
    .filter(({ song }) => !heldApple.has(song.appleId) && !(upperIsrc(song.isrc) && heldIsrc.has(upperIsrc(song.isrc)!)))
  if (fresh.length > 0) {
    const rows = await db
      .insert(tracks)
      .values(fresh.map(({ song, rank }) => ({
        ...catalogTrackValue(song, storefront),
        enrichPriority: queue.priority(rank, songs.length),
      })))
      .onConflictDoNothing()
      .returning({ id: tracks.id })
    inserted = rows.map((r) => r.id)
  }
  if (held.length > 0 && queue.heldFloor !== null) {
    await db.execute(sql`
      UPDATE tracks t SET enrich_priority = GREATEST(t.enrich_priority, ${queue.heldFloor})
      WHERE ${matchHeld}`)
  }
  return inserted
}

function appleErrorCategory(e: unknown): string {
  return e instanceof AppleCatalogError ? e.category : 'internal'
}

function isRateLimit(e: unknown): boolean {
  return e instanceof AppleCatalogError && (e.category === 'rate_limit' || e.status === 429)
}

// Worst case for one row, per the stages enrichTrack will run on it.
function worstCase({ track, skip }: DueTrack): number {
  const itunes = track.appleId && (track.durationMs == null || track.genre == null) ? STAGE_SUBREQUESTS.itunes : 0
  const features = skip.features ? 0 : STAGE_SUBREQUESTS.features
  const meaning = skip.meaning ? 0 : STAGE_SUBREQUESTS.lyrics + STAGE_SUBREQUESTS.embed
  return itunes + features + meaning
}

// Named songs' rows first, then one row per seed in turn, so a short budget
// spreads across the artists (the floor wants at least two).
function interleave(due: DueTrack[], keys: string[], namedIds: Set<string>): DueTrack[] {
  const named = due.filter((d) => namedIds.has(d.track.id))
  const byKey = new Map(keys.map((k) => [k, [] as DueTrack[]]))
  for (const d of due) {
    if (namedIds.has(d.track.id)) continue
    const key = d.track.artistKeys.find((k) => byKey.has(k))
    if (key) byKey.get(key)!.push(d)
  }
  const out = [...named]
  const queues = [...byKey.values()]
  for (let i = 0; queues.some((q) => i < q.length); i++) {
    for (const q of queues) if (i < q.length) out.push(q[i])
  }
  return out
}

export async function fillForSeeds(db: Db, deps: FillDeps, options: FillOptions): Promise<FillResult> {
  const budget = options.budget ?? FILL_BUDGET
  const result: FillResult = { inserted: 0, enriched: 0, twins: 0, subrequests: 0, artists: [] }
  const left = () => budget - result.subrequests
  const now = deps.now ?? Date.now
  const started = now()
  const expired = (): boolean => {
    if (now() - started <= FILL_DEADLINE_MS) return false
    result.timedOut = true
    return true
  }

  const plan = await readFillPlan(db, options.userId)
  // Never for a personal listener: their mix comes from their own music.
  if (plan.personal) return result
  const storefront = options.storefront ?? plan.storefront ?? deps.defaultStorefront

  let appleStopped = false
  const apple = async <T>(call: () => Promise<T>): Promise<T | null> => {
    if (appleStopped || left() < STAGE_SUBREQUESTS.apple || expired()) return null
    result.subrequests += STAGE_SUBREQUESTS.apple
    try {
      return await call()
    } catch (e) {
      result.appleError = appleErrorCategory(e)
      // A 429 stops every further Apple call this turn.
      if (isRateLimit(e)) appleStopped = true
      return null
    }
  }

  const newIds: string[] = []
  let artistsTried = 0
  for (const seed of plan.thin) {
    if (!seed.needsApple || artistsTried >= FILL_MAX_ARTISTS) continue
    // Both calls or neither: a search with no budget left for the top songs
    // buys nothing.
    if (appleStopped || left() < 2 * STAGE_SUBREQUESTS.apple || expired()) break
    artistsTried += 1
    const found = await apple(() => deps.catalog.searchArtists(storefront, seed.name, ARTIST_SEARCH_LIMIT))
    const artist = found?.find((a) => artistKey(a.name) === seed.key)
    if (!artist) continue
    const songs = await apple(() => deps.catalog.artistTopSongs(storefront, artist.id, FILL_PER_ARTIST))
    if (!songs) continue
    const ids = await addCatalogueSongs(db, songs.slice(0, FILL_PER_ARTIST), storefront)
    newIds.push(...ids)
    result.artists.push(seed.name)
  }

  const namedIds = new Set<string>()
  for (const named of (options.namedSongs ?? []).slice(0, FILL_MAX_SONGS)) {
    const titleKey = artistKey(named.title)
    if (titleKey === '') continue
    const wantArtist = named.artist ? artistKey(named.artist) : ''
    const term = [named.title, named.artist ?? ''].join(' ').trim()
    const found = await apple(() => deps.catalog.searchSongs(storefront, term, SONG_SEARCH_LIMIT))
    if (!found) continue
    // The same title by another artist is a different song (a cover), so a
    // named artist must be among the credits.
    const song = found.find((s) => artistKey(s.title) === titleKey
      && (wantArtist === '' || creditedKeys(s.artist).includes(wantArtist)))
    if (!song) continue
    const ids = await addCatalogueSongs(db, [song], storefront)
    newIds.push(...ids)
    // Held already: still enriched first if it is due.
    const [row] = rowsOf(await db.execute(sql`SELECT id FROM tracks WHERE apple_id = ${song.appleId}`))
    if (row) namedIds.add(String(row.id))
  }
  result.inserted = newIds.length

  // Same recording under another id: features and meaning for free.
  const twins = await runTwinCopy(db, newIds.length, newIds)
  result.twins = Math.max(twins.features, twins.meanings)

  if (options.enrich === false) return result
  const keys = plan.thin.map((s) => s.key)
  if (keys.length === 0 && namedIds.size === 0) return result
  const filters: SQL[] = []
  if (keys.length > 0) filters.push(sql`t.artist_keys && ARRAY[${sql.join(keys.map((k) => sql`${k}`), sql`, `)}]::text[]`)
  if (namedIds.size > 0) filters.push(sql`t.id IN (${sql.join([...namedIds].map((id) => sql`${id}::uuid`), sql`, `)})`)
  const due = interleave(await dueTracks(db, ENRICH_CANDIDATES, sql.join(filters, sql` OR `)), keys, namedIds)

  // Charged per call: Apple and the AI binding at one each; ReccoBeats and
  // LRCLIB at what they fetched when the caller counts, else their worst
  // case. No Spotify-id lookups: a held Spotify export row matching a seed
  // takes the ReccoBeats search like any other, so every call is counted.
  const charged = <A, R>(stage: 'features' | 'lyrics', fn: (arg: A) => Promise<R>) => async (arg: A): Promise<R> => {
    const before = deps.enrichFetches?.()
    try {
      return await fn(arg)
    } finally {
      result.subrequests += before === undefined ? STAGE_SUBREQUESTS[stage] : deps.enrichFetches!() - before
    }
  }
  const enrichDeps: EnrichDeps = {
    ...deps.enrich,
    spotify: undefined,
    itunes: async (appleId, sf) => {
      result.subrequests += STAGE_SUBREQUESTS.itunes
      return deps.enrich.itunes(appleId, sf)
    },
    features: charged('features', deps.enrich.features),
    lyrics: charged('lyrics', deps.enrich.lyrics),
    embed: async (text) => {
      result.subrequests += STAGE_SUBREQUESTS.embed
      return deps.enrich.embed(text)
    },
  }

  // A row enriched in-line holds the front of the queue only while this
  // request works on it: if any stage fails it falls back to the backlog
  // (priority 0), so failed fill rows never starve the hourly job.
  const backToBacklog = (id: string) => db.execute(sql`
    UPDATE tracks SET enrich_priority = 0 WHERE id = ${id}::uuid AND enrich_priority >= ${FRONT_OF_QUEUE_PRIORITY}`)
  const settled = (o: string) => o === 'ok' || o === 'skipped'
  for (const row of due) {
    if (worstCase(row) > left() || expired()) break
    try {
      await db.execute(sql`UPDATE tracks SET enrich_priority = ${FRONT_OF_QUEUE_PRIORITY} WHERE id = ${row.track.id}::uuid`)
      const outcome = await enrichTrack(db, enrichDeps, row.track, row.skip)
      if (outcome.features === 'ok' || outcome.meaning === 'ok') result.enriched += 1
      if (!settled(outcome.features) || !settled(outcome.meaning)) await backToBacklog(row.track.id)
    } catch {
      // enrichTrack records each stage's provider failure itself (its
      // recordFailure); anything that still escapes (a database error)
      // leaves the row queued and the turn goes on.
      await backToBacklog(row.track.id).catch(() => undefined)
    }
  }
  return result
}
