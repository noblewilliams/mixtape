# Mixtape v1 — System Design

*Status: draft for founder review · 2026-08-29*
*Companion doc: [vision](../../product/vision.md) · decisions log: [decisions](../../decisions.md)*

## Scope

v1 is a **personal tool**: founder + friends on TestFlight, iOS only, Apple Music only. Success = the founder reaches for mixtape instead of the Music app when they know *what kind* of thing they want to hear.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Client | Flutter (iOS-first) + native Swift MusicKit bridge | Founder's stack; MusicKit has no full-fidelity Flutter plugin, so a small Swift bridge (same pattern as goalympics' HealthKitBridge) exposes auth, library, play counts, and playback |
| API | Hono on Cloudflare Workers | Founder's stack; Workers queues/cron fit the enrichment pipeline |
| DB | Neon Postgres + Drizzle ORM | Serverless Postgres, generous tier, not coupled to auth/storage the way Supabase is |
| Auth | Better Auth self-hosted in the Hono worker, users in Neon | Neon's managed auth lacks Sign in with Apple; Better Auth (same engine) supports Apple natively and stays portable |
| Curation LLM | Claude Sonnet 5 (`claude-sonnet-5`) | ~5–8¢ per generated queue; escalate only the final sequencing pass to Opus 5 if ordering feels generic |
| Embeddings | Voyage or Workers AI (bge) | Lyric-meaning + prompt vectors; pennies per million tokens, one-time per track |
| Web | Pending — placeholder only in v1 | MusicKit JS makes it possible later (no play counts on web); shares this backend |

## Platform constraints (researched 2026-08)

- **Spotify**: Audio Features / Recommendations / Audio Analysis removed for new apps (Nov 2024); extended access requires a registered business with 250k+ MAU (May 2025); dev mode ≈ 25 allowlisted users; search now capped at 10 results (Feb 2026). Spotify is out of scope for v1; the schema stays platform-agnostic (tracks keyed by ISRC + per-platform ID columns) so it can return.
- **Apple Music**: library + playlists read/write, per-song play counts (native iOS only, via MediaPlayer), recommendations, recently played (heavy-rotation endpoint is unreliable — don't depend on it), full playback for subscribers. Developer token = MusicKit key from the existing Apple Developer Program membership ($0 incremental).
- **Playback modes**: `ApplicationMusicPlayer` = in-app radio session (ephemeral, our default). `SystemMusicPlayer` = hands the queue to the Music app so it survives app close. Both supported; sessions UI offers "play here" and "send to Music".

## Components

### 1. Client (`client/`)

- Flutter app, Riverpod for state (founder convention).
- **MusicKitBridge (Swift)**: authorization, library/playlist fetch, play counts, recently played, queue control for both players, playlist creation. Dart seam mirrors the bridge for testability.
- Screens (v1): Connect → Home (prompt box + session history) → Session (queue view: play, swap, pin, ban, "more like this", regenerate-from-here, save-as-playlist) → Settings.
- New Swift files must be added to the Xcode target (pbxproj) — recurring goalympics lesson.

### 2. API (`server/`)

Hono worker, routes grouped by domain:

- `auth/*` — Better Auth handler (Sign in with Apple; session JWTs for the app).
- `ingest/*` — client pushes library snapshot, play counts, recents; server diffs into the taste graph.
- `sessions/*` — create (prompt → queue), refine (edit ops), history, convert-to-playlist (server orchestrates; client executes MusicKit write and confirms).
- `enrich/*` — internal: queue consumers + cron for the enrichment waterfall.

### 3. Data (Neon)

Core tables (sketch — final schema at implementation):

- `users`, `auth_*` (Better Auth) 
- `tracks` — keyed by internal id; `isrc`, `apple_id`, title/artist/album, genre
- `track_features` — bpm, key, energy, danceability, valence, acousticness, source + confidence
- `track_meanings` — embedding vector, derived theme tags. **Never lyric text** (licensing stance below)
- `user_tracks` — per-user relationship: play_count, last_played, in_library, source playlists
- `sessions` — prompt, parsed intent, generated queue (ordered track refs + per-track "why"), edit log, status
- `taste_signals` — skips, swaps, pins, bans, completes (feeds v2 learning)

pgvector for embeddings (Neon supports it).

### 4. Enrichment pipeline (Workers queue + cron)

Per-track waterfall, results cached forever, corpus shared across users:

1. `track_features` cache hit → done
2. **ReccoBeats** (free, full Spotify-style feature set; resolve name→ID first)
3. **GetSongBPM** (free, BPM+key only; requires visible backlink attribution in the app)
4. **Self-analysis**: iTunes Search API (free, no auth, name+artist → 30s preview from the same catalog users are on) → Essentia/librosa on a worker → BPM/key/energy we computed ourselves

Lyrics-meaning leg (parallel): fetch transiently (LRCLIB; Musixmatch 30% snippet as fallback) → embed + derive theme tags → **store only derivations, drop the text**.

Every user-touched track is enqueued on ingest and on first appearance in a candidate pool.

### 5. Curation engine (the intelligence)

Retrieve-then-rerank, one generation ≈ 5–8¢ on Sonnet 5:

1. **Intent extraction** (small Sonnet call): prompt → structured intent (mood, energy arc, tempo range, era, familiarity dial, lyrical themes, exclusions).
2. **Candidate pool** (code, no LLM): taste graph + platform recommendations + genre/era filters → ~200–300 enriched tracks.
3. **Scoring** (code): hard constraints (BPM window, exclusions) then weighted score — embedding similarity (intent ↔ track meaning), feature fit, familiarity weighting from play counts.
4. **Curation pass** (Sonnet, prompt-cached candidate pool): select N, sequence for arc and transitions, one-line "why" per track.
5. **Refinement turns** reuse the cached pool — cheap (~90% cache discount on hits); every edit logged to `taste_signals`.

### 6. Lyrics licensing stance (v1)

Derive-don't-display. Lyric text is never stored, cached, or shown; only embeddings and abstract theme tags persist. This sits in a legal gray zone but matches the industry's now-priced "AI analysis" use (Musixmatch has AI-use deals with all three majors — that's the door to knock on at scale). Hard rules: no lyric text in UI or DB; no "we analyze lyrics" marketing. A licensed Musixmatch deal is a scaling milestone, not a launch blocker.

## Cost model

- Generation ≈ 5–8¢ (Sonnet 5, 15–25k in / 1–2k out); refinements much cheaper via prompt caching; intent calls sub-cent.
- Heavy personal use (~20 queues/day) ≈ $30–50/month — at or below goalympics spend.
- Escalation lever: Opus 5 for the sequencing pass only (~2.5× that one call) if quality demands.
- Enrichment: one-time per track, external APIs free, embeddings negligible.

## Error handling & resilience

- Enrichment failures degrade gracefully: a track with partial features still competes (confidence-weighted), and the waterfall retries via queue backoff.
- Curation must never return an empty queue: if the pool is thin, widen filters and say so in the session ("stretched beyond your library for this one").
- MusicKit auth loss → re-auth prompt, sessions history intact server-side.
- All external calls (ReccoBeats, GetSongBPM, iTunes, LRCLIB) behind per-source circuit breakers; the waterfall skips a tripped source.

## Testing

- Founder convention: TDD, server route tests + client widget/provider tests.
- Curation engine gets a golden-set harness: fixed taste graph + fixed prompts → assert structural properties (constraint satisfaction, no duplicates, arc monotonicity where demanded) rather than exact track lists.
- Swift bridge: thin, hand-verified on device; Dart seam mocked in tests.

## Open questions (deferred, not blocking)

- Android: Apple Music exists on Android (MusicKit on Android SDK) — revisit post-v1.
- Familiarity dial default (how adventurous is the DJ unprompted?) — tune with real use.
- Whether session play events can auto-sync (MusicKit playback observation) vs. explicit signals only.

## Build phases

1. **P1 Foundation** — repo scaffold (done), Better Auth + Apple sign-in, MusicKit bridge (auth + library read), ingest → taste graph.
2. **P2 Enrichment** — tracks/features schema, waterfall workers, embeddings, backfill founder's library.
3. **P3 Curation + Session UX** — intent → pool → score → curate; session screen with playback (radio mode).
4. **P4 Refinement + Conversion** — edit ops, taste signals, save-as-playlist, send-to-Music.
5. **P5 Web (pending)** — placeholder only.

Each phase gets its own implementation plan (writing-plans flow) before code.
