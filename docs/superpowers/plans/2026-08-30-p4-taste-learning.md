# P4 — Taste learning + per-user DJ memory

**Founder decisions (2026-08-30):** memory notes are created live by the DJ via a `remember_preference` tool (behavioral distillation deferred); a "What the DJ knows" screen in the app lists notes with swipe-to-forget; learned taste applies as a **subtle rerank** (fourth scoring term — the prompt still dominates), with explicitly-stated hard rules enforced through the DJ's context, not pool gating.

**Raw signals** (collected since P3a): `queue_tracks` rows carry `addedBy`/`removedBy` (`'dj' | 'user'`) and removed rows are preserved — user swipe-aways are already cleanly separated from DJ swaps. Play counts/lastPlayedAt arrive via library re-syncs. **Gap:** Play-in-Apple-Music and Save-as-playlist happen purely on-device today — the server never learns them (Task 1 closes this).

## Binding design facts

- Curation stays Sonnet-only; the memory tool is part of the same DJ turn (no extra LLM calls). Memory notes and taste data are USER-derived → injected at user altitude only, through `sanitizeForPrompt`, never into the system prompt verbatim (P3a injection posture).
- `DJ_TOOLS` lives in `src/dj/contracts.ts` WITH schema-drift tests — extending it means updating those tests deliberately, and `MAX_CURATIONS_PER_TURN` budgeting must not count `remember_preference` as a curation.
- Scoring weights (`src/dj/pool.ts` `FAMILIARITY_WEIGHTS`) are a true convex combination per familiarity preset — adding a `taste` term means rebalancing all presets so they still sum to 1; taste score is [0,1] with 0.5 = neutral (no signal), so an unknown track is neither boosted nor punished.
- Don't double-count: library play counts already power the `fam` term. The taste term uses only DJ-session-derived signals: user removals (penalty), tracks kept in played/saved sessions (boost), with recency decay (half-life ~90 days) so old signals fade.
- Artist-level aggregation for v1 (track-level signals are too sparse at one user); computed in SQL inside `buildPool` (~4.7k tracks, cheap) — no materialized profile table until scale demands it.
- Memory notes: hard cap 50 active per user (tool returns a content-free refusal beyond it), exact-duplicate insert is a no-op, DELETE is hard (a forgotten note is gone). Notes render in the DJ context as a compact numbered list; the tool takes `{note: string}` (≤200 chars, trimmed/sanitized).
- New endpoints under the existing session-auth middleware: `POST /sessions/:id/events` (`{type: 'played' | 'saved_playlist'}`), `GET /me/memories`, `DELETE /me/memories/:id` (owner-scoped). Client event posts are fire-and-forget (silent failure — never degrade Play/Save UX).
- Migrations follow the repo's Drizzle flow; apply to prod at the end of the phase alongside deploy (this project deploys continuously — no held migrations).

## Tasks

### Task 1: session events (server)
- `session_events` table (id, sessionId FK cascade, type enum played|saved_playlist, createdAt) + migration; `POST /sessions/:id/events` (zod-validated, session ownership enforced, 404 unknown session); route tests incl. cross-tenant denial.
- Commit `feat(server): session events`.

### Task 2: memory module (server)
- `dj_memories` table (id, userId FK, note text, createdAt) + migration.
- `remember_preference` tool in `DJ_TOOLS` (+drift tests): loop executes it inline (insert with cap/dupe rules), tool result `{ok: true}` or content-free refusal; NOT counted against the curation budget; works in both generate and edit turns.
- Notes injected each turn at user altitude (sanitized, numbered, capped); system prompt gains a short instruction: save a note when the user STATES a durable preference (not one-off moment requests), and respect existing notes — treat "never/always" notes as hard rules.
- `GET /me/memories` + `DELETE /me/memories/:id` (owner-scoped, 404 others').
- Tests: tool round-trip persists; cap + dupe; injection posture (a note containing tool-call-looking text renders inert); delete scoping; golden-set: a "never play X" note structurally excludes X from the produced queue.
- Commit `feat(server): dj memory module`.

### Task 3: taste term in scoring (server)
- `buildPool` gains per-artist taste aggregation (user removals vs kept-in-played/saved-session tracks, recency-decayed, squashed to [0,1] around 0.5 neutral) joined into candidate scoring.
- Rebalanced convex weights per preset (taste ≈ 0.10–0.15, shaved proportionally from the others); intent schema untouched.
- Tests: neutral-when-no-signal (existing golden results unchanged within tolerance); winner-flip — a heavily-swiped artist's track loses to a near-tied kept-artist track; decay (old removals matter less); no double-counting regression on the fam term.
- Commit `feat(server): taste-aware scoring`.

### Task 4: client — events + memory screen
- Fire-and-forget event posts on successful playQueue (`played`) and createPlaylist (`saved_playlist`) — silent catch, no UX change; widget tests assert the calls + that failures are invisible.
- "What the DJ knows" screen: entry from Home AppBar (psychology/memory icon), lists notes newest-first, swipe-to-forget with undo-window snackbar (optimistic remove, DELETE on commit), empty state ("the DJ hasn't learned anything yet — tell it what you like"), loading/error per the established `hasError && !hasValue` pattern.
- Commit `feat(client): dj memory screen + listen signals`.

### Task 5: migrations + deploy + founder smoke
- Apply both migrations to prod, `wrangler deploy`, rebuild the app.
- Smoke script: state a durable preference in chat ("I always want at least one Wizkid track on party tapes") → note appears in the memory screen → new session honors it; swipe the same artist away in two sessions → their tracks visibly rarer in the next queue (subtle, not absent); forget a note → behavior reverts.
- decisions.md entry + README status; record follow-ups (behavioral distillation, context-scoped taste) as deferred.

## Out of scope (resist)
Nightly LLM distillation of behavior · context-aware taste (per-mood affinities) · pool gating/hard exclusions from implicit signals · cross-user taste priors · memory editing UI (delete-only in v1) · Opus anywhere.
