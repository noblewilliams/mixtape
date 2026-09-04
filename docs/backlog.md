# Backlog & open items

Single consolidated list. Detail lives in `decisions.md` (rationale) and the plan files under `superpowers/plans/` (specs). Last updated 2026-09-01 — v1 phases P1/P2/P2.5/P3/P4 are complete and founder-verified; artwork Phase 1 is deployed.

## Owed right now

- **Listening-export import, phase 1 (server):** spec `superpowers/specs/2026-09-01-listening-export-import-design.md` (rev 3), plan `superpowers/plans/2026-09-01-listening-export-p1-server.md`. Phase 1 (server) and phase 2 (Spotify import on iOS and web: parsers, import services, screens, queue outputs, Files hand-over) are code-complete locally as of 2026-09-04 (server 1084 / web 310 / client 535 tests green, simulator build OK; plan `superpowers/plans/2026-09-02-listening-export-p2-spotify-import.md`). Still gated on the founder: apply migrations 0018–0019 and deploy the Worker from a clean worktree, deploy the web app, cut a TestFlight build, and run the real-export smoke once the Spotify and Apple exports arrive. Phase 3 (enrichment by id, ISRC cross-link, artwork), 4 (relay and embed probes), and 5 (Apple "go deeper") follow. Spotify listeners bring their Account data + Extended streaming history exports; Apple export is an optional "go deeper" step. Phase 1 is the schema, staged import protocol, day ledger, derivations, play-derived pool candidates with ISRC dedupe, corpus mode behind the interview, seeds, funnel events, and enrichment priority. Phases 2–5 (parsers + UI on iOS and web, enrichment by id, relay/embed probes, Apple adapter) follow phase by phase; the founder's own exports were requested 2026-09-01 and seed the fixtures.
- **Ship web sync and consumption:** source-aware, deletion-safe song sync; web MusicKit pagination/normalization; playlist upload; honest recent/playlist familiarity; bounded staging cleanup; and the web browse/memory/session API client are code-complete locally. The approval board is `docs/mockups/2026-09-01-web-sync-playlist-states.html`. Next: approve the dedicated `Your music` product flow, implement those UI states, and run authorized probes across the launch browser matrix for duplicate playlist identity and playback behavior, with Android Chrome as a launch-critical target. Do not deploy or read the founder library until the normal reviewed migration/deploy and action-time privacy gates.
- **Roll out playlist intelligence Phase 2:** the read-only native snapshot, deletion-safe staged sync, per-user storefront persistence, browse APIs, defensive client contracts, and bounded staging cleanup are code-complete locally. Next: apply migrations 0012–0014 from a clean worktree, deploy the exact reviewed Worker, run the first private founder sync, and compare counts/order/artwork against Apple Music. Taste scoring, conversational editing, mutation, and browse UI remain later phases.
- **Playlist probe side effect is inconclusive:** the founder reported that both disposable playlists currently looked ordered, but the Music-created candidate may have lost one song. There is no pre-probe snapshot to resolve it. Run no further mutation probe in Phase 2; the new read-only snapshot becomes the baseline for future conflict detection.

## Selected next phase — artwork + playlist intelligence

Founder direction is locked in `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`: pull Apple artwork URL templates/dimensions/background colours; sync ordered playlists for browse and bounded taste scoring; support playlist-inspired mixes; then let a listener open a playlist and talk through an exact draft. The founder-device probe rejected exact rebuild for both the current Mixtape-created and Music-created disposable playlists, so the first apply contract is append-only only where that narrower operation is separately verified, and revised-copy for insertion/removal/reordering. Exact in-place rebuild is deferred until a `MusicLibrary.createPlaylist` path passes a separate device probe.

The iOS minimum is locked to 16 before playlist sync ships; no iOS 13–15 fallback. Execution order: (0) Cloudflare-runtime catalog + iPhone playlist-ownership spikes, (1) artwork metadata, (2) deletion-safe playlist sync and browse APIs, (3) playlist taste/seeds, (4) conversational drafts + catalog discovery, (5) native apply + approved UI state board. Phase 0–1 is complete in production: 4,686/4,689 tracks have valid artwork and background colours, three are scheduled 30-day catalog no-match retries, and zero failed. Phase 2 is locally code-complete and awaits its migration/deploy/private-sync gate; it establishes collection and browse contracts only.

## Next big phase: v2 — "The DJ learns" (vision.md milestone 2)

P4 built v2's foundation (taste term + memory). What remains, in ascending difficulty — recommended sequencing: smoke P4 → TestFlight → ~2 weeks of daily use → spec v2 starting with arcs:

1. **Richer arcs (warm-up → peak → cool-down).** Queues engineered as an energy journey, not just well-ordered picks. Pure server-side sequencing work over the already-scored pool (features now 100%). This is THE designated evidence case for the Opus-escalation contingency (CLAUDE.md): if Sonnet's arc ordering disappoints, escalate only the sequencing pass. Cheapest pillar, felt in every tape.
2. **Anticipatory sessions ("your usual Friday wind-down?").** Data already exists — sessions carry timestamps + prompts. A pattern job spots time-of-day/mood habits; Home offers a one-tap suggested session instead of a blank prompt.
3. **Automatic playback feedback (skips/repeats/completions).** Hardest + most valuable. CONSTRAINT: playback hands off to the Music app, so skips are currently invisible to us. Options: observe `systemMusicPlayer` state while the app is alive (partial signal), or build in-app playback via `ApplicationMusicPlayer` (vision explicitly allows both) so the whole session is observed and every skip becomes a free taste signal. Deserves its own spec — in-app playback also changes the product feel (the tape plays inside mixtape).

**Earlier-than-v2 candidate (compounds with time — consider starting soon):** the per-day listening ledger (vision.md "Deeper history"): snapshot per-song play counts on every sync and store the diffs — Apple never exposes per-day history, so the ledger only exists from the day sampling starts. Cheap to begin (a snapshots table + diff on ingest), pays into recency-aware taste, "on this day" sessions, and the v4 social layer. Playlist snapshots now supply the other missing raw input: a later phase can turn eligible user-curated membership into a bounded explicit taste term without treating editorial or Mixtape-generated membership as preference.

Then **v3 — web + reach**: first-class Apple Music web access for listeners who cannot or choose not to use the native iOS app (no native play counts; same backend), App Store release, licensed-lyrics deal when revenue justifies (see vision.md milestone 3). Then **v4 — social taste layer** (added 2026-08-30): blend sessions from multiple people's taste graphs, taste-twin similarity matching over user embedding vectors, catalog discovery beyond the library — see vision.md v4 + Deeper history sections; needs v3's user base + an opt-in privacy model first.

## Next candidates (unordered, founder picks)

- **UI copy → locked terminology** — align "The tape" card, "queue updated · vN" chips, and any queue-wording to the mix / play now / create-playlist vocabulary (decisions.md 2026-08-30).
- **Mix version history (founder request, P4 smoke)** — the transcript's "queue updated · vN" chips are inert; you can't view or restore an earlier version of a mix. BLOCKER FIRST: retention — `replaceQueue` deletes the previous version's active rows on regenerate, so old versions aren't reconstructible today. Design: version-ranged queue rows (or per-version snapshots) → tappable chips showing that version → "restore" action (a new version copying an old one). Compounds with the regen bug fix above (surgical edits make versions cheap diffs).
- **TestFlight upload / release install** — debug builds only run tethered to `flutter run`; daily use wants `flutter run --release` or TestFlight (which was always the v1 distribution plan).
- **Git remote** — the repo has NO remote; it exists only on this machine. Push somewhere before it matters.
- **Behavioral memory distillation** — a periodic job that turns swipe/keep patterns into memory notes (founder deferred at P4 design time; the live `remember_preference` tool shipped instead).
- **People as first-class memory ("remembered companions")** — founder request 2026-08-30, from the P4 smoke: describing a friend's taste in a session prompt ("Ose likes Tems and mellow afro house") does NOT auto-save, by the durable-vs-one-off rule — correct default, but the DJ should be able to remember named people and their tastes so "tape for me and Ose" just works without re-describing him. Works today via an explicit "remember: Ose likes…" note; the feature version = structured person-scoped memories (name → taste sketch), applied only when that person is mentioned. Bridge to v4 blends: a blend for a friend who isn't a user yet is exactly a companion memory.
- **Profile name** — account `name` was set manually via SQL for the founder; a real profile field would feed playlist attribution (see queue_screen save dialog) and any future social surface. Apple only discloses the name at first-ever sign-in, so capture it at sign-up for future users.
- **Web integration** — Better Auth, session/memory/playlist APIs, MusicKit JS playback and library reads, staged sync, and Apple playlist creation are wired. Apple + Google login, explicit account linking, and the last-used provider hint are implemented. The approved production UI still needs to surface real sync, playlist browse/detail, memories, and rename/archive controls. Web cannot contribute native iOS per-song play counts by design; recent order and playlist membership cover that capability gap without inventing counts.

## Deferred polish (recorded during reviews; none are gates)

Client:
- Undo/confirmDismiss on queue-screen swipe-remove (P3b Task 5 review, finding 10).
- Sync terminal-state notice when the sync sheet is closed mid-sync (SyncDone/SyncFailed invisible from the AppBar icon).
- Auth-lifecycle cluster: sign-out token revocation, stale keychain on reinstall, in-memory token cache.
- Queue-intent FIFO could be hoisted into a provider so pop-mid-drain doesn't drop trailing intents (rare).

Server / DJ:
- Memory-note paraphrase bloat: dupes are exact-match only ("No jazz" ≠ "no jazz"); watch the 50-cap, revisit similarity dedupe if it bites.
- Taste artist matching is exact-string: 'Wizkid' vs 'Wizkid & Ayra Starr' are unrelated artists — fragments signal on collab-dense libraries; a real artist entity would fix it.
- Keep-boost saturates around ~8 played sessions (documented in pool.ts); revisit normalization if fam+taste over-anchor comfort picks.
- `analyze-previews` front-loads all downloads before analysis (operator UX); interleaving fetch/analyze chunks recorded as deferred (P2.5 Task 3 review).
- Opus-for-sequencing escalation stays a contingency: only with evidence of Sonnet ordering poorly (see CLAUDE.md).
- Playlist tables and contracts keep Apple-flavored column names (`apple_library_id`, `apple_library_entry_id`) while carrying opaque Spotify fingerprint keys; rename to `source_*` when the tables are next touched for another reason (listening-export spec, naming debt).
- Listening-export: a track row holding both `spotify_id` and `apple_id` is swept by the Spotify liked-removal and delete-source rules even when its library membership came from an Apple export; revisit when phase 3's ISRC cross-link starts producing dual-id rows (Task 3 review, 2026-09-02).
- Listening-export re-import cannot lower a play count (`GREATEST` merge); delete-import is the reset. A removed Apple library song with three plays in the last two years re-enters the pool; session removals still penalize it. Both accepted 2026-09-01.

## Reopen clauses (from decisions.md — conditions, not tasks)

- Spotify Web API integration if their access policy changes; the export path ships regardless (decisions.md 2026-09-01).
- Neon managed auth if it ships Sign in with Apple.
- GetSongBPM leg of the enrichment waterfall — currently NOT needed (features at 100%); reopens only if coverage regresses (requires visible getsongbpm.com backlink in UI).
- Musixmatch licensed-lyrics deal at scale (lyrics stay derive-don't-display until then).
- iTunes lookup from Workers if Apple unblocks datacenter IPs (currently residential-only; local scripts use it).
