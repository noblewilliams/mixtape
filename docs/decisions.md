# Decision Log

Short ADR-style log. Newest first. Each entry: decision, why, and what would reopen it.

## 2026-08-29 — P2 backfill coverage report (4,689 tracks, ~5.5h wall incl. machine naps)
**Meanings 94.8%** (4,327 embeddings + 120 instrumentals) — the semantic axis is near-total. **Features 59.9%** (2,809; +ISRC/duration on each) — BELOW the 80% gate ⇒ **P2.5 (local preview analysis on the founder's Mac) is triggered** per the ReccoBeats-only decision's reopen clause. Failure mix: 1,770 genuine no-match, ~110 transient (429/timeout — reset and retried same day). Recommended sequencing: finish P3 first (the engine treats missing features as unscored-not-excluded by design; 95% meaning coverage carries curation), then P2.5 lifts the feature axis. Steady-state cron continues for new syncs.

## 2026-08-29 — P3 reshaped: conversation-first DJ, hand-off playback
Founder decisions: refinement moves INTO the session conversation (chat with inline queue widgets; manual drag/swipe posts the same edit ops), playback hands off to the Apple Music app (no in-app player in P3), save-as-playlist pulled forward from P4, per-track "why" on tap, queue length prompt-parsed with ~15 default. P4 slims to taste-signal learning + polish. Spec: `docs/superpowers/specs/2026-08-29-p3-dj-conversation-design.md`. **Reopens if:** hand-off UX proves clunky → in-app player returns to the roadmap.

Known accepted risk: tracks.title/artist are globally shared and last-ingester-wins (ingest.ts overwrites); DJ context renders them sanitized (control-chars stripped, capped) and never at system altitude. Revisit if multi-user title poisoning is observed.

**P3a spec deviations, recorded:** replace_range op dropped (edit ops cover it via remove+extend; revisit if the model fumbles multi-op rewrites); thin-pool widen-once deferred to P3b/P4 (only exactly-empty pools message the model today — thin pools silently backfill); session archiving shipped as PATCH /sessions/:id status (spec listed it without an endpoint). Queue removed-rows retention: replaceQueue preserves state='removed' rows as P4 taste signals.

## 2026-08-29 — iTunes lookup disabled on Workers (Apple IP-blocks datacenter ranges)
Verified live during Task 8: itunes.apple.com/lookup returns 403 to Cloudflare Workers regardless of headers, while working from residential IPs. The deployed pipeline runs `itunes: async () => null`; track duration comes from the matched ReccoBeats candidate (written back to `tracks.duration_ms` and threaded into the same pass's LRCLIB exact-get), genre comes from the library sync. `lookupItunes` stays tested for local/P2.5 use (preview downloads run from the founder's Mac anyway). **Reopens if:** Apple unblocks, or P2.5's local analyzer wants richer metadata.

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

## 2026-08-30 — Session titles: Haiku-generated, not the truncated prompt
`POST /sessions` names each session with a short 2–5 word title from `claude-haiku-4-5-20251001`, run concurrently with the DJ turn so latency is bounded to 5s worst case (a per-request timeout, not the turn's own duration); falls back to the truncated-prompt title on any failure/empty/garbage output — a title must never fail a session. The generated title lands on the row even when the turn itself fails, so a retried session isn't stuck showing the truncated fallback. This is a naming call, not curation, so it doesn't touch the Sonnet-only curation rule above.

## 2026-08-30 — P3 CLOSED: founder device smoke passed end-to-end
Full loop verified on the iPhone against prod: new prompt → curated queue → refinement turns → reorder/swipe → Play in Apple Music → Save as playlist (verified in Music) → archive/unarchive. Findings fixed during the smoke: (1) save "failures" were the flat 20s Dart timeout expiring while the native addItem chain (sequential, order-preserving, one network round trip per track) was still finishing — timeout now scales per track and snackbars carry Apple's real error; (2) playlists were attributed to "Runner" (Xcode product name) — now `authorDisplayName` = the user's account name (GET /me, editable + remembered in the save dialog, fallback "mixtape") with description "made by mixtape"; (3) session titles shipped mid-smoke (entry above) and backfilled onto the two pre-existing prod sessions. Deferred polish recorded in the P3b plan: undo-on-dismiss, sync terminal-state notice, auth-lifecycle cluster. Next: P2.5 (features 59.9% < 80% gate), then P4.

## 2026-08-30 — P2.5 COMPLETE: features coverage 59.9% → 100.0%
All 1,848 ReccoBeats-exhausted tracks (attempts ≥ 3, features-stage failures only — never-attempted tracks stay with the cron so they keep their shot at the richer 11-field rows) analyzed locally on the founder's Mac via `npm run analyze-previews`: batch iTunes lookups (residential IP) → 30s preview download (cached, checkpointed, transient/terminal-disciplined) → afconvert decode → essentia.js (WASM, Node; 'degara' tempo method chosen for verified determinism). Zero failures across the full run. **Honesty rule held:** only tempo/key/mode/energy/danceability/loudness written, `source='local_preview'` (reversible by source); valence/acousticness/instrumentalness/liveness/speechiness stay NULL — no fabricated proxies. **Calibrations (recorded per review):** energy = RMS dBFS mapped over a −30..−5 dBFS window into [0,1]; loudness = 20·log10(RMS) clamped [−60,0] (dBFS approximation — ReplayGain was rejected: it returns gain-to-apply, sign-inverted vs ReccoBeats loudness); danceability = Essentia raw /3 clamped [0,1]; degenerate audio (near-silence, BPM outside 40–250) throws rather than writing plausible-looking garbage. Known estimator limit: degara collapses tempo octaves internally (a true 190 BPM track may read ~95). GetSongBPM leg of the waterfall: NOT needed (100% ≥ the 80% gate).
