# Decision Log

Short ADR-style log. Newest first. Each entry: decision, why, and what would reopen it.

## 2026-09-04 — Confirmed playlist origin gates explicit taste
Playlist collection is not proof of authorship. The existing `is_mixtape_owned` flag had no writer, native playlist kinds do not positively establish hand-built curation, and web editability is not an origin guarantee. User-approved expansion: add creation provenance on iOS/web and gate scoring conservatively. Migration 0021 adds listener/source/provider-ID origin records independent of sync snapshots. A client creation receipt must reference a mix owned by the authenticated listener; it can arrive before sync and survives rename, disappearance and reappearance. The record is client-attested, not independently Apple-verified. Mixtape receipt/legacy ownership wins over user confirmation, and names/descriptions never establish origin.

Existing playlists stay `unknown`. `PUT /playlists/:id/taste-confirmation` accepts an explicit reversible declaration from their owner; automatic/editorial and known Mixtape playlists cannot be confirmed. No UI auto-confirms anything; a confirmation surface needs a later approved browse design. Deleting a Spotify import clears its confirmations. Account deletion cascades all origin evidence. Creation callbacks record exact provider IDs; a missing ID or upload failure leaves origin unknown and must never turn a completed creation into a retryable save error.

In personal pools only, distinct active confirmed playlists contribute `0.10 * (1 - 0.5^min(n,10))` per recording (ISRC, falling back to track ID). One playlist contributes 0.05; two 0.075; the maximum is 0.09990234375. Playlist membership no longer also contributes to familiarity: observed counts or web recent rank carry that term. Learned per-artist taste stays 0.12; meaning/feature/familiarity weights retain their preset proportions over the remaining 0.78. Corpus mode is unchanged. This reranks existing candidates only; it does not admit playlist-only tracks, bypass prompt filters, invent plays, or penalize disappearance. Playlist-as-seed and conversational edits remain later slices.

iOS creation now uses typed `MusicLibrary.createPlaylist` and sequential `add` operations so it returns a MusicKit playlist ID rather than guessing across MediaPlayer identity types. The existing added/failed outcome stays intact. This new creation path requires an authorized founder-device smoke before release and does not enable exact rebuild. No production migration/deploy is implied by local verification. **Reopens if:** real-device ID reconciliation fails, author attribution/order changes, receipt loss is frequent enough to require a durable retry outbox, or listening evidence warrants changing the initial score weight.

## 2026-09-01 — Web glass is one session-painted content plane
Primary web views own one subtle animated background plane; navigation, the mix rail, and mobile top chrome
sit above it as translucent neutral glass and never animate independently. An open mix uses the stable
cassette color already derived from its session ID, while Home uses the slate house paint, so renames and
queue refinements cannot cause color jumps. The plane follows a 10-second multi-direction path with no hue
cycling or moving blur. Dark mode uses the same paint identity as a low-light reflection over graphite;
authentication and dialogs remain neutral. Reduced motion freezes a balanced frame, and reduced transparency
uses opaque surfaces. Approval: `docs/mockups/approved/2026-09-01-web-shared-content-plane-liquid-glass.md`.
**Reopens if:** real-device testing shows the motion distracts from reading, browser rendering makes the
session color unstable, or translucent chrome cannot hold contrast over supported paints.

## 2026-09-01 — Web is a first-class Apple Music client
The web is a first-class sync and listening client for anyone who cannot or chooses not to use the native
iOS app; Android listeners are a launch-critical audience, not a platform-specific product boundary. The
web is not limited to browsing an iPhone-produced snapshot. MusicKit on the Web reads library songs,
playlists, playlist entries, and recent tracks, then uploads normalized snapshots through the same private
Mixtape API without sending or storing the Music User Token. Web-derived taste intentionally lacks native
play counts: missing counts stay unknown and playlist membership, recent order, and Mixtape behavior carry
more of the ranking load. The existing playlist staging work remains valid and gains a browser adapter;
song-library ingestion gains its own deletion-safe staged completion protocol. Design:
`docs/superpowers/specs/2026-09-01-web-sync-consumption-design.md`. **Reopens if:** Apple removes web library
or playback access, the supported browser matrix cannot preserve playlist order/duplicates, or web launch
expands beyond Apple Music subscribers.

## 2026-09-01 — Web removal Undo delays the server mutation
The web removes a swiped track from local queue state immediately, but does not send the versioned `remove`
operation until the approved three-second Undo window expires. Undo therefore restores the local row without
needing a new server restore contract. Reorders persist immediately; their Undo submits the inverse versioned
move. Queue operations are serialized per session, and starting a newer mutation finalizes any older pending
removal before enqueueing the new operation so server positions continue to match the visible order. A 409
replaces optimistic state with the authoritative queue returned by the server. **Reopens if:** navigation or
multi-tab testing shows that delayed removal can be lost, or product requirements need removal to be durable
before the Undo window closes.

## 2026-09-01 — Web mix Undo uses a compact flush toast
The approved web mix rail keeps its three-second single-level Undo, but presents it in a compact 38px toast
with 4px vertical padding. Undo is a transparent icon-and-text action with no separate visible container,
countdown, or progress bar; expiry is quiet. This supersedes only the Undo-toast presentation in the original
mix-rail approval. Approval: `docs/mockups/approved/2026-09-01-web-artwork-mix-rail-undo-toast.md`.
**Reopens if:** implementation cannot preserve a comfortably clickable Undo target without visibly increasing
the toast height, or usability testing shows that quiet expiry makes the recovery window unclear.

## 2026-08-31 — Web mix arrangement lives in a persistent artwork rail
The web keeps mix arrangement in a 468px right rail beside the DJ conversation rather than a floating
widget or separate Talk/Mix workspace. Artwork-led rows expose the song reason on hover/focus and use a
three-line handle for reorder. A row-body swipe reveals and proportionally stretches a flush muted-coral
X while moving; releasing at or beyond 65% removes the track, with one-finger pointer/touch and two-finger
horizontal trackpad input sharing the threshold. Reorder and removal both have a single-level three-second
Undo, keyboard parity, live announcements, and a reduced-motion reading; below 1020px the same rail becomes
a sheet. Approval: `docs/mockups/approved/2026-08-31-web-artwork-mix-rail.md`. The current manual queue-ops
API supports move/remove but not restore, so implementation must either delay removal persistence for the
Undo window or add a versioned restore op without changing the approved UI. **Reopens if:** device testing
shows the 65% threshold causes accidental removals, horizontal wheel handling interferes with vertical
scroll, or the 468px rail materially harms the conversation at supported desktop widths.

## 2026-08-31 — Account sign-in is separate from Apple Music authorization
Mixtape accepts Apple or Google as equal Better Auth login methods; Apple Music remains a separate
MusicKit authorization requested only when a listener syncs, plays, or creates a playlist. Better Auth
implicit account linking is disabled: a matching email never merges identities silently. A signed-in
listener may explicitly link a second provider from Account, including an Apple private-relay address and
a different Google address after both OAuth challenges succeed, and may remove one only while another
login remains. The web remembers only the successfully-used provider name (`apple` or `google`) in local
storage so it can label the usual choice; pending attempts stay in session storage and email/profile/token
data is never persisted for this hint. **Reopens if:** provider-linking abuse is observed, Google stops
returning verified emails, or a future passkey/credential flow needs a different recovery model.

## 2026-08-31 — Web auth is same-origin; application API stays direct
Production Better Auth traffic stays on the deployed web origin at `/api/auth/*`, with Netlify proxying
only those requests to the Cloudflare Worker. Direct cross-site auth calls from `netlify.app` to
`workers.dev` were rejected by browser third-party-cookie protection: a live callback replay reproduced
`state_mismatch` without Better Auth's state cookie and passed state validation with the cookie present.
The authenticated web app reads the Better Auth session token into memory and sends it as a bearer token
on direct Worker API requests. This preserves first-party auth cookies without routing 20–40 second DJ
turns through Netlify's 26-second external-proxy ceiling. The token is never persisted in browser storage.
**Reopens if:** the web and Worker move onto subdomains of one registrable custom domain and same-site
cookie behavior is verified end-to-end.

## 2026-08-31 — Artwork Phase 1 deployed at 99.94% coverage
Migrations 0009–0010 and reviewed commit `89ecbfc` were deployed to production from a clean worktree. Starting from 4,689 eligible tracks, the operator processed 4,389 in 15 calls over 36.3 seconds while the enabled schedule processed the other 300 concurrently. Final measured coverage: 4,686 matched with Apple artwork (99.94%), three were classified `no_match`, and zero failed. Every matched row has a URL, positive dimensions, normalized six-digit `artwork_bg_color`, and `artwork_fetched_at`; integrity checks found zero partial/invalid rows, and a metadata-free three-image sample rendered 3/3 JPEGs. Existing enrichment remained unchanged at 4,689 feature rows, 4,447 meaning rows, and 4,327 embeddings. A reviewed hardening pass then applied migration 0011 and deployed commit `b636677` as Worker version `41135e7f-3f98-4fa9-b2ba-207a7f7585ad`; live health/auth checks passed, the same coverage counts remained intact, the runner lock schema verified, and a fresh three-image sample rendered 3/3 JPEGs. The three no-matches remain retryable after the pinned 30-day window rather than being permanently exhausted. **Reopens if:** coverage materially regresses, sampled Apple URLs stop rendering, or production begins returning persistent catalog authorization/upstream failures.

## 2026-08-31 — Current playlists cannot use MusicKit exact rebuild
A founder-iPhone probe refetched two non-empty disposable playlists through MusicKit for Swift—one created through Mixtape's current `MPMediaLibrary.getPlaylist` flow and one created directly in Music—and resolved their ordered entries. `MusicLibrary.shared.edit(...items:)` rejected the same-order rebuild for both. The probe returned fixed categories only and was removed completely afterward. Therefore `is_mixtape_owned` records provenance but does not imply rebuild capability: current Mixtape-created and external playlists may be synced, browsed, and used as taste/context, while in-place writes are limited to separately verified append-only operations; insertion, removal, or reordering must create a revised copy. Phase 2 playlist sync/browse may proceed, but no apply plan may return `rebuild`. Exact rebuild reopens only after Mixtape creates playlists through `MusicLibrary.createPlaylist` (or Apple changes the contract) and that path passes a new device probe. Manual confirmation that both disposable playlists retained the exact same order after the rejected calls is still outstanding; the rejection evidence alone is not recorded as a successful no-op mutation.

## 2026-08-31 — Apple catalog approved from Cloudflare Workers
Apple Music catalog requests are approved for the server artwork pipeline. A temporary Worker running through Cloudflare remote development signed a server-only MusicKit token and queried the Nigerian storefront: one known catalog ID matched with valid artwork and a valid background colour. An unknown ID returned a sanitized zero-match result, and an invalid admin token returned 401 before catalog construction. The probe returned counts/booleans only and was removed immediately afterward. Phase 1 may use the typed catalog client from Workers; it must retain fixed-category errors and never log Apple bodies, tokens, artwork URLs, colours, or track metadata. **Reopens if:** production calls begin returning persistent Apple authorization/infrastructure failures or measured artwork coverage indicates a storefront/catalog-ID mismatch.

## 2026-08-31 — iOS 16 minimum for playlist intelligence
Mixtape now targets iOS 16 consistently before playlist sync ships. The playlist design depends on `MusicLibraryRequest` and `MusicLibrary`, which the installed Apple SDK exposes on iOS 16+, and retaining iOS 13–15 would require a second MediaPlayer browse path that still could not provide exact conversational playlist editing. One supported path is cleaner and appropriate for the founder/friends distribution. **Reopens if:** distribution evidence identifies a required listener device that cannot run iOS 16.

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

## 2026-09-01 — Listening-export import: Spotify via the listener's own export; Apple export as "go deeper" (founder)
Spec: `docs/superpowers/specs/2026-09-01-listening-export-import-design.md` (rev 3). Eleven decisions approved together:
1. Spotify support ships via the listener's own data export (Account data + Extended streaming history), never the Web API (Feb 2026: 5 users/app, Premium required, batch track endpoint removed). **Reopens if:** Spotify's API policy changes.
2. Apple's Media Services export is an optional "go deeper" step; iOS live sync stays the primary Apple path.
3. Export parsing happens on the listener's device; archives and personal-data files never reach Mixtape. No server endpoint accepts a file.
4. The listening ledger is per track per day (`listening_days`); per-play rows only when a feature needs play order or exact timestamps.
5. `spotify_id` joins `apple_id` as a peer identity column; rows for one recording link by ISRC, the pool dedupes on it, and a physical merge is deferred.
6. A play is 30 seconds or more. Pool candidates are library, seeded, or three counted plays in the last 730 days.
7. Private-session (incognito) plays are excluded unless the listener opts in at the inventory step.
8. A mix before any data requires the DJ interview and at least 25 seed-matched corpus tracks across 3 artists, and is labeled "not personal yet".
9. iOS and web parsers share one contract and one fixture suite; the Spotify import ships on each surface as soon as it is ready; the Apple adapter is web-first.
10. An export is backfill; a scrobble relay (ListenBrainz or Last.fm) is the intended live feed, pending the phase-4 probe.
11. Connected music sources are a set per listener (`user_music_sources`), not a single platform column.
Accepted edges recorded in the backlog: a re-import cannot lower a play count (delete-import is the reset); a removed Apple library song with three recent plays re-enters the pool.

## 2026-09-04 — Playlist catalog materialization reuses global enrichment
The first follow-on to playlist collection resolves exact Apple catalog IDs from active Apple playlist entries into global `tracks`, using the listener's persisted storefront. Existing canonical records link without a network lookup; new records require a catalog-confirmed song, never fuzzy title/artist matching or authoritative metadata copied from playlist snapshots. Store validated artwork (including `artwork_bg_color`) and normal catalog metadata, then let the existing feature, meaning, and artwork jobs consume the new records. No `user_tracks`, play counts, saved-library membership, or source connection is created by resolution. Playlist order, duplicate occurrences, source fingerprints, and snapshots remain unchanged.

The scheduled resolver claims at most 25 IDs in one storefront per run, with a five-minute lease and fenced completion. Relinking is separately capped at 1,000 entries per pass (before lookup and, when a batch was claimed, after completion). Network calls hold no database transaction open. Global retry state contains only public catalog IDs, storefront, and fixed operational categories; misses and failures have bounded retry delays, not permanent exclusion. Removed playlists are rechecked after the catalog request. Concurrent imports retain their canonical metadata. Resolver failure is isolated from existing enrichment and cleanup work.

This is a local implementation milestone: migration 0020 is prepared, not applied. Release requires a reviewed committed snapshot, approval for production migrations/deployment, and a private smoke. Export migrations 0018–0019 have their own rollout gate; do not silently deploy unrelated local work. Spotify enrichment/ISRC cross-linking, richer playlist taste/seeds, browse UI, conversational drafts, and verified native apply are not delivered by this slice. In particular, resolve the documented dual-ID source-deletion issue before cross-platform identity writes.


## 2026-09-04 — Saved-library membership belongs to listener sources

Before Phase 3 adds cross-platform identity links, persist the source that saved
each track for each listener in `user_track_library_sources`. Global Apple and
Spotify IDs cannot establish ownership. `user_tracks.in_library` is the union
of surviving memberships. Spotify account snapshots replace Spotify membership;
completed Apple library snapshots replace live Apple membership; Apple media
imports and the older paged native ingest remain additive for their own source.
Deleting an export removes only its membership, leaving another source, seeds,
and remaining listening history protected. The blanket `apple_live` removal
bypass is superseded; `likedRemovalSkipped` stays in the wire contract and is
false for new runs. Previously completed summaries remain unchanged.

Migration 0022 preserves existing saved rows as `legacy`: expiring staging data
and catalog IDs cannot reconstruct historical ownership reliably. Later source
removal or sync does not discard those unknown memberships. This favors retaining
saved music over silently removing it; an explicit historical reconciliation
flow is owed separately. All membership writes and derived flags publish in one
transaction under the listener-profile lock, including the paged native endpoint.
No physical track merge, play-count semantics, playlist-origin cleanup, or UI
change is included. Plan: `superpowers/plans/2026-09-04-library-source-ownership.md`.
This is local work; migration application and deployment remain release gates.


## 2026-09-04 — Apple ISRC matches use the listener's market

The user approved this rule for Spotify imports: use the listener's saved Apple
storefront, otherwise their import country in lowercase, and wait if neither is
known. Do not substitute the founder's Nigerian storefront for unknown users.

A bounded maintenance job queries Apple by exact ISRC. Only one complete,
validated catalog result may populate an unowned `apple_id`; missing, ambiguous,
or conflicting results stay unlinked. A unique-index race never overwrites an
owner or causes a physical track merge. Fill missing metadata and valid artwork
while preserving existing values and all listener state. Catalog identity does
not imply availability in every listener's market.

Migration 0023 records the successful `apple_catalog_storefront` on the track,
which artwork refresh then uses. Existing tracks retain a null value and the
older artwork fallback setting. Its `apple_isrc_lookups` table separates retries
by track, ISRC, and storefront, with short fenced claims, fixed error categories,
and no private source payloads. The ISRC request runs outside a transaction and
completion rechecks the source, market, and identity. Scheduler failure remains
isolated from artwork/enrichment/cleanup.

Plan: `superpowers/plans/2026-09-04-apple-isrc-linking.md`. This local slice depends
on the migration-0022 membership fix. It does not ship Spotify fallback artwork,
change playlists or session behavior, or bypass migration/deployment approval.

## 2026-09-04 — Playlist inspiration is session context, not taste

An ordinary mix session may explicitly select one active playlist owned by the
listener as a read-only inspiration source. The selection persists across
follow-ups and has revision-checked replace/clear semantics. Name lookup is
literal, active, user-scoped, capped, and ambiguity asks instead of guessing.
Selecting a playlist never edits it, changes the queue by itself, admits tracks
outside existing candidate rules, or creates saved-library/play/taste evidence.
Original source songs may compete unless the listener asks for different songs;
then every resolved source recording and ISRC sibling is excluded.

The live profile requires 3 resolved recordings and deterministically samples at
most 200 identities with at most 5 per normalized artist. It adds a bounded 0.15
pre-limit score while preserving learned taste 0.12 and confirmed-playlist 0.10;
missing axes are neutral. Prompt constraints win. Playlist-derived context is
sanitized at USER altitude. Queue commits recheck selection revision, source
activity/fingerprint, and queue version after curation; an unavailable or changed
source preserves the current mix. Migration 0024 and its matching Worker are deployed.

## 2026-09-04 — Spotify fallback artwork keeps identity exact

For a current Spotify-import track still lacking an Apple ID and artwork after
Apple ISRC matching, request the official Spotify oEmbed endpoint by exact
Spotify ID. Store only a strictly validated fixed thumbnail from legacy
`i.scdn.co` or the anchored Spotify-owned
`image-cdn-<letters>.spotifycdn.com` namespace. After a valid oEmbed miss,
Deezer may be tried only when the track has a valid ISRC; the response must
repeat that ISRC and expose either exact host `e-cdns-images.dzcdn.net` or
`cdn-images.dzcdn.net`. Existing HTTPS, path, length, no-credentials, no-port,
no-query, and no-fragment rules still apply. This artwork is display metadata.
It never creates an Apple/Deezer identity, merges a row, or changes listener
membership, plays, taste, playlists, or mixes.

The maintenance job claims at most three priority tracks for five minutes using
the existing artwork retry state. Attempts fence expired or superseded work.
Provider calls run outside transactions; completion rechecks the active completed
Spotify source, Spotify ID, ISRC, Apple ID, existing artwork, and claim before a
conditional write. Apple linking clears any earlier fallback retry. Requests
time out after five seconds, response bodies are capped at 256 KiB, and stored
errors/results contain fixed categories and counts only.

Deezer's exact-ISRC route lacks a stable public reference, so it remains a
guarded best-effort fallback even though the 2026-09-06 binding-free Cloudflare
edge smoke succeeded without listener data or a token. That smoke exposed the
current CDN hosts above; the original deployed allowlists rejected them.
Isolated commit `b8f8393` keeps exact/anchored ownership checks and adds
lookalike-host regressions. It passed 78 files / 1,307 tests, typecheck, a Worker
dry-run, and the final Spotify known/missing plus Deezer known edge cases. The
provider-only `cace81e` backport then passed 73 files / 1,263 tests, typecheck,
and a full Worker dry-run before deployment as version
`f2c5014b-a199-4398-bec9-e0dd22ac0d7e`; the next scheduled invocation completed
with zero fallback failures and no eligible fallback rows. The same fix is on
`origin/main` as `ebfe96d`. Spotify oEmbed remains primary.
Plan: `superpowers/plans/2026-09-04-spotify-fallback-artwork.md`; release
sequencing is in `superpowers/specs/2026-09-05-listening-export-release-validation-design.md`.

## 2026-09-05 — Playlist editing has its own bounded DJ loop

Source-playlist editing does not reuse the ordinary mix queue or its tool set.
It runs against an occurrence-aware private draft and exposes only bounded
Apple catalog search plus versioned draft edits. Provider and model calls stay
outside write transactions; Apple writes and apply-mode selection are absent
from the loop. Catalog additions must come from a search result returned in the
same turn, direct artist and album constraints are hard filters, existing songs
are excluded, and `best_fit` placement is computed deterministically from
neighbour metadata. Playlist names, entries, and transcript content remain at
USER altitude in a bounded prompt. **Reopens if:** a provider offers a stronger
transactional playlist editor or production evidence shows the separate loop
cannot meet latency or placement quality targets.

## 2026-09-06 — First playlist write is an idempotent revised copy

Applying a reviewed playlist draft first creates a new Apple Music playlist and
leaves the Apple or Spotify source untouched. The server prepares one immutable,
versioned `revised_copy` operation only when every desired occurrence has an
exact Apple catalog ID. A fresh native fingerprint must still match an Apple
source; Spotify exports use their immutable imported fingerprint and never gain
Spotify write-back.

The iOS adapter records the operation before creation, records Apple's new
library ID immediately afterward, adds songs sequentially, then verifies the
actual ordered catalog fingerprint. Repeating the same operation reconciles the
stored playlist instead of creating or adding again. A renewed prepare window
keeps the same operation ID, including after expiry, because a new ID could
duplicate an unknown prior result. Only an exact verified result is confirmed;
partial and unknown results remain visible and reconcilable. Append and rebuild
remain disabled. No schema change is required beyond migration 0025.
