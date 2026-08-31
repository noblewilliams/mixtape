# Backlog & open items

Single consolidated list. Detail lives in `decisions.md` (rationale) and the plan files under `superpowers/plans/` (specs). Last updated 2026-08-30 — v1 phases P1/P2/P2.5/P3/P4 are all code-complete and deployed.

## Owed right now

- **P4 founder device smoke** (the only open gate): rebuild the app, then run the script in `superpowers/plans/2026-08-30-p4-taste-learning.md` §Task 5 — state a durable preference → note appears in "What the DJ knows" → new session honors it; swipe an artist away in 2 sessions → rarer next queue; forget → reverts.

## Selected next phase — artwork + playlist intelligence

Founder direction is locked in `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`: pull Apple artwork URL templates/dimensions/background colours; sync ordered playlists for browse and bounded taste scoring; support playlist-inspired mixes; then let a listener open a playlist and talk through an exact draft. The founder-device probe rejected exact rebuild for both the current Mixtape-created and Music-created disposable playlists, so the first apply contract is append-only only where that narrower operation is separately verified, and revised-copy for insertion/removal/reordering. Exact in-place rebuild is deferred until a `MusicLibrary.createPlaylist` path passes a separate device probe.

The iOS minimum is locked to 16 before playlist sync ships; no iOS 13–15 fallback. Execution order: (0) Cloudflare-runtime catalog + iPhone playlist-ownership spikes, (1) artwork metadata, (2) deletion-safe playlist sync and browse APIs, (3) playlist taste/seeds, (4) conversational drafts + catalog discovery, (5) native apply + approved UI state board. Phase 0–1 execution plan: `docs/superpowers/plans/2026-08-31-artwork-capability-spikes.md`. Each phase gets a separate task plan and adversarial review/fix round.

## Next big phase: v2 — "The DJ learns" (vision.md milestone 2)

P4 built v2's foundation (taste term + memory). What remains, in ascending difficulty — recommended sequencing: smoke P4 → TestFlight → ~2 weeks of daily use → spec v2 starting with arcs:

1. **Richer arcs (warm-up → peak → cool-down).** Queues engineered as an energy journey, not just well-ordered picks. Pure server-side sequencing work over the already-scored pool (features now 100%). This is THE designated evidence case for the Opus-escalation contingency (CLAUDE.md): if Sonnet's arc ordering disappoints, escalate only the sequencing pass. Cheapest pillar, felt in every tape.
2. **Anticipatory sessions ("your usual Friday wind-down?").** Data already exists — sessions carry timestamps + prompts. A pattern job spots time-of-day/mood habits; Home offers a one-tap suggested session instead of a blank prompt.
3. **Automatic playback feedback (skips/repeats/completions).** Hardest + most valuable. CONSTRAINT: playback hands off to the Music app, so skips are currently invisible to us. Options: observe `systemMusicPlayer` state while the app is alive (partial signal), or build in-app playback via `ApplicationMusicPlayer` (vision explicitly allows both) so the whole session is observed and every skip becomes a free taste signal. Deserves its own spec — in-app playback also changes the product feel (the tape plays inside mixtape).

**Earlier-than-v2 candidate (compounds with time — consider starting soon):** the per-day listening ledger (vision.md "Deeper history"): snapshot per-song play counts on every sync and store the diffs — Apple never exposes per-day history, so the ledger only exists from the day sampling starts. Cheap to begin (a snapshots table + diff on ingest), pays into recency-aware taste, "on this day" sessions, and the v4 social layer. Related v1 gap: playlist memberships aren't synced — the user's own playlists are the strongest explicit taste signal we don't yet ingest.

Then **v3 — web + reach**: MusicKit-JS web companion (no play counts on web; same backend), App Store release, licensed-lyrics deal when revenue justifies (see vision.md milestone 3). Then **v4 — social taste layer** (added 2026-08-30): blend sessions from multiple people's taste graphs, taste-twin similarity matching over user embedding vectors, catalog discovery beyond the library — see vision.md v4 + Deeper history sections; needs v3's user base + an opt-in privacy model first.

## Next candidates (unordered, founder picks)

- **UI copy → locked terminology** — align "The tape" card, "queue updated · vN" chips, and any queue-wording to the mix / play now / create-playlist vocabulary (decisions.md 2026-08-30).
- **Mix version history (founder request, P4 smoke)** — the transcript's "queue updated · vN" chips are inert; you can't view or restore an earlier version of a mix. BLOCKER FIRST: retention — `replaceQueue` deletes the previous version's active rows on regenerate, so old versions aren't reconstructible today. Design: version-ranged queue rows (or per-version snapshots) → tappable chips showing that version → "restore" action (a new version copying an old one). Compounds with the regen bug fix above (surgical edits make versions cheap diffs).
- **TestFlight upload / release install** — debug builds only run tethered to `flutter run`; daily use wants `flutter run --release` or TestFlight (which was always the v1 distribution plan).
- **Git remote** — the repo has NO remote; it exists only on this machine. Push somewhere before it matters.
- **Behavioral memory distillation** — a periodic job that turns swipe/keep patterns into memory notes (founder deferred at P4 design time; the live `remember_preference` tool shipped instead).
- **People as first-class memory ("remembered companions")** — founder request 2026-08-30, from the P4 smoke: describing a friend's taste in a session prompt ("Ose likes Tems and mellow afro house") does NOT auto-save, by the durable-vs-one-off rule — correct default, but the DJ should be able to remember named people and their tastes so "tape for me and Ose" just works without re-describing him. Works today via an explicit "remember: Ose likes…" note; the feature version = structured person-scoped memories (name → taste sketch), applied only when that person is mentioned. Bridge to v4 blends: a blend for a friend who isn't a user yet is exactly a companion memory.
- **Profile name** — account `name` was set manually via SQL for the founder; a real profile field would feed playlist attribution (see queue_screen save dialog) and any future social surface. Apple only discloses the name at first-ever sign-in, so capture it at sign-up for future users.
- **Web integration** — the approved React/Vite/TypeScript UI milestone is implemented. Wire Better Auth, `/sessions`, `/me/memories`, MusicKit JS playback, and Apple Music playlist creation; web still cannot contribute native iOS per-song play counts.

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

## Reopen clauses (from decisions.md — conditions, not tasks)

- Spotify support if their API access policy changes (schema already platform-agnostic).
- Neon managed auth if it ships Sign in with Apple.
- GetSongBPM leg of the enrichment waterfall — currently NOT needed (features at 100%); reopens only if coverage regresses (requires visible getsongbpm.com backlink in UI).
- Musixmatch licensed-lyrics deal at scale (lyrics stay derive-don't-display until then).
- iTunes lookup from Workers if Apple unblocks datacenter IPs (currently residential-only; local scripts use it).
