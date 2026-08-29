# Decision Log

Short ADR-style log. Newest first. Each entry: decision, why, and what would reopen it.

## 2026-08-29 — P2 enrichment: ReccoBeats-only waterfall, GetSongBPM dropped
ReccoBeats (probed live) provides the full 11-field feature set + ISRC backfill, keyless. GetSongBPM adds only BPM+key, needs an API key, and requires a visible getsongbpm.com backlink in the UI. **Reopens if:** Task 8 coverage report shows features coverage < 80% — then P2.5 adds the local preview-analysis leg first, GetSongBPM second.

## 2026-08-29 — ReccoBeats matching contract (probed live)
Search is TITLE-ONLY (`searchText` with artist terms returns zero results); we filter candidates ourselves by normalized artist equality + duration within 5s. Features endpoint keyed by their UUID.

## 2026-08-29 — iTunes storefront is config (default ng)
Founder's apple_ids resolve only on the Nigerian storefront (`country=ng`; US/GB return 0 — verified). `ITUNES_STOREFRONT` var, default `ng`. iTunes lookup doubles as duration/genre backfill + preview URLs.

## 2026-08-29 — Enrichment driven by cron + admin-token endpoint, not Cloudflare Queues
Queues needs the paid Workers plan; a 5-min cron (batch 8) covers steady state and `POST /enrich/run` + `scripts/backfill.sh` covers backfill. `/enrich/*` is guarded by `ENRICH_ADMIN_TOKEN` (enrichment is global per-track work, not user data — a user session would be the wrong shape). **Reopens if:** multi-user scale makes batch-8-per-5-min insufficient.

## 2026-08-29 — Embeddings: Workers AI @cf/baai/bge-m3 (1024-dim, pgvector on Neon)
Zero new accounts/keys, 10k free neurons/day, 8k-token context comfortably fits lyrics. Vector index deferred to P3 (no similarity queries exist yet). **Reopens if:** embedding quality disappoints in P3 matching — then Voyage.

## 2026-08-29 — Lyrics in P2: embeddings only, tags deferred
`track_meanings` stores embedding + instrumental flag, no text column (enforces the derive-don't-display stance structurally). Theme tags need the P3 curation prompt design to be useful — deferred.

## 2026-08-29 — Name: mixtape
Working name chosen by founder (over selector/resident/crates). Central metaphor: a personal DJ hand-making a tape for you.

## 2026-08-29 — Repo layout: monorepo at ~/Documents/work/mixtape
`client/` (Flutter iOS), `server/` (Hono on Cloudflare Workers), `web/` (placeholder, pending), `docs/`.

## 2026-08-29 — Apple Music first; Spotify deferred
Spotify removed Audio Features/Recommendations for new apps (Nov 2024) and gates extended access behind 250k-MAU registered businesses (May 2025); dev mode ≈ 25 users. Apple Music via MusicKit provides everything v1 needs, including real per-song play counts (native iOS only). **Reopens if:** Spotify changes access policy. Schema stays platform-agnostic (ISRC + per-platform IDs) against that day.

## 2026-08-29 — DB: Neon Postgres + Drizzle (not Supabase)
Founder preference: more generous, less tightly bound than Supabase. pgvector for embeddings.

## 2026-08-29 — Auth: Better Auth self-hosted in Hono, users in Neon
Neon's managed auth doesn't support Sign in with Apple (Google/GitHub/Microsoft only, verified 2026-08). Better Auth is the same engine, supports Apple natively, runs on Workers, keeps us portable. **Reopens if:** Neon managed auth ships Apple provider and migration is cheap.

## 2026-08-29 — Sessions-first product model
The primary object is an ephemeral radio-style session queue, not a playlist. History persists server-side; any session converts to a real playlist on demand. Playback via ApplicationMusicPlayer (in-app) or SystemMusicPlayer (hand-off to Music app).

## 2026-08-29 — Curation LLM: Sonnet 5, Opus 5 as escalation
~5–8¢/generation on Sonnet 5 with prompt-cached refinement turns. Escalate only the final sequencing pass to Opus 5 if ordering quality disappoints. Embeddings via a dedicated model (Voyage / Workers AI bge), never a chat model.

## 2026-08-29 — Enrichment waterfall for BPM/energy/etc.
Cache → ReccoBeats (full feature set) → GetSongBPM (BPM+key; requires visible backlink) → self-analysis of iTunes 30s previews with Essentia/librosa. Per-track, cached forever, shared across users.

## 2026-08-29 — Lyrics: derive-don't-display in v1
Store only embeddings + theme tags; never store or show lyric text; no lyrics-based marketing. Licensed Musixmatch deal (they hold AI-use licenses with all three majors) is a scaling milestone, not a launch blocker.

## 2026-08-29 — v1 audience: personal tool
Founder + friends via TestFlight. App Store polish (onboarding, review-proofing) deferred to v3 (see vision milestones).
