/**
 * propose-first-spike — Step 0 of spec 2026-11-16 propose-first (plan task
 * S0). Measures, before anything is built:
 *
 *  1. Free feature coverage: a stratified sample of catalogue ISRCs from
 *     `tracks`, run through ReccoBeats (enrich/reccobeats.ts), then Deezer
 *     by ISRC for ReccoBeats misses. Hit rate, latency, 429s, bpm = 0.
 *  2. Proposal quality for library listeners: the founder account (largest
 *     library) and the Exportify test account, each sent PROMPTS through
 *     proposeSongs (listener 'personal', top artists) with the real
 *     Anthropic client. Verification is reimplemented READ-ONLY: Apple
 *     catalogue search plus pickHit, never verifyProposals (it inserts
 *     catalogue rows). Verify rate, version suspicion, share already owned,
 *     tokens per call.
 *  3. Estimate error: the proposal prompt is varied for this spike only (the
 *     system prompt's output block is swapped by a wrapping LLM client, so
 *     propose.ts is untouched) to ask for per-song energy and valence; the
 *     estimates are compared with ReccoBeats' measured values for verified
 *     proposals.
 *
 * Usage (from server/):  npx tsx scripts/propose-first-spike.ts
 *   [--catalogue 500] [--proposals 200] [--reuse <raw.json>] [--raw <raw.json>]
 *   [--report ../docs/testing/2026-11-16-propose-first-spike.md]
 * Loads DATABASE_URL, ANTHROPIC_API_KEY, APPLE_TEAM_ID, MUSICKIT_KEY_ID and
 * MUSICKIT_PRIVATE_KEY from .dev.vars (neon-http, the one-off script
 * driver). DATABASE_URL is production: this script only ever SELECTs.
 * Prints and writes counts, titles and artists only: never ids, emails,
 * tokens or keys. --reuse skips phases whose results are already in that
 * raw file (proposals, then lookups), so a crash does not spend twice.
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { neon, type NeonQueryFunction } from '@neondatabase/serverless'
import { artistKey } from '../src/dj/artist-keys'
import type { Intent } from '../src/dj/contracts'
import { anthropicLlm, buildAnthropic, type LlmClient } from '../src/dj/llm'
import { isAlbumGlue } from '../src/dj/pool'
import { pickHit, proposeSongs, titleKey, type Proposal } from '../src/dj/propose'
import { resolveAndFetchFeatures, type AudioFeatures } from '../src/enrich/reccobeats'
import { EnrichSourceError } from '../src/enrich/types'
import { AppleCatalogError, createAppleCatalogClient, type CatalogSong } from '../src/musickit/catalog'
import { generateMusicKitDeveloperToken } from '../src/musickit/token'
import { loadDevVars } from './lib/dev-vars'

// ---------- arguments ----------

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : fallback
}
const CATALOGUE_N = Number(arg('catalogue', '500'))
const PROPOSAL_ISRC_N = Number(arg('proposals', '200'))
const RAW_PATH = resolve(arg('raw', join(tmpdir(), 'propose-first-spike.raw.json'))!)
const REUSE_PATH = arg('reuse')
const REPORT_PATH = resolve(arg('report', new URL('../../docs/testing/2026-11-16-propose-first-spike.md', import.meta.url).pathname)!)

// ---------- pacing ----------

const RECCO_GAP_MS = 1000 // between track lookups (a lookup is search + features: up to 2 requests)
const RECCO_429_WAIT_MS = 30_000
const DEEZER_GAP_MS = 150 // Deezer allows 50 requests / 5 s
const APPLE_CONCURRENCY = 4
const APPLE_GAP_MS = 300
const LLM_CONCURRENCY = 3
const SEARCH_LIMIT = 5
const MAX_TERM_LENGTH = 120

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ---------- prompts (2026-11-09 pressure test, plus mainstream briefs) ----------

type Brief = { brief: string; mainstream: boolean; intent: Partial<Intent> & { themes: string } }

const PROMPTS: Brief[] = [
  // Mainstream: popular songs any well-known artist set would cover.
  { brief: 'upbeat pop for a sunday morning clean-up', mainstream: true, intent: { themes: 'upbeat feel-good pop, sunny, sing-along', energyArc: 'steady', genres: ['pop'] } },
  { brief: '2000s hip hop party bangers', mainstream: true, intent: { themes: 'party, club, hype hip hop', energyArc: 'rise', eraFrom: 2000, eraTo: 2009, genres: ['hip-hop/rap'] } },
  { brief: 'afrobeats for a friday night out', mainstream: true, intent: { themes: 'afrobeats, dance, night out', energyArc: 'rise', genres: ['afrobeats'] } },
  { brief: 'feel-good throwbacks for a road trip', mainstream: true, intent: { themes: 'nostalgic sing-along classics, open road', energyArc: 'arc' } },
  { brief: 'workout mix, high energy rap and pop', mainstream: true, intent: { themes: 'gym, high energy, motivation', energyArc: 'rise', tempoMin: 115 } },
  { brief: 'Frank Ocean and Daniel Caesar', mainstream: true, intent: { themes: 'alternative r&b, introspective, warm', energyArc: 'steady', namedArtists: ['Frank Ocean', 'Daniel Caesar'] } },
  { brief: 'classic rock anthems', mainstream: true, intent: { themes: 'stadium rock anthems, guitars', energyArc: 'arc', genres: ['rock'] } },
  { brief: 'chill r&b for a late night drive', mainstream: true, intent: { themes: 'smooth late night r&b, mellow', energyArc: 'steady', genres: ['r&b/soul'] } },
  // Genre, era and constraint briefs (the pressure test's failures and their kin).
  { brief: '90s r&b slow jams for a dinner date', mainstream: false, intent: { themes: 'romantic slow jams, sensual, dinner', energyArc: 'steady', eraFrom: 1990, eraTo: 1999, genres: ['r&b/soul'] } },
  { brief: 'rainy sunday reading, soft jazz', mainstream: false, intent: { themes: 'soft jazz, rain, reading, calm', energyArc: 'steady', genres: ['jazz'] } },
  { brief: 'focus music, no vocals', mainstream: false, intent: { themes: 'instrumental focus, no vocals, steady', energyArc: 'steady' } },
  { brief: '80s synth-pop deep cuts', mainstream: false, intent: { themes: 'synth-pop, new wave, lesser-known album tracks', energyArc: 'arc', eraFrom: 1980, eraTo: 1989, familiarity: 'adventurous' } },
  { brief: 'old-school highlife classics', mainstream: false, intent: { themes: 'highlife, West African guitar band classics', energyArc: 'steady', eraTo: 1995, genres: ['highlife'] } },
  { brief: 'bossa nova for a slow dinner', mainstream: false, intent: { themes: 'bossa nova, gentle, Brazilian', energyArc: 'steady', genres: ['bossa nova'] } },
  { brief: 'ambient electronic for coding late at night', mainstream: false, intent: { themes: 'ambient electronic, downtempo, minimal vocals', energyArc: 'steady', genres: ['electronic'] } },
]

function fullIntent(p: Brief): Intent {
  return { allowExplicit: true, familiarity: 'mix', targetCount: 15, ...p.intent } as Intent
}

// ---------- the spike's prompt variant (S3, inlined) ----------

const OUTPUT_BLOCK_START = 'Output STRICT JSON ONLY'
const ESTIMATE_OUTPUT_BLOCK =
  'Each song also carries "energy" and "valence", numbers from 0 to 1 with two decimals: your best estimate of how ' +
  'the recording feels, on the scale of Spotify-style audio features. energy: 0 is calm and sparse, 1 is loud, fast ' +
  'and intense. valence: 0 is sad, dark or tense, 1 is happy, cheerful or euphoric.\n\n' +
  'Output STRICT JSON ONLY: one array, [{"title":"<song title>","artist":"<primary artist>","reason":"<short ' +
  'reason>","energy":<0-1>,"valence":<0-1>}, ...], in play order. Begin your response with [ and end it with ]. No ' +
  'prose, no markdown, no code fences, nothing before or after the array.'

type CallLog = { inputTokens: number; outputTokens: number; cacheRead: number | null; stopReason: string | null; ms: number; text: string }

function estimatingLlm(inner: LlmClient, calls: CallLog[]): LlmClient {
  return async (req) => {
    const at = req.system.indexOf(OUTPUT_BLOCK_START)
    if (at < 0) throw new Error('proposal prompt output block not found: the spike variant is stale')
    const started = Date.now()
    const turn = await inner({ ...req, system: req.system.slice(0, at) + ESTIMATE_OUTPUT_BLOCK })
    calls.push({
      inputTokens: turn.usage?.inputTokens ?? 0,
      outputTokens: turn.usage?.outputTokens ?? 0,
      cacheRead: turn.usage?.cacheReadInputTokens ?? null,
      stopReason: turn.stopReason,
      ms: Date.now() - started,
      text: turn.text,
    })
    return turn
  }
}

const songKey = (title: string, artist: string) => `${titleKey(title)}\u0000${artistKey(artist)}`

function parseEstimates(text: string): Map<string, { energy?: number; valence?: number }> {
  const out = new Map<string, { energy?: number; valence?: number }>()
  const start = text.indexOf('[')
  const end = text.lastIndexOf(']')
  if (start < 0 || end <= start) return out
  let arr: unknown
  try {
    arr = JSON.parse(text.slice(start, end + 1))
  } catch {
    return out
  }
  if (!Array.isArray(arr)) return out
  const unit = (v: unknown) => (typeof v === 'number' && v >= 0 && v <= 1 ? v : undefined)
  for (const item of arr) {
    if (!item || typeof item !== 'object') continue
    const r = item as Record<string, unknown>
    if (typeof r.title !== 'string' || typeof r.artist !== 'string') continue
    out.set(songKey(r.title, r.artist), { energy: unit(r.energy), valence: unit(r.valence) })
  }
  return out
}

// ---------- raw results ----------

type ProposalRow = {
  title: string
  artist: string
  energy?: number
  valence?: number
  outcome: 'verified' | 'no_match' | 'no_results' | 'glue' | 'duplicate' | 'apple_error'
  hit?: { title: string; artist: string; isrc: string | null; durationMs: number | null; genre: string | null; year: number | null }
  titleDiffers?: boolean
  versionMarker?: boolean
  owned?: boolean
  appleError?: string
  firstPassAppleError?: boolean
}
type PromptRun = {
  account: 'founder' | 'exportify'
  brief: string
  mainstream: boolean
  storefront: string
  calls: Omit<CallLog, 'text'>[]
  error?: string
  proposals: ProposalRow[]
}
type ReccoOutcome = { status: 'hit' | 'miss' | 'error'; ms: number; http?: number; energy?: number | null; valence?: number | null; tempo?: number | null; retried429?: boolean }
type DeezerOutcome = { status: 'bpm' | 'bpm_zero' | 'error_body' | 'http_error' | 'fetch_error'; ms: number; http?: number; errorType?: string; bpm?: number }
type LookupRow = {
  set: 'chart' | 'library' | 'non_english' | 'pre1980' | 'proposal'
  isrc: string
  title: string
  artist: string
  durationMs: number | null
  recco: ReccoOutcome
  deezer?: DeezerOutcome
  estimate?: { energy?: number; valence?: number }
}
type Raw = {
  startedAt: string
  accounts: { founder: { library: number; storefront: string; topArtists: number }; exportify: { library: number; storefront: string; topArtists: number; storefrontDefaulted: boolean } }
  runs: PromptRun[]
  lookups: LookupRow[]
  reccoRateLimits: number
  catalogueTarget: number
  appleRetried?: number
}

// ---------- read-only database ----------

type Sql = NeonQueryFunction<false, false>
async function select<T>(sql: Sql, text: string, params: unknown[] = []): Promise<T[]> {
  if (!/^\s*(SELECT|WITH)\b/i.test(text)) throw new Error('read-only script: SELECT only')
  return (await sql.query(text, params)) as T[]
}

type LibRow = { title: string; artist: string; isrc: string | null }
type Account = { userId: string; storefront: string; storefrontDefaulted: boolean; library: LibRow[]; topArtists: string[] }

async function loadAccounts(sql: Sql): Promise<{ founder: Account; exportify: Account }> {
  // Founder: the largest in-library collection. Exportify test account: the
  // Spotify-export listener whose library is 830 songs (the account the
  // 2026-10-03 drain describes), else the smallest Spotify-export library.
  const founderRow = (await select<{ user_id: string }>(sql,
    `SELECT user_id FROM user_tracks WHERE in_library GROUP BY user_id ORDER BY count(*) DESC LIMIT 1`))[0]
  const exportRows = await select<{ user_id: string; n: string }>(sql,
    `SELECT ut.user_id, count(*) AS n FROM user_tracks ut
       WHERE EXISTS (SELECT 1 FROM user_music_sources m WHERE m.user_id = ut.user_id AND m.source = 'spotify_export')
       GROUP BY ut.user_id ORDER BY count(*) ASC`)
  const exportRow = exportRows.find((r) => Number(r.n) === 830) ?? exportRows[0]
  if (!founderRow || !exportRow) throw new Error('could not identify the two accounts')
  const load = async (userId: string): Promise<Account> => {
    const sf = (await select<{ apple_storefront: string | null }>(sql,
      `SELECT apple_storefront FROM user_music_profiles WHERE user_id = $1`, [userId]))[0]?.apple_storefront ?? null
    // Every row the listener has, in library or not: Spotify-export rows
    // carry in_library = false, and a song they played is a song they own
    // for the "already owned" question.
    const library = await select<LibRow>(sql,
      `SELECT t.title, t.artist, upper(t.isrc) AS isrc FROM user_tracks ut JOIN tracks t ON t.id = ut.track_id WHERE ut.user_id = $1`, [userId])
    // dj/loop.ts topLibraryArtists counts in_library rows only; for an
    // export-only listener that is empty, so fall back to every row.
    let top = await select<{ artist: string }>(sql,
      `SELECT t.artist FROM user_tracks ut JOIN tracks t ON t.id = ut.track_id
         WHERE ut.user_id = $1 AND ut.in_library GROUP BY t.artist ORDER BY count(*) DESC, t.artist LIMIT 10`, [userId])
    if (top.length === 0) {
      top = await select<{ artist: string }>(sql,
        `SELECT t.artist FROM user_tracks ut JOIN tracks t ON t.id = ut.track_id
           WHERE ut.user_id = $1 GROUP BY t.artist ORDER BY count(*) DESC, t.artist LIMIT 10`, [userId])
    }
    return { userId, storefront: sf ?? 'ng', storefrontDefaulted: sf === null, library, topArtists: top.map((r) => r.artist) }
  }
  return { founder: await load(founderRow.user_id), exportify: await load(exportRow.user_id) }
}

type SampleRow = { isrc: string; title: string; artist: string; duration_ms: number | null }

async function sampleCatalogue(sql: Sql, n: number): Promise<Array<SampleRow & { set: LookupRow['set'] }>> {
  const per = Math.ceil(n / 4)
  // Deterministic order (md5 of id with a fixed salt) so a rerun samples the
  // same songs; strata are disjoint, taken in this order.
  const strata: Array<{ set: LookupRow['set']; where: string }> = [
    { set: 'pre1980', where: `t.release_year < 1980` },
    { set: 'non_english', where: `t.title ~ '[^\\x01-\\x7F]'` },
    { set: 'library', where: `EXISTS (SELECT 1 FROM user_tracks u WHERE u.track_id = t.id)` },
    // Catalogue-seeded (charts, editorial playlists, verified proposals): no
    // listener holds it.
    { set: 'chart', where: `NOT EXISTS (SELECT 1 FROM user_tracks u WHERE u.track_id = t.id) AND t.apple_id IS NOT NULL` },
  ]
  const taken = new Set<string>()
  const out: Array<SampleRow & { set: LookupRow['set'] }> = []
  for (const s of strata) {
    const rows = await select<SampleRow>(sql,
      `SELECT DISTINCT ON (upper(t.isrc)) upper(t.isrc) AS isrc, t.title, t.artist, t.duration_ms
         FROM tracks t WHERE t.isrc IS NOT NULL AND ${s.where}
         ORDER BY upper(t.isrc), md5(t.id::text || 'spike-2026-11-16')`)
    rows.sort((a, b) => (hash(a.isrc) < hash(b.isrc) ? -1 : 1))
    let k = 0
    for (const r of rows) {
      if (k >= per) break
      if (taken.has(r.isrc)) continue
      taken.add(r.isrc)
      out.push({ ...r, set: s.set })
      k++
    }
  }
  return out
}

function hash(s: string): string {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0
  return h.toString(16).padStart(8, '0')
}

// ---------- proposals + read-only verification ----------

const VERSION_MARKER = /\b(live|remix|remixed|mix|version|remaster|remastered|acoustic|cover|edit|demo|instrumental|karaoke|sped|slowed|re-?recorded|mono|stereo|session|unplugged|extended|reprise|tribute)\b/i

type Catalog = ReturnType<typeof createAppleCatalogClient>

// One proposal's Apple search and pickHit, as verifyProposals does it, with
// no insert. seenApple holds the run's confirmed recordings (Apple id or
// ISRC) so a repeat counts as a duplicate, not a second song.
async function verifyRow(row: ProposalRow, account: Account, catalog: Catalog, seenApple: Set<string>, namedSongs: Intent['namedSongs']): Promise<void> {
  const isrcs = new Set(account.library.flatMap((r) => (r.isrc ? [r.isrc] : [])))
  const keys = new Set(account.library.map((r) => songKey(r.title, r.artist)))
  const term = `${row.title} ${row.artist}`.slice(0, MAX_TERM_LENGTH).trim()
  let found: CatalogSong[]
  try {
    found = await catalog.searchSongs(account.storefront, term, SEARCH_LIMIT)
  } catch (e) {
    // Apple omits results.songs when nothing matches, which the client
    // reads as a malformed 200: that is an empty search, not a failure.
    if (e instanceof AppleCatalogError && e.category === 'response' && e.status === 200) {
      row.outcome = 'no_results'
      delete row.appleError
      return
    }
    row.outcome = 'apple_error'
    row.appleError = e instanceof AppleCatalogError ? `${e.category}${e.status ? `:${e.status}` : ''}` : 'internal'
    if (e instanceof AppleCatalogError && e.category === 'rate_limit') await sleep(5000)
    return
  }
  delete row.appleError
  if (found.length === 0) { row.outcome = 'no_results'; return }
  const hit = pickHit(found, row)
  if (!hit) { row.outcome = 'no_match'; return }
  if (isAlbumGlue(hit.title, hit.artist, namedSongs)) { row.outcome = 'glue'; return }
  const isrc = hit.isrc ? hit.isrc.trim().toUpperCase() : null
  if (seenApple.has(hit.appleId) || (isrc && seenApple.has(isrc))) { row.outcome = 'duplicate'; return }
  seenApple.add(hit.appleId)
  if (isrc) seenApple.add(isrc)
  row.outcome = 'verified'
  row.hit = { title: hit.title, artist: hit.artist, isrc, durationMs: hit.durationMs ?? null, genre: hit.genre ?? null, year: hit.releaseYear ?? null }
  row.titleDiffers = artistKey(hit.title) !== artistKey(row.title)
  row.versionMarker = VERSION_MARKER.test(hit.title) && !VERSION_MARKER.test(row.title)
  row.owned = (isrc !== null && isrcs.has(isrc)) || keys.has(songKey(hit.title, hit.artist)) || keys.has(songKey(row.title, row.artist))
}

// The first pass ran three briefs at once (12 Apple searches in flight);
// searches that failed there are retried one at a time, so an Apple error
// is not read as a proposal that does not exist.
async function retryAppleErrors(raw: Raw, accounts: { founder: Account; exportify: Account }, catalog: Catalog): Promise<void> {
  let retried = 0
  for (const run of raw.runs) {
    const failed = run.proposals.filter((r) => r.outcome === 'apple_error')
    if (failed.length === 0) continue
    const seen = new Set(run.proposals.flatMap((r) => (r.outcome === 'verified' && r.hit?.isrc ? [r.hit.isrc] : [])))
    const p = PROMPTS.find((q) => q.brief === run.brief)!
    for (const row of failed) {
      row.firstPassAppleError = true
      await verifyRow(row, accounts[run.account], catalog, seen, fullIntent(p).namedSongs)
      retried++
      await sleep(1000)
    }
  }
  raw.appleRetried = retried
  console.log(`apple retries: ${retried}, still failing ${raw.runs.flatMap((r) => r.proposals).filter((r) => r.outcome === 'apple_error').length}`)
}

async function runProposals(account: Account, label: PromptRun['account'], llm: LlmClient,
  catalog: Catalog): Promise<PromptRun[]> {
  const runs: PromptRun[] = []
  let next = 0
  const worker = async () => {
    while (next < PROMPTS.length) {
      const p = PROMPTS[next++]
      const calls: CallLog[] = []
      const run: PromptRun = { account: label, brief: p.brief, mainstream: p.mainstream, storefront: account.storefront, calls: [], proposals: [] }
      runs.push(run)
      let proposals: Proposal[] = []
      try {
        proposals = await proposeSongs(estimatingLlm(llm, calls), {
          brief: p.brief,
          intent: fullIntent(p),
          seeds: p.intent.namedArtists ?? [],
          storefront: account.storefront,
          listener: 'personal',
          topArtists: account.topArtists,
        })
      } catch (e) {
        run.error = e instanceof Error ? e.name : typeof e
      }
      run.calls = calls.map(({ text: _t, ...rest }) => rest)
      const estimates = parseEstimates(calls.at(-1)?.text ?? '')
      run.proposals = proposals.map((q) => ({ title: q.title, artist: q.artist, ...estimates.get(songKey(q.title, q.artist)), outcome: 'no_match' as const }))
      // Read-only verification: verifyProposals' search and pickHit, no insert.
      const seenApple = new Set<string>()
      for (let i = 0; i < run.proposals.length; i += APPLE_CONCURRENCY) {
        const batch = run.proposals.slice(i, i + APPLE_CONCURRENCY)
        await Promise.all(batch.map((row) => verifyRow(row, account, catalog, seenApple, fullIntent(p).namedSongs)))
        await sleep(APPLE_GAP_MS)
      }
      const v = run.proposals.filter((r) => r.outcome === 'verified').length
      console.log(`[${label}] ${p.brief}: ${v}/${run.proposals.length} verified${run.error ? ` (error ${run.error})` : ''}`)
    }
  }
  await Promise.all(Array.from({ length: LLM_CONCURRENCY }, worker))
  return PROMPTS.map((p) => runs.find((r) => r.brief === p.brief)!).filter(Boolean)
}

// ---------- providers ----------

let reccoRateLimits = 0

async function recco(row: { title: string; artist: string; durationMs: number | null }): Promise<ReccoOutcome> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const started = Date.now()
    try {
      const f: AudioFeatures | null = await resolveAndFetchFeatures({ title: row.title, artist: row.artist, durationMs: row.durationMs })
      const ms = Date.now() - started
      return f
        ? { status: 'hit', ms, energy: f.energy, valence: f.valence, tempo: f.tempo, ...(attempt > 0 ? { retried429: true } : {}) }
        : { status: 'miss', ms, ...(attempt > 0 ? { retried429: true } : {}) }
    } catch (e) {
      const ms = Date.now() - started
      const status = e instanceof EnrichSourceError ? e.status : undefined
      if (status === 429 && attempt === 0) {
        reccoRateLimits++
        console.log('  reccobeats 429, backing off')
        await sleep(RECCO_429_WAIT_MS)
        continue
      }
      if (status === 429) reccoRateLimits++
      return { status: 'error', ms, ...(status !== undefined ? { http: status } : {}) }
    }
  }
  return { status: 'error', ms: 0 }
}

async function deezer(isrc: string): Promise<DeezerOutcome> {
  const started = Date.now()
  let res: Response
  try {
    res = await fetch(`https://api.deezer.com/track/isrc:${encodeURIComponent(isrc)}`, { signal: AbortSignal.timeout(8000) })
  } catch {
    return { status: 'fetch_error', ms: Date.now() - started }
  }
  const ms = Date.now() - started
  if (!res.ok) return { status: 'http_error', ms, http: res.status }
  const body = (await res.json().catch(() => null)) as { bpm?: unknown; error?: { type?: unknown; code?: unknown } } | null
  if (!body) return { status: 'http_error', ms, http: res.status }
  if (body.error) return { status: 'error_body', ms, errorType: `${String(body.error.type)}:${String(body.error.code)}` }
  const bpm = typeof body.bpm === 'number' ? body.bpm : 0
  return bpm > 0 ? { status: 'bpm', ms, bpm } : { status: 'bpm_zero', ms, bpm }
}

async function runLookups(rows: Omit<LookupRow, 'recco' | 'deezer'>[]): Promise<LookupRow[]> {
  const out: LookupRow[] = []
  let i = 0
  for (const row of rows) {
    const r = await recco(row)
    const full: LookupRow = { ...row, recco: r }
    if (r.status !== 'hit' || r.energy == null) {
      full.deezer = await deezer(row.isrc)
      await sleep(DEEZER_GAP_MS)
    }
    out.push(full)
    if (++i % 25 === 0) console.log(`  lookups ${i}/${rows.length} (recco 429s ${reccoRateLimits})`)
    await sleep(RECCO_GAP_MS)
  }
  return out
}

// ---------- report ----------

const pct = (a: number, b: number) => (b === 0 ? 'n/a' : `${((100 * a) / b).toFixed(1)}%`)
function quantile(values: number[], q: number): number | null {
  if (values.length === 0) return null
  const s = [...values].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor(q * s.length))]
}
const md = (s: string) => s.replace(/\|/g, '\\|')

function buildReport(raw: Raw): string {
  const L: string[] = []
  const lookups = raw.lookups
  const cat = lookups.filter((l) => l.set !== 'proposal')
  const prop = lookups.filter((l) => l.set === 'proposal')
  const reccoHit = (l: LookupRow) => l.recco.status === 'hit' && l.recco.energy != null
  const covered = (l: LookupRow) => reccoHit(l) || l.deezer?.status === 'bpm'

  // Proposals.
  const allRows = raw.runs.flatMap((r) => r.proposals.map((p) => ({ ...p, run: r })))
  const verifyRate = (runs: PromptRun[]) => {
    const n = runs.reduce((a, r) => a + r.proposals.length, 0)
    const v = runs.reduce((a, r) => a + r.proposals.filter((p) => p.outcome === 'verified').length, 0)
    return { n, v }
  }
  const mainstream = verifyRate(raw.runs.filter((r) => r.mainstream))
  const niche = verifyRate(raw.runs.filter((r) => !r.mainstream))
  const verified = allRows.filter((r) => r.outcome === 'verified')

  // Gate 2: ReccoBeats energy on verified proposals.
  const propRecco = prop.filter(reccoHit).length
  // Gate 3: MAE.
  const pairs = prop.filter((l) => reccoHit(l) && l.estimate?.energy !== undefined)
    .map((l) => ({ est: l.estimate!.energy!, meas: l.recco.energy! }))
  const vpairs = prop.filter((l) => l.recco.status === 'hit' && l.recco.valence != null && l.estimate?.valence !== undefined)
    .map((l) => ({ est: l.estimate!.valence!, meas: l.recco.valence! }))
  const mae = (ps: { est: number; meas: number }[]) => (ps.length ? ps.reduce((a, p) => a + Math.abs(p.est - p.meas), 0) / ps.length : null)
  const meanMeas = (ps: { meas: number }[]) => (ps.length ? ps.reduce((a, p) => a + p.meas, 0) / ps.length : 0)
  const baseline = (ps: { est: number; meas: number }[]) => { const m = meanMeas(ps); return ps.length ? ps.reduce((a, p) => a + Math.abs(m - p.meas), 0) / ps.length : null }
  const corr = (ps: { est: number; meas: number }[]) => {
    if (ps.length < 3) return null
    const mx = ps.reduce((a, p) => a + p.est, 0) / ps.length
    const my = meanMeas(ps)
    let sxy = 0, sxx = 0, syy = 0
    for (const p of ps) { sxy += (p.est - mx) * (p.meas - my); sxx += (p.est - mx) ** 2; syy += (p.meas - my) ** 2 }
    return sxx && syy ? sxy / Math.sqrt(sxx * syy) : null
  }
  const within = (ps: { est: number; meas: number }[], t: number) => ps.filter((p) => Math.abs(p.est - p.meas) <= t).length
  const energyMae = mae(pairs)

  const g1 = mainstream.n > 0 && mainstream.v / mainstream.n >= 0.7
  const g2 = prop.length > 0 && propRecco / prop.length >= 0.6
  const g3 = energyMae !== null && energyMae <= 0.15
  const f = (x: number | null, d = 3) => (x === null ? 'n/a' : x.toFixed(d))

  L.push('# Propose-first spike (Step 0)', '')
  L.push(`Run ${raw.startedAt.slice(0, 16).replace('T', ' ')} UTC by \`server/scripts/propose-first-spike.ts\`. ` +
    'Read-only against production: SELECTs only, no inserts, no `verifyProposals`.', '')
  L.push('## Gate 0', '')
  L.push('| Gate | Threshold | Measured | Result |', '|---|---|---|---|')
  L.push(`| Apple verify rate, mainstream briefs | ≥ 70% | ${pct(mainstream.v, mainstream.n)} (${mainstream.v}/${mainstream.n}) | ${g1 ? 'pass' : 'FAIL'} |`)
  L.push(`| ReccoBeats energy on verified proposals | ≥ 60% | ${pct(propRecco, prop.length)} (${propRecco}/${prop.length}) | ${g2 ? 'pass' : 'FAIL'} |`)
  L.push(`| Model energy estimate MAE vs ReccoBeats | ≤ 0.15 | ${f(energyMae)} (n=${pairs.length}) | ${g3 ? 'pass' : 'FAIL'} |`, '')

  L.push('## Free feature coverage', '')
  L.push(`Catalogue sample: ${cat.length} ISRCs (target ${raw.catalogueTarget}); verified-proposal sample: ${prop.length} ISRCs ` +
    `(target ${PROPOSAL_ISRC_N}). ReccoBeats first (title search, artist + duration gate, as enrichment does), Deezer ` +
    '`/track/isrc:<ISRC>` only for ReccoBeats misses and errors.', '')
  L.push('| Set | n | ReccoBeats energy | Deezer bpm>0 (of RB misses) | Deezer bpm=0 | Deezer error body | Either |', '|---|---|---|---|---|---|---|')
  const sets: Array<LookupRow['set'] | 'all catalogue'> = ['chart', 'library', 'non_english', 'pre1980', 'all catalogue', 'proposal']
  for (const s of sets) {
    const rows = s === 'all catalogue' ? cat : lookups.filter((l) => l.set === s)
    const misses = rows.filter((l) => !reccoHit(l))
    const dz = (st: DeezerOutcome['status']) => misses.filter((l) => l.deezer?.status === st).length
    L.push(`| ${s} | ${rows.length} | ${pct(rows.filter(reccoHit).length, rows.length)} | ${pct(dz('bpm'), misses.length)} (${dz('bpm')}/${misses.length}) | ${dz('bpm_zero')} | ${dz('error_body')} | ${pct(rows.filter(covered).length, rows.length)} |`)
  }
  L.push('')
  const rLat = lookups.map((l) => l.recco.ms)
  const dLat = lookups.flatMap((l) => (l.deezer ? [l.deezer.ms] : []))
  const reccoErr = lookups.filter((l) => l.recco.status === 'error')
  const errTypes = new Map<string, number>()
  for (const l of lookups) if (l.deezer?.status === 'error_body') errTypes.set(l.deezer.errorType!, (errTypes.get(l.deezer.errorType!) ?? 0) + 1)
  const dzAll = lookups.filter((l) => l.deezer)
  L.push(`- ReccoBeats: ${lookups.length} lookups, p50 ${quantile(rLat, 0.5)} ms, p95 ${quantile(rLat, 0.95)} ms (a lookup is a search plus a features fetch on a match). ` +
    `429s: ${raw.reccoRateLimits}. Other errors: ${reccoErr.length}${reccoErr.length ? ` (HTTP ${[...new Set(reccoErr.map((l) => l.recco.http ?? 'none'))].join(', ')})` : ''}. ` +
    `Hits without an energy value: ${lookups.filter((l) => l.recco.status === 'hit' && l.recco.energy == null).length}.`)
  L.push(`- Deezer: ${dzAll.length} lookups, p50 ${quantile(dLat, 0.5)} ms, p95 ${quantile(dLat, 0.95)} ms. ` +
    `bpm>0 ${dzAll.filter((l) => l.deezer!.status === 'bpm').length}, bpm=0 ${dzAll.filter((l) => l.deezer!.status === 'bpm_zero').length} ` +
    `(${pct(dzAll.filter((l) => l.deezer!.status === 'bpm_zero').length, dzAll.filter((l) => l.deezer!.status === 'bpm' || l.deezer!.status === 'bpm_zero').length)} of found tracks), ` +
    `error body ${dzAll.filter((l) => l.deezer!.status === 'error_body').length} (${[...errTypes].map(([k, v]) => `\`${k}\` ×${v}`).join(', ') || 'none'}), ` +
    `HTTP/fetch errors ${dzAll.filter((l) => l.deezer!.status === 'http_error' || l.deezer!.status === 'fetch_error').length}.`, '')

  L.push('## Proposal quality (library listeners)', '')
  const fa = raw.accounts.founder
  const ea = raw.accounts.exportify
  L.push(`- Founder account: ${fa.library} songs, storefront \`${fa.storefront}\`, ${fa.topArtists} top artists sent.`)
  L.push(`- Exportify test account: ${ea.library} songs (all \`in_library = false\`, Spotify export), storefront \`${ea.storefront}\`` +
    `${ea.storefrontDefaulted ? ' (no profile storefront; the loop\'s `ng` fallback)' : ''}, ${ea.topArtists} top artists sent (counted over every row, since \`topLibraryArtists\` counts in-library rows only and would send none).`, '')
  L.push(`Mainstream briefs: ${pct(mainstream.v, mainstream.n)} verified (${mainstream.v}/${mainstream.n}). Genre/era/constraint briefs: ${pct(niche.v, niche.n)} (${niche.v}/${niche.n}). ` +
    `All: ${pct(mainstream.v + niche.v, mainstream.n + niche.n)}.`, '')
  const outcomes = new Map<string, number>()
  for (const r of allRows) outcomes.set(r.outcome, (outcomes.get(r.outcome) ?? 0) + 1)
  L.push(`Outcomes across all proposals: ${[...outcomes].map(([k, v]) => `${k} ${v}`).join(', ')}. ` +
    '`no_match` means Apple returned songs but none passed `pickHit` (title key, credited artist, no unasked version word); `no_results` means the search came back empty.', '')
  const firstErr = allRows.filter((r) => r.firstPassAppleError)
  if (raw.appleRetried !== undefined) {
    const errCats = new Map<string, number>()
    for (const r of allRows) if (r.appleError) errCats.set(r.appleError, (errCats.get(r.appleError) ?? 0) + 1)
    L.push(`Apple search failures on the first pass (three briefs at once, up to 12 searches in flight): ${firstErr.length}. ` +
      `Retried one at a time: ${firstErr.filter((r) => r.outcome === 'verified').length} verified, ${firstErr.filter((r) => r.outcome !== 'verified' && r.outcome !== 'apple_error').length} did not, ` +
      `${firstErr.filter((r) => r.outcome === 'apple_error').length} still errored${errCats.size ? ` (${[...errCats].map(([k, v]) => `\`${k}\` ×${v}`).join(', ')})` : ''}. ` +
      'Apple answers an empty search with a 200 that has no `results.songs`, which the catalog client throws as `response:200`; ' +
      'those are counted as `no_results` (production `verifyProposals` counts them as misses too, so the verify rate is the same either way). ' +
      'Songs verified on the retry are counted as verified but were not in the ReccoBeats proposal sample (drawn before the retry).', '')
  }
  L.push(`Of ${verified.length} verified: already owned by that listener ${verified.filter((r) => r.owned).length} (${pct(verified.filter((r) => r.owned).length, verified.length)}); ` +
    `Apple title differs from the proposed title ${verified.filter((r) => r.titleDiffers).length}; of those, carrying a version marker the proposal lacked ${verified.filter((r) => r.versionMarker).length}.`, '')
  L.push('| Account | Brief | Main | Proposed | Verified | Rate | Owned | Title differs | In tok | Out tok | Calls | Est. given |', '|---|---|---|---|---|---|---|---|---|---|---|---|')
  for (const r of raw.runs) {
    const v = r.proposals.filter((p) => p.outcome === 'verified')
    const inTok = r.calls.reduce((a, c) => a + c.inputTokens, 0)
    const outTok = r.calls.reduce((a, c) => a + c.outputTokens, 0)
    L.push(`| ${r.account} | ${md(r.brief)} | ${r.mainstream ? 'y' : ''} | ${r.proposals.length}${r.error ? ` (${r.error})` : ''} | ${v.length} | ${pct(v.length, r.proposals.length)} | ${v.filter((p) => p.owned).length} | ${v.filter((p) => p.titleDiffers).length} | ${inTok} | ${outTok} | ${r.calls.length} | ${r.proposals.filter((p) => p.energy !== undefined).length} |`)
  }
  L.push('')
  const calls = raw.runs.flatMap((r) => r.calls)
  const inT = calls.map((c) => c.inputTokens)
  const outT = calls.map((c) => c.outputTokens)
  const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0)
  L.push(`Tokens: ${calls.length} Sonnet calls (\`claude-sonnet-5\`, effort medium), input ${sum(inT)} total (mean ${Math.round(sum(inT) / Math.max(1, calls.length))}, max ${Math.max(0, ...inT)}), ` +
    `output ${sum(outT)} total (mean ${Math.round(sum(outT) / Math.max(1, calls.length))}, max ${Math.max(0, ...outT)}). ` +
    `Cache reads: ${sum(calls.map((c) => c.cacheRead ?? 0))}. max_tokens stops: ${calls.filter((c) => c.stopReason === 'max_tokens').length}. ` +
    `Call latency p50 ${quantile(calls.map((c) => c.ms), 0.5)} ms, p95 ${quantile(calls.map((c) => c.ms), 0.95)} ms.`, '')

  L.push('### Verified picks whose Apple title differs (judge by eye)', '')
  const diffs = verified.filter((r) => r.titleDiffers)
  if (diffs.length === 0) L.push('None.')
  else {
    L.push('| Account | Brief | Proposed | Apple hit | Marker |', '|---|---|---|---|---|')
    for (const r of diffs) L.push(`| ${r.run.account} | ${md(r.run.brief)} | ${md(r.title)} by ${md(r.artist)} | ${md(r.hit!.title)} by ${md(r.hit!.artist)} | ${r.versionMarker ? 'yes' : ''} |`)
  }
  L.push('')
  L.push('### Unverified proposals (sample, judge by eye)', '')
  const misses = allRows.filter((r) => r.outcome !== 'verified' && r.outcome !== 'duplicate')
  L.push('| Account | Brief | Proposed | Outcome |', '|---|---|---|---|')
  for (const r of misses.slice(0, 60)) L.push(`| ${r.run.account} | ${md(r.run.brief)} | ${md(r.title)} by ${md(r.artist)} | ${r.outcome} |`)
  if (misses.length > 60) L.push(`| | | … ${misses.length - 60} more | |`)
  L.push('')

  L.push('## Model estimate error', '')
  L.push(`Verified proposals with both a model estimate and a ReccoBeats measurement: energy n=${pairs.length}, valence n=${vpairs.length}.`, '')
  L.push('| Feature | MAE | Within 0.15 | Within 0.25 | Pearson r | Baseline MAE (predict the sample mean) |', '|---|---|---|---|---|---|')
  L.push(`| energy | ${f(energyMae)} | ${pct(within(pairs, 0.15), pairs.length)} | ${pct(within(pairs, 0.25), pairs.length)} | ${f(corr(pairs), 2)} | ${f(baseline(pairs))} |`)
  L.push(`| valence | ${f(mae(vpairs))} | ${pct(within(vpairs, 0.15), vpairs.length)} | ${pct(within(vpairs, 0.25), vpairs.length)} | ${f(corr(vpairs), 2)} | ${f(baseline(vpairs))} |`, '')
  return L.join('\n')
}

// ---------- main ----------

async function main() {
  const env = loadDevVars()
  for (const k of ['DATABASE_URL', 'ANTHROPIC_API_KEY', 'APPLE_TEAM_ID', 'MUSICKIT_KEY_ID', 'MUSICKIT_PRIVATE_KEY']) {
    if (!env[k]) throw new Error(`${k} missing from .dev.vars`)
  }
  const sql = neon(env.DATABASE_URL)
  const reuse: Partial<Raw> = REUSE_PATH && existsSync(REUSE_PATH) ? JSON.parse(readFileSync(REUSE_PATH, 'utf8')) : {}
  const save = (raw: Partial<Raw>) => writeFileSync(RAW_PATH, JSON.stringify(raw, null, 1))

  const accounts = await loadAccounts(sql)
  const raw: Raw = {
    startedAt: reuse.startedAt ?? new Date().toISOString(),
    accounts: {
      founder: { library: accounts.founder.library.length, storefront: accounts.founder.storefront, topArtists: accounts.founder.topArtists.length },
      exportify: { library: accounts.exportify.library.length, storefront: accounts.exportify.storefront, topArtists: accounts.exportify.topArtists.length, storefrontDefaulted: accounts.exportify.storefrontDefaulted },
    },
    runs: reuse.runs ?? [],
    lookups: reuse.lookups ?? [],
    reccoRateLimits: reuse.reccoRateLimits ?? 0,
    catalogueTarget: CATALOGUE_N,
    ...(reuse.appleRetried !== undefined ? { appleRetried: reuse.appleRetried } : {}),
  }
  reccoRateLimits = raw.reccoRateLimits
  console.log(`accounts: founder ${raw.accounts.founder.library} songs, exportify ${raw.accounts.exportify.library} songs`)

  const catalog = createAppleCatalogClient({
    fetchLike: fetch,
    issueServerToken: () => generateMusicKitDeveloperToken({ teamId: env.APPLE_TEAM_ID, keyId: env.MUSICKIT_KEY_ID, privateKey: env.MUSICKIT_PRIVATE_KEY }),
  })
  if (raw.runs.length === 0) {
    const llm = anthropicLlm(buildAnthropic(env.ANTHROPIC_API_KEY))
    raw.runs.push(...(await runProposals(accounts.founder, 'founder', llm, catalog)))
    save(raw)
    raw.runs.push(...(await runProposals(accounts.exportify, 'exportify', llm, catalog)))
    save(raw)
  }

  if (raw.appleRetried === undefined) {
    await retryAppleErrors(raw, accounts, catalog)
    save(raw)
  }

  if (raw.lookups.length === 0) {
    const sample = await sampleCatalogue(sql, CATALOGUE_N)
    console.log(`catalogue sample: ${sample.length}`)
    // Verified proposals with an ISRC, deduped, round-robin across runs so
    // every brief is represented.
    const seen = new Set(sample.map((s) => s.isrc))
    const queues = raw.runs.map((r) => r.proposals.filter((p) => p.outcome === 'verified' && p.hit?.isrc))
    const propRows: Omit<LookupRow, 'recco' | 'deezer'>[] = []
    for (let i = 0; propRows.length < PROPOSAL_ISRC_N && queues.some((q) => q.length > i); i++) {
      for (const q of queues) {
        const p = q[i]
        if (!p || propRows.length >= PROPOSAL_ISRC_N || seen.has(p.hit!.isrc!)) continue
        seen.add(p.hit!.isrc!)
        propRows.push({ set: 'proposal', isrc: p.hit!.isrc!, title: p.hit!.title, artist: p.hit!.artist, durationMs: p.hit!.durationMs, estimate: { energy: p.energy, valence: p.valence } })
      }
    }
    const catRows = sample.map((s) => ({ set: s.set, isrc: s.isrc, title: s.title, artist: s.artist, durationMs: s.duration_ms }))
    console.log(`proposal ISRCs: ${propRows.length}`)
    // Proposals first: they decide two of the three gates.
    raw.lookups = await runLookups(propRows)
    raw.reccoRateLimits = reccoRateLimits
    save(raw)
    raw.lookups.push(...(await runLookups(catRows)))
    raw.reccoRateLimits = reccoRateLimits
    save(raw)
  }

  // Rows recorded before verifyRow learned that a 200 without results.songs
  // is an empty search.
  for (const row of raw.runs.flatMap((r) => r.proposals)) {
    if (row.outcome === 'apple_error' && row.appleError === 'response:200') {
      row.outcome = 'no_results'
      delete row.appleError
    }
  }
  writeFileSync(REPORT_PATH, buildReport(raw) + '\n')
  console.log(`report written; raw results at ${RAW_PATH}`)
}

await main()
