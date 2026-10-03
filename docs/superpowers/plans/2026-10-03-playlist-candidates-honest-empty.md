# Playlist candidates, honest empty mixes, no em dashes in DJ replies

Date: 2026-10-03. Decision: `../../decisions.md` → 2026-10-03.
Scope: `server/` only. No migration, no client change, no deploy.

## Why

A listener who used the Exportify quick import with every file as a playlist
(the default role) had 830 songs and zero pool candidates: `resolvePoolMode`
read the landed import as `personal`, and the personal candidate rule
(`in_library OR seeded OR 3 recent plays`) admitted none of them. Every
`generate_queue` returned "no tracks in the library match those constraints",
the model retried with looser briefs until `MAX_TURNS`, and the listener got
"took too many tries — here's where I landed." over an empty queue. The same
import gave those songs `enrich_priority` 0, so only about 120 were enriched
two weeks later.

## Working-tree warning

Other sessions hold uncommitted changes in `server/src/dj/loop.ts`,
`server/test/dj/loop.test.ts`, `server/src/routes/sessions.ts`,
`server/src/db/schema.ts` and across `web/` and `client/`. Edit in place, keep
their changes, never `git stash`, `git checkout`, `git restore`, or commit.

## Task 1: playlist songs are personal candidates (`src/dj/pool.ts`)

Red first in `test/dj/pool.test.ts`.

- New CTE `playlist_tracks`: distinct `pe.track_id` from `playlist_entries pe`
  joined to `user_playlists up` where `up.user_id` is the listener,
  `up.in_library = true`, `up.kind IN ('user','external','user_shared','unknown')`,
  `playlistOriginSql <> 'mixtape'`, and `pe.track_id IS NOT NULL`.
- Share the kind list with `playlist_signal` through one constant so the two
  cannot drift.
- Personal filter becomes `ut.in_library OR ut.seeded OR recent plays OR
  ut.track_id IN (SELECT track_id FROM playlist_tracks)`.
- Eligibility only. Do not require `user_confirmed` (that still gates the 0.10
  taste term), do not change any weight, do not touch corpus mode or
  `resolvePoolMode`.
- The candidate source stays `user_tracks`, so a playlist entry with no
  `user_tracks` row for the listener stays out (Apple playlist sync writes
  none; the Spotify imports do). Keep that; it is recorded in the decision.
- Update the candidate-rule comments at the top of the file and above the CTE.

Tests: a playlist-only track (user_tracks row, `in_library=false`,
`seeded=false`, no ledger) in an active `user` playlist is a candidate; the
same track is not a candidate when the playlist is `editorial`, is
`in_library=false`, belongs to another listener, or has Mixtape origin
(`is_mixtape_owned` or a `playlist_origins` row with origin `mixtape`); an
unconfirmed playlist admits but earns no playlist taste term.

## Task 2: enrichment priority follows the candidate rule

- `src/listening/import-store.ts` step 6 ("Enrichment order: pool candidates
  first"): a track of this run that sits in one of the listener's active
  candidate-kind playlists gets the same `1 + play_count_recent` priority as
  the other candidate legs. Check that playlist entries for the run are
  already written at that point in `complete()`; if they are published later,
  move the priority statement after them or derive membership from the staged
  rows. Add a test beside the existing enrichment-priority test.
- `scripts/reprioritize-playlist-tracks.ts`: one-off backfill for imports that
  already landed. Dry run by default (prints counts only, never ids), `--apply`
  to write, following `scripts/retitle-sessions.ts` and `scripts/lib/dev-vars.ts`.
  Sets `enrich_priority = greatest(enrich_priority, 1)` for tracks that are
  candidates through the playlist leg for any listener. Add an npm script.
  **Do not run it with `--apply`.** A dry run is fine.

## Task 3: an empty library says so (`src/dj/loop.ts`, `src/dj/pool.ts`)

Red first in `test/dj/loop.test.ts`.

- Export `hasPersonalCandidates(db, userId)` from `pool.ts`: whether the
  personal candidate rule admits anything, with no intent filters (an EXISTS). It must reuse the same SQL fragments
  as `buildPool` (candidate CTEs and the rule), not a copy.
- In `executeGenerateQueue`, when the pool is empty in personal mode and
  `hasPersonalCandidates` is false, return a new exported `EMPTY_LIBRARY_TEXT`
  tool result instead of the constraints text: the listener's music holds
  nothing the DJ can pick from yet, changing the brief will not help, do not
  call `generate_queue` again this turn, tell them plainly and suggest
  importing playlists or liked songs or pasting a few songs they love, the
  queue is unchanged. Tool-result altitude only; the model does the telling.
- Otherwise keep `no tracks in the library match those constraints` exactly
  (an existing test pins it).
- Same check in `executeEditQueue` before `applyOps` when the batch needs a
  pool: zero personal candidates returns `EMPTY_LIBRARY_TEXT`, no partial
  application, no version bump.
- Fallback at `MAX_TURNS`: keep `FALLBACK_TEXT` for a turn whose queue version
  moved; add exported `FALLBACK_UNCHANGED_TEXT` for a turn that changed
  nothing. It must not claim anything landed.

Tests: generate against a listener with a landed source and zero candidates
gets `EMPTY_LIBRARY_TEXT` as the tool result and spends no curation; filters
that empty a non-empty library still get the constraints text; a
`MAX_TURNS` turn with no queue change persists `FALLBACK_UNCHANGED_TEXT`; the
existing `MAX_TURNS` test (queue changed) still gets `FALLBACK_TEXT`.

## Task 4: no em dashes in what the DJ says

The founder does not want em dashes (U+2014) in the agent's replies.

- `src/dj/sanitize.ts`: `stripEmDashes(text)`. An em dash with optional
  surrounding spaces becomes `, `; one at the very start or end is dropped;
  never produce `, ,` or a space before the comma. En dashes and hyphens are
  left alone. Unit tests in `test/dj/`.
- Apply it to every model-authored string a listener reads: the final reply in
  `dj/loop.ts` (before persisting), the final reply in
  `playlist-editing/loop.ts`, and curation `reason` strings in `dj/curate.ts`.
  Not to session titles, track titles, or anything fed back into a prompt.
- Rewrite every canned listener-facing string in `src/dj/loop.ts` and
  `src/playlist-editing/loop.ts` without em dashes (`FALLBACK_TEXT`, the four
  apologies, the playlist-edit `FALLBACK`), keeping the lowercase, brief voice.
  New strings from Task 3 follow the same rule.
- `PERSONA_PROMPT` and the playlist-edit persona: add one line telling the
  model never to use em dashes in replies (commas or full stops instead), and
  rewrite the prompt's own instruction prose without em dashes so it does not
  model the habit. Do the same for the reasons paragraph in `curate.ts`'s
  `SYSTEM_PROMPT`. Leave code comments and the `[i] Title — Artist` listing
  format alone.
- Guard test: every exported canned string and both persona prompts contain no
  U+2014.

## As built (2026-10-03)

- Playlist entries are written by a playlist sync that starts after
  `completeImport`, so the import-side priority only sees playlists from an
  earlier import. `playlists/sync-store.ts` `complete()` applies the same
  raise once the entries exist.
- `runDjTurn`, not `attemptTurn`, picks the `MAX_TURNS` fallback, because only
  it sees the net queue change across a conflict retry. A reply that strips to
  nothing takes the same fallback.
- `CORPUS_NOTICE` was reworded without an em dash so the guard covers every
  exported canned string.
- Accepted from review: the priority raises lock shared `tracks` rows in no
  fixed order (low deadlock risk, raise-only, mostly a no-op after the first
  sync), and the backfill script binds parameters per listener (fine at
  current scale, rework before thousands of listeners).
- Not verified against the live model: that it stops retrying on
  `EMPTY_LIBRARY_TEXT`. Tests use scripted replies.

## Verification

`npm run typecheck` and `npm test` from `server/`. Pre-existing failures that
come from other sessions' uncommitted work are reported, not fixed.

## Out of scope

Client and web copy, Apple playlist-only admission, corpus fallback for a
personal listener with no candidates, production data writes, deploy.
