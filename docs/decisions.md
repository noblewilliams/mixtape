# Decision Log

Short ADR-style log. Newest first. Each entry: decision, why, and what would reopen it.

## 2026-08-31 — Artwork Phase 1 deployed at 99.94% coverage
Migrations 0009–0010 and reviewed commit `89ecbfc` were deployed to production from a clean worktree. The bounded backfill processed all 4,689 tracks in 15 batches over 36.3 seconds: 4,686 matched with Apple artwork (99.94%), three were classified `no_match`, and zero failed. Every matched row has a URL, positive dimensions, normalized six-digit `artwork_bg_color`, and `artwork_fetched_at`; integrity checks found zero partial/invalid rows, and a metadata-free three-image sample rendered 3/3 JPEGs. Existing enrichment remained unchanged at 4,689 feature rows, 4,447 meaning rows, and 4,327 embeddings. The three no-matches remain retryable after the pinned 30-day window rather than being permanently exhausted. **Reopens if:** coverage materially regresses, sampled Apple URLs stop rendering, or production begins returning persistent catalog authorization/upstream failures.

## 2026-08-31 — Current playlists cannot use MusicKit exact rebuild
A founder-iPhone probe refetched two non-empty disposable playlists through MusicKit for Swift—one created through Mixtape's current `MPMediaLibrary.getPlaylist` flow and one created directly in Music—and resolved their ordered entries. `MusicLibrary.shared.edit(...items:)` rejected the same-order rebuild for both. The probe returned fixed categories only and was removed completely afterward. Therefore `is_mixtape_owned` records provenance but does not imply rebuild capability: current Mixtape-created and external playlists may be synced, browsed, and used as taste/context, while in-place writes are limited to separately verified append-only operations; insertion, removal, or reordering must create a revised copy. Phase 2 playlist sync/browse may proceed, but no apply plan may return `rebuild`. Exact rebuild reopens only after Mixtape creates playlists through `MusicLibrary.createPlaylist` (or Apple changes the contract) and that path passes a new device probe.

## 2026-08-31 — Apple catalog approved from Cloudflare Workers
Apple Music catalog requests are approved for the server artwork pipeline. A temporary Worker running through Cloudflare remote development signed a server-only MusicKit token and queried the Nigerian storefront: one known catalog ID matched with valid artwork and a valid background colour. An unknown ID returned a sanitized zero-match result, and an invalid admin token returned 401 before catalog construction. The probe returned counts/booleans only and was removed immediately afterward. Phase 1 may use the typed catalog client from Workers; it must retain fixed-category errors and never log Apple bodies, tokens, artwork URLs, colours, or track metadata. **Reopens if:** production calls begin returning persistent Apple authorization/infrastructure failures or measured artwork coverage indicates a storefront/catalog-ID mismatch.

## 2026-08-31 — iOS 16 minimum for playlist intelligence
Mixtape's current iOS 13 deployment target will rise to iOS 16 before playlist sync ships. The playlist design depends on `MusicLibraryRequest` and `MusicLibrary`, which the installed Apple SDK exposes on iOS 16+, and retaining iOS 13–15 would require a second MediaPlayer browse path that still could not provide exact conversational playlist editing. One supported path is cleaner and appropriate for the founder/friends distribution. Artwork-only server work may land before the target bump. **Reopens if:** distribution evidence identifies a required listener device that cannot run iOS 16.

## 2026-08-31 — Artwork metadata + playlists as taste and editable DJ workspaces
Album artwork is stored as Apple's URL template, dimensions, and normalized six-digit `artwork_bg_color`; image bytes do not enter Postgres. Apple Music playlists are synced as ordered, deletion-safe snapshots, exposed for browsing, and used as a bounded explicit taste signal only when they represent user curation—not Apple editorial/personalized output or the DJ's own generated output. Opening a playlist creates a separate playlist-edit conversation and exact server draft; Apple Music changes only after review/apply. Mixtape-owned playlists may be rebuilt in order only when a device spike verifies the exact creation path; the current `MPMediaLibrary` path was later rejected and is narrowed by the decision above. External playlists receive direct append only when the approved result is truly append-only; insertion/removal/reordering creates a revised copy and leaves the source untouched. Catalog discovery is allowed for playlist edits, while Music User Tokens remain client-managed and are never stored server-side. Spec: `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`. **Reopens if:** Apple expands full editing to externally-created playlists, a future MusicKit creation path passes exact-rebuild verification, or Worker catalog calls fail from production infrastructure.

## 2026-08-30 — Web foundation: React + Vite + TypeScript, UI-first integration
The approved tape-and-glass identity is now implemented as the first web milestone in `web/`. The UI uses typed local fixtures that mirror the live Hono session/message/queue contracts, keeping visual implementation separate from authentication and MusicKit JS debugging. The production shell includes the flat three-zone conversation, cassette-derived controls, single-shelf Closet, accurate cassette asset, full-screen preparation motion, and responsive queue behavior. **Next boundary:** replace the local state seam with Better Auth + `/sessions` + `/me/memories`, then add MusicKit JS playback and playlist writes. Web still cannot supply native iOS per-song play counts. **Reopens if:** an integration constraint proves the current client-side domain shapes do not match the live API contract.

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

## 2026-08-30 — P4: taste learning + per-user DJ memory (deployed)
The DJ now learns two ways. **(1) Memory notes** — a `remember_preference` tool lets the DJ save short preference facts the listener states in chat (cap 50/user, unique per (user, note), exact-match dupes only — paraphrase bloat is the known failure mode, revisit if it bites). Notes are stored raw and sanitized at RENDER time, injected at user altitude only (never system), and reach track selection via sessionContext into the curation request — that channel is test-pinned. A "What the DJ knows" screen (Home AppBar) lists notes with swipe-to-forget (one undo window at a time; a new swipe finalizes the previous delete). **(2) Taste term** — scoring gained a fourth convex weight (taste = 0.12, sim/feat/fam scaled by 0.88): per-artist, [0,1] around 0.5-neutral, from user-removed queue rows (weight 1.0) vs artists kept in played/saved sessions (weight 0.25 — active rejection beats passive acceptance 4:1), squashed via 0.5+0.5·tanh(0.3·net), 90-day half-life decay, distinct-session counting (client event spam can't multiply influence), in-session removal dominance (a swipe-away isn't cancelled by the artist's surviving tracks). Taste never gates the pool — rerank only, bounded ±0.06. Known v1 limits (recorded): exact-string artist matching fragments collab credits; keep-boost saturates ~8 sessions; events on archived sessions accepted; `saved_playlist` only posted when ≥1 track actually saved. Client posts played/saved_playlist events fire-and-forget from success branches only. Migrations 0006–0008 applied to prod 2026-08-30.

## 2026-08-30 — Vision amended: social taste layer + deeper history (founder)
Founder additions to vision.md: (1) the "not a social app" stance is AMENDED — mixtape stays feed-free, but gains a v4 social milestone: blend sessions from multiple people's taste graphs + "taste twins" similarity matching (user taste vector = play-count-weighted embeddings; opt-in, libraries never exposed raw). (2) "Deeper history" additions: ingest the user's existing playlists as explicit taste signal + seeds (v1 gap — we sync songs, not playlist memberships); build a per-day listening ledger by snapshot-diffing play counts across regular syncs (Apple exposes no per-day history — the diff IS the history; compounding, so start sampling early); catalog discovery beyond the library for the adventurous end of the familiarity dial. Sequencing unchanged: these slot into v2+ (ledger sampling could start earlier since it compounds); backlog.md updated.

## 2026-08-30 — Terminology locked (founder): mix / play now / create playlist
Talking to the DJ asks for the creation of a **mix** (the tracklist formerly called "queue"/"tape" interchangeably). A created mix has two actions: **play now** (add it to the Apple Music queue and start it) or **create as playlist**. Use this vocabulary in all docs, specs, conversations, and — as a backlog item — align UI copy ("The tape", "queue updated · vN") to it. The DB/table naming (queue_tracks etc.) stays as-is; this is product language, not a schema rename.

## 2026-08-30 — P4 smoke finding: DJ regenerates the whole mix on a single-track removal (OPEN)
Live-confirmed in session "Smooth Cruise Through Lagos": a message that asked to save a preference AND avoid one track ("MINIMAL FUSS") produced a wholesale queue replacement (v1→v2, all 13 tracks different) instead of an edit_queue remove. Root cause: the system prompt doesn't instruct that a standing mix is preserved by default — surgical edit_queue ops for removals/swaps, full generate_queue ONLY when the brief itself changes. Side effect: regeneration also bypasses removed-row provenance, weakening taste signals. Fix owed: prompt hardening + live re-verify (queued behind the in-flight session-rename change to avoid file collisions).

## 2026-08-30 — P4 SMOKE PASSED → v1 COMPLETE end-to-end
Founder device smoke: memory save (with scoping + one-track veto folded in) ✓, note visible in "What the DJ knows" ✓, swipe-to-forget with undo and expiry ✓, play now ✓, create playlist ✓, Haiku titles ✓, brief-honoring mix ✓. The two-session artist-swipe taste nudge is deliberately subtle — marked "observe over daily use" rather than a gate. Smoke yield (all recorded above/backlog): the regen-on-small-edit bug (OPEN), session rename (in progress), mix version history (backlog, retention blocker noted), remembered-companions idea, locked mix/play-now/create-playlist terminology. All five v1 phases are now founder-verified on device.

## 2026-08-30 — Regen-on-small-edit bug FIXED + verified; deploy discipline lesson
Fix `5b41a91`: PERSONA_PROMPT gained a "standing mix is precious" rule (edit_queue with smallest ops for removals/swaps — even bundled in a message doing something else; generate_queue only for a new brief or explicit start-over) + both tool descriptions hardened (generate_queue marked DESTRUCTIVE). Live-verified against prod: "drop track 3 and change nothing else" removed exactly one track, order preserved ("Dropped Morocco — rest of the mix stays untouched"). Session rename (chat tool + PATCH + long-press, `32099f0`/`16abd42`) is deployed server-side; the client half rides the next app rebuild. INCIDENT + RULE: a `wrangler deploy` from the working tree bundled a PARALLEL agent's uncommitted src changes (auth WIP requiring an unset env var) → ~3-minute prod 500 outage, recovered by redeploying from a clean `git worktree` at HEAD. Rule going forward: while any parallel session may have uncommitted changes, ALWAYS deploy from a clean worktree of the committed state, never the working tree.
