# Plan: outside-library picks, free-plan enrichment, ISRC twins

Date: 2026-10-03. Spec: `../specs/2026-10-03-outside-library-picks-design.md`.
Decision: `../../decisions.md` → 2026-10-03 (mixes may include songs the
listener does not own).

House cadence: one fresh implementer per task, red tests first, then a
reviewer pass and one fix round. Implementers and reviewers run on Opus. At
most two agents in flight.

## Standing rules for every task

- **Free plan.** 50 subrequests and 10 ms CPU per invocation, 5 cron
  triggers, 10,000 Workers AI neurons per day. No task may assume a paid
  limit, add an invocation at a new time of day, or raise a batch constant
  without the measuring test from Task 2.
- **Shared working tree.** Other sessions hold uncommitted work, including
  `server/drizzle/0033_tape_case_color.sql` and its journal entry. Edit in
  place. No `git stash`, `checkout`, `restore`, `reset` or commit. Never
  regenerate or edit migration 0033.
- **No production writes, no deploy, no `--apply`** unless a step says the
  founder runs it.
- New listener-facing strings and prompt prose contain no em dashes; the
  guard in `server/test/dj/no-em-dash.test.ts` covers new exported strings.
- Never store or display lyric text. Curation tests are golden-set
  structural assertions, not exact-track assertions.
- Docs ride with the change: update the spec's status line when a phase
  lands, and `docs/backlog.md`.

## Gate 0: Neon allowance (settled 2026-10-03)

Free plan: 100 CU-hours per project per month, scale to zero after 5 idle
minutes. The existing hourly cron costs roughly 18 CU-hours a month at
0.25 CU; a second trigger two minutes later adds roughly 6. Task 3 stays.
The estimates assume the compute idles at 0.25 CU; the founder can confirm
the real figure on the Neon dashboard's usage page.

## Phase A: enrichment inside the free plan (server only)

### Task 1: twin copy

Files: new `server/src/enrich/twin-copy.ts`, `server/src/enrich/scheduled.ts`,
`server/test/enrich/twin-copy.test.ts`.

- `runTwinCopy(db, limit = 500)`: one statement per table. For a track with
  an ISRC and no `track_features` row, insert a copy of the row belonging to
  another track with the same uppercase ISRC, `source = 'twin'`, keeping the
  donor's timestamps. Same for
  `track_meanings` with `lyrics_source = 'twin'`, copying the embedding and
  `instrumental`. `ON CONFLICT DO NOTHING`. Deterministic donor choice
  (oldest row). Returns counts only.
- Clear the matching `enrichment_failures` rows for tracks it filled.
- Call it in `handleScheduled` immediately before the enrichment batch, in
  its own try/catch like the other jobs. Log counts only.
- Tests: fills only what is missing, never overwrites, respects the limit,
  ignores malformed or null ISRCs, a filled track leaves the enrichment
  candidate set.

### Task 2: measure, then size the batch

Files: `server/src/enrich/scheduled.ts`, `server/src/routes/enrich.ts`,
`server/test/enrich/subrequest-budget.test.ts`.

- The Worker uses the WebSocket pool (`drizzle-orm/neon-serverless`), so
  database statements are not subrequests. Correct the stale comment above
  `MAX_BATCH`.
- Test: run `runEnrichmentBatch` with counting fakes for every external
  source (Spotify tracks and features lookups, feature search, lyrics,
  embedder). Assert the worst case, where every per-track call happens, as
  `fixed + perTrack * n`. Export those two numbers as constants and derive
  `CRON_BATCH` and `MAX_BATCH` as the largest `n` with
  `fixed + perTrack * n <= 40` (10 held back for the pool's connections and
  retries), capped at 8.
- Step-up rule, written in a comment beside the constant: ship at 5 first;
  the founder checks one day of `maintenance cron` logs for CPU-limit kills
  or `failed` markers before the cap is raised to 8.
- Report the measured numbers.

### Task 3: enrichment in its own invocation

Files: `server/wrangler.jsonc`, `server/src/index.ts`,
`server/src/enrich/scheduled.ts`, `server/test/enrich/scheduled.test.ts`.

- Crons become `["0 * * * *", "2 * * * *"]`. `scheduled` dispatches on
  `event.cron`. The first runs the cleanups, playlist catalogue resolution
  and Apple artwork. The second runs twin copy, enrichment, Apple ISRC
  linking, then the Spotify thumbnail fallback: linking follows enrichment
  because enrichment produces ISRCs, and the fallback follows linking so
  Apple artwork gets its chance first (amended after review, 2026-10-03).
  An unknown cron string runs nothing and logs a fixed marker.
- Tests: each expression runs only its own jobs; failure isolation between
  jobs is unchanged.

### Task 4: founder-run drain

Files: new `server/scripts/drain-enrichment.ts`, `server/package.json`.

- Calls `POST /enrich/run` on the deployed Worker in a loop. Reads the admin
  token and base URL the way `scripts/dj-chat.ts` and `scripts/lib/dev-vars.ts`
  do; never prints either.
- Required `--max <tracks>`; default delay 4 seconds between calls,
  `--delay-ms` to change it (minimum 1000); stops early when a call reports
  zero processed, any error, or two calls in a row where nothing succeeded
  (a provider outage would otherwise burn every track's three attempts). Prints running counts only.
- Not run by any agent.

**Phase A exit:** `npm run typecheck`, `npm test`. Founder commits, deploys
from a clean worktree, watches one day of cron logs.

## Phase B: one recording, however it arrived

### Task 5: ISRC through the import (server)

Files: `server/src/listening/contracts.ts`, `server/src/db/schema.ts`, a new
migration generated with `npm run db:generate` on top of 0033,
`server/src/listening/import-store.ts`, staging write path,
`server/test/listening/*`, `server/test/migrations/pending-upgrade.test.ts`.

- `listeningTrackSnapshotSchema` gains optional `isrc`, accepted only when it
  matches `^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$` after uppercasing; anything else is
  dropped to absent, not rejected, so a bad cell never fails an import.
- `listening_import_tracks.isrc` nullable column with the same check.
- Publish step 1 writes `isrc = coalesce(tracks.isrc, excluded.isrc)` on both
  insert and conflict for the Spotify source. Apple export path unchanged.
- Old clients that send no `isrc` keep working.
- Tests: carried, absent, malformed, and never overwriting an existing ISRC.

### Task 6: store the ISRC the artwork job already fetches

Files: `server/src/artwork/runner.ts`, `server/test/artwork/*`.

- Where the job updates a track from a catalogue song, also set
  `isrc = coalesce(tracks.isrc, <song isrc>)` when the value is well formed.
- Add a bounded pass (at most 300 rows, one catalogue call per run) over
  Apple rows that already have artwork and no ISRC, ordered by id, with a
  per-track "checked" marker so a song Apple returns no ISRC for is not
  refetched every hour. Reuse an existing status table if one fits; if a new
  column is needed it goes in Task 5's migration, so do Task 5 first.
- Tests: fills, never overwrites, bounded, no refetch loop.

### Task 7: twins are not conflicts

Files: `server/src/enrich/apple-isrc.ts`, `server/src/db/schema.ts` (category
enum and check), Task 5's migration, `server/test/enrich/apple-isrc.test.ts`.

- When the matched Apple ID is already held by another row whose ISRC equals
  the candidate's, record category `twin` with no further retry. A holder
  with a different or missing ISRC stays `conflict`.
- Result counts gain `twins`.

### Task 8: parsers read the ISRC (web, then iOS)

Files: `web/src/import/*` and tests; `client/lib/import/*` and tests.

- Read Exportify's ISRC column through the same header mapping used for the
  other columns (headers are translated). Normalise and validate as in
  Task 5; send it on the track snapshot.
- These directories carry other sessions' uncommitted work. Touch only the
  parser and its tests. New iOS Swift files, if any, need target membership.

**Phase B as built (2026-10-03):** migration `0034_isrc_twins` adds
`listening_import_tracks.isrc`, `tracks.isrc_checked_at` and the `twin`
lookup category. The Apple ISRC backfill covers 300 rows an hour with one
catalogue call, is skipped in a run where the artwork job did a full batch
(the 10 ms CPU limit), and defers rows on a lasting catalogue error. Only
the literal `ISRC` header is mapped; no translated label is known.

**Rollout order is mandatory.** 0033 and `src/dj/tape-colors.ts` (another
session's work) must be committed before or with Phase B: the schema imports
that file and 0034's snapshot builds on 0033. Then: apply 0034, deploy the
Worker, ship web, ship iOS. The old Worker rejects a track carrying `isrc`
(strict schema), so a client shipped first fails every Exportify upload, and
so does a Worker rollback after the clients ship. A new Worker without 0034
fails every import upload, the artwork job and playlist editing.

**Phase B exit:** typecheck and tests in `server/`, `web/` and `client/`.
Founder applies the migration, deploys, runs `drain-enrichment --max 700`,
then re-imports the Exportify files so existing rows get their ISRCs.

## Phase C: outside picks (server, behind a flag)

Flag: `OUTSIDE_PICKS` var in `wrangler.jsonc`, `"off"` by default, read once
in `index.ts` and passed through `DjDeps`. Off means today's behaviour
exactly, and the tests prove that.

### Task 9: outside candidates in the pool

Files: `server/src/dj/pool.ts`, `server/src/dj/contracts.ts`,
`server/test/dj/pool.test.ts`.

- `intentSchema` and the tool JSON schema gain optional `allowOutside`
  (default true), documented as "false when the listener wants only their
  own music".
- `outsideCap(intent)`: 0 when `allowOutside` is false or familiarity is
  comfort; `floor(0.2 * targetCount)` for mix; `floor(0.4 * targetCount)` for
  adventurous. Exported with its constants.
- `buildOutsidePool(db, embedding, userId, intent, cap, opts)`: inner CTE
  takes the 200 nearest `track_meanings` rows by raw embedding distance (so
  the HNSW index is used), then: drop any recording key the listener holds
  in `user_tracks`, apply the brief's hard filters and the queue exclusion,
  require a playable id using the same platform rule as the existing `pref`
  expression, collapse ISRC twins to the playable row, score with the corpus
  formula where artist familiarity is 0.7 when the listener has another row
  by that artist, plus learned artist taste and the playlist profile when
  selected. Return at most `min(60, 4 * cap)` rows. Skip the query entirely
  when cap is 0.
- `PoolTrack` gains `outside: boolean`. `buildPool` reuses its embedding for
  the outside query (one embed call per build, as today) and appends the
  outside rows after the personal ones. Personal mode only; corpus mode is
  untouched.
- Tests: own recording never offered, including through a twin; platform
  rule per listener kind; hard filters; cap arithmetic; cap 0 issues no
  query; flag off returns no outside rows.

### Task 10: cap enforcement and the DJ's words

Files: `server/src/dj/curate.ts`, `server/src/dj/loop.ts`,
`server/src/dj/queue-store.ts`, tests beside each.

- Pool listing marks outside rows with a `new` field and the legend explains
  it. The intent block states "at most N songs marked new". The system
  prompt's "assume they know these songs" is scoped to unmarked rows.
- After `normalizePicks`: keep outside picks in order up to the cap, drop
  the rest, backfill from personal rows only.
- Edits: the cap for a swap or extend is
  `cap(queue length after the edit) - outside picks already in the queue`,
  floored at 0.
- Tool results for generate and edit add one line when any pick is outside:
  how many, their positions, and an instruction to say so plainly. New
  exported constant, no em dashes.
- `QueueTrackView` gains `newToYou`, computed at read time as "no
  `user_tracks` row of this listener shares the track's recording key". No
  migration. Present on every queue response; false when the flag is off is
  not special-cased, since no outside pick can exist then.
- Persona: one line. Outside picks are allowed up to the cap; pass
  `allowOutside: false` when the listener or a saved preference asks for
  their own music only; use adventurous when they ask for new things.
- Tests: caps hold for each familiarity and after backfill; `allowOutside:
  false` yields none; `newToYou` only on outside picks; the tool-result line
  appears only when needed; flag off is byte-for-byte today's tool results.

**Phase C server exit:** typecheck, tests, founder deploys with the flag off.

### Gate 1: state board (approved 2026-10-03)

Variant A approved, wording approved, and not-personal mixes show no mark
(the server sends `newToYou` false for them). Record:
`../../mockups/approved/2026-10-03-new-to-you-mark.md`.

The "new to you" mark on queue rows (web and iOS, light and dark, with and
without a reason line) and the wording on "Create as playlist" when a mix
contains outside picks. Use the `ui-state-board` flow and the founder's
recorded mobile and web design preferences. No client work before approval.

### Task 11: web mark, then Task 12: iOS mark

Map `newToYou` through the API layer and render the approved mark. Add the
approved line to the create-playlist confirmation. Tests per house style.

### Gate 2: flag on

Founder sets `OUTSIDE_PICKS` to `"on"`, deploys, and makes three mixes
(comfort, default, adventurous) on their own account to confirm 0, at most
3, and at most 6 new songs in a 15-track mix.

## Optional, not approved: Spotify IDs for Apple rows

Why Spotify-only listeners get no picks: a pick must open in their player,
their rows need a Spotify ID, and every other song we hold has only an Apple
ID. The features provider's by-id responses carry an
`open.spotify.com/track/<id>` link (`server/src/enrich/reccobeats-by-id.ts`).
If its search response carries the same link, the exact title, artist and
duration match that enrichment already makes for an Apple row could also
stamp `spotify_id` on that row at no extra call, unless another row already
holds that id (then they are twins). Unknown until one real search response
is inspected. A spike is one request. Already-enriched rows would need a
slow re-query through the drain script. Ask the founder before doing either.

## What the founder does, in order

1. After Phase A: commit, deploy, check a day of cron logs, allow the batch
   to go from 5 to 8.
2. After Phase B: migrate, deploy, drain, re-import the Exportify files.
3. After Phase C server: deploy with the flag off.
4. Approve the state board.
5. Turn the flag on and run the three-mix check.
