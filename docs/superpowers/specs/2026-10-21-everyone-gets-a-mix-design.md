# Everyone gets a mix

Status: decisions taken 2026-10-21, all five recommendations (recorded in
`../../decisions.md`). Step 1 implemented and committed 2026-10-21 (Tasks 1
and 2, each reviewed) and deployed; Gate 1 passed the same evening after two
fixes to the DJ model calls (curation token budget, streaming with a
deadline). Step 2 implemented and committed 2026-10-21 (Tasks 3 and 4, each
reviewed) and deployed; Gate 2 passed 2026-10-22. Step 3 implemented and committed
2026-10-22 (Tasks 5 and 6, each reviewed); migration 0043 and the deploy done, sitting 1 seeded 9,022 tracks
(Gate 3 continues in sittings). Steps 3b and 4 committed and deployed 2026-10-22; Gate 4 passed and
`NEVER_REFUSE` is on in production (Worker `e32b557b`). The program is live;
Gate 3 seeding sittings continue at the founder's pace. Plan: `../plans/2026-10-21-everyone-gets-a-mix.md`.
Follows `2026-10-20-first-run-flow-design.md` (decision 4 there deferred
this program) and reopens the 2026-10-03 "honest empty mixes" decision on
the evidence below.

## The problem, with evidence

A listener who has not added a library gets a mix only when their named
artists match the shared catalogue: at least `MIN_SEED_TRACKS` (25) enriched
tracks across `MIN_SEED_ARTISTS` (3) artists (`server/src/dj/pool.ts`,
`resolvePoolMode`). Two things make that floor fail people who should pass
it, and one thing makes it fail people who cannot pass it at all.

1. **Matching is exact.** Seeds and catalogue artists are compared with
   `lower(btrim())` equality. On 2026-10-21 the founder named kanye west,
   jay z and kid cudi; the catalogue held 176 Kanye and 23 Kid Cudi tracks,
   but "jay z" matched none of the rows spelled "jaÿ-z" or credited as
   "jaÿ-z & kanye west". Two matched artists is under three, so the DJ
   refused with 199 usable tracks in reach.
2. **The prompt is not a seed.** "mostly mainstream like kids see ghost's
   reborn" names an artist and a song; neither counts.
3. **The catalogue is one taste.** It is the union of the founder's
   libraries and the Exportify test account: 6,438 tracks, 1,587 artists,
   93 % with audio features, 91 % with meaning embeddings. A listener whose
   artists are outside it has nothing to match, whatever the floor says.

The DJ's refusal text also still asks the listener to "finish the DJ
interview", which the first-run flow no longer offers.

## Direction

The DJ never answers a first prompt with nothing. In order of preference it
builds from the listener's own music, then from the catalogue through the
artists they named, then from the catalogue filled on demand from Apple for
the artists they named, then from the whole catalogue by the prompt's vibe.
Every step says plainly where the picks came from. The catalogue grows from
Apple's charts and editorial playlists so the last step is good rather than
generic.

Four steps, each shippable alone, in this order.

## Step 1: a fair floor (server)

- **Normalised artist matching.** Both sides are folded before comparison:
  lowercase, accents stripped (`unaccent` or a Postgres expression over
  `translate`), punctuation and spaces removed, so "jay z", "Jay-Z" and
  "jaÿ-z" are one key. A seed matches a track when its key equals any
  credited artist's key, where credits are split on `&`, `,`, `feat.`,
  `ft.`, `with` and `x`. Stored as a generated column `tracks.artist_keys
  text[]` with a GIN index, filled by migration; the taste term keeps its
  own v1 matching for now (backlog item, not this program).
- **Prompt seeds.** The DJ loop already extracts intent from the brief;
  it now also returns `named_artists` and `named_songs`. Named artists are
  saved as `user_artist_seeds` with `source = 'prompt'`; named songs are
  resolved later by step 2. Saved before `resolvePoolMode` runs, so the
  first turn sees them.
- **Floor.** `corpus` when matched tracks are at least 25 across at least 2
  artists, or at least 40 from one artist. Below that, step 2 runs before
  any refusal.
- **Copy.** `INSUFFICIENT_SEEDS_TEXT` drops the interview and says: name a
  few more artists or add your music. Kept as the model's own voice.

Expected effect on 2026-10-21's case: Jay-Z matches 30 credited rows, the
mode is `corpus`, the mix is built.

## Step 2: fill from Apple at prompt time (server)

When step 1's floor fails (mode `insufficient_seeds`; the fill never runs
for a listener whose seeds already pass it, nor in personal mode), for each
named artist (from the artists page or the prompt) with fewer than
`FILL_FLOOR` (12) enriched tracks in the catalogue:

1. Resolve the artist through the Apple catalogue client
   (`server/src/musickit/catalog.ts`): `searchSongs` with the artist name
   already exists; add `searchArtists` and `artistTopSongs` (Apple's
   `/v1/catalog/{storefront}/artists/{id}/view/top-songs`). Named songs use
   `searchSongs(term)` and take the first exact title match.
2. Insert the top `FILL_PER_ARTIST` (10) songs as `tracks` rows with
   `apple_id`, `isrc`, title, credited artist, duration and genre, source
   `catalogue_fill`, and mark them for enrichment at the front of the
   queue. ISRC twins (`twin-copy.ts`) fill features and meaning for free
   when a recording already exists under another id.
3. Enrich inside the request what the budget allows: the free plan gives
   50 subrequests and 10 ms CPU per invocation, and a mix turn already
   spends about 30 on the model, the database and the title. Per filled
   artist the fill costs 2 Apple calls; per track it costs up to 2
   ReccoBeats calls (search, then features), up to 2 LRCLIB calls (exact,
   then search) and 1 Workers AI call for the embedding, charged at what
   was actually fetched. Budget: `FILL_BUDGET` = 20 subrequests and
   `FILL_DEADLINE_MS` = 12 s per mix turn, at most 3 artists and 3 named
   songs, which comes to 3 or 4 tracks fully enriched in-request; the rest
   are queued with a priority boost for the hourly cron (`ENRICH_BATCH_CAP`
   8) and the next prompt. (Corrected 2026-10-21 from "about 6": the
   original arithmetic counted one call per provider.)
4. Then `resolvePoolMode` runs again. For an artist the catalogue already
   half knows, the fresh rows plus the existing ones usually meet the
   25-track floor on this turn. For an artist the catalogue does not hold
   at all, one turn yields 3 or 4 enriched rows, so the floor is met on a
   later prompt once the cron has worked through the queued rows, or not
   at all until step 4; the DJ's refusal says to name a few more artists,
   which also widens the fill. This is the honest shape of step 2 on the
   free plan; step 4 is what closes it.

The "Making your mix" page already covers the time. The DJ's first reply
says the picks come from the shared catalogue, as today. Fill never runs
for a listener in `personal` mode. A filled track is an ordinary catalogue
row afterwards: the next listener who names that artist finds it.

Funnel: `catalogue_filled` for the listener (user and surface; the counts
go to the `dj turn` log line, since `funnel_events` has no session or
count columns).

## Step 3: a broad catalogue (founder-run script, server admin route)

Seed the catalogue ahead of demand so step 4 has something to draw from.

- **Sources.** Apple's catalogue charts per genre
  (`/v1/catalog/{storefront}/charts?types=songs&genre=…`, top 200 per
  genre) and Apple's editorial playlists per genre (the "Essentials",
  "Today's Hits" and "A-List" families, resolved by search). Storefronts:
  `ng`, `us`, `gb` to start. Roughly 25 genres times 200 times 3
  storefronts is about 15,000 songs before dedupe; editorial playlists add
  about the same. Target: 20,000 to 30,000 catalogue tracks in the first
  pass.
- **How it runs.** A new founder-run script `scripts/seed-catalogue.ts`
  (same shape as `drain-enrichment.ts`): it pulls the lists through a new
  admin route `POST /enrich/seed` that inserts `tracks` rows with ISRCs and
  queues them, then drives `POST /enrich/run` in a loop so each batch has
  its own free-plan budget. ReccoBeats has returned 429 and 503 under the
  2026-10-03 drain; the script keeps the existing cool-down and `--delay-ms`
  and stops on sustained provider errors. Expect days, not hours: at the
  drain's observed pace (about 720 tracks a sitting) a 25,000-track pass is
  roughly 35 sittings, so the script is resumable and reports coverage.
- **Storage.** `track_meanings` is 76 MB for 6,000 rows, about 12.7 KB a
  row, almost all the 1024-dimension `bge-m3` embedding and its HNSW index.
  At that rate 25,000 tracks is about 320 MB in that table alone against
  the Neon free plan's 0.5 GB. Two ways through, decision 3 below: store
  embeddings as `halfvec` (2 KB a row, same model, negligible recall loss
  for nearest-neighbour at this size) which keeps the first pass inside
  the free plan, or move to Neon's paid plan. Compute: the 100 CU-hour
  monthly allowance already carries the hourly cron; the seeding sittings
  add their own hours while they run.
- **Quality.** Chart songs come with Apple genre and release year; the
  pool's familiarity and taste terms treat them as 0, as corpus rows are
  today. Explicit and clean twins are kept as one recording by ISRC.
- **Provenance (built 2026-10-22).** Seeded rows and prompt-time fill rows
  are written as `artist_source = 'apple_catalog'`, the same as
  playlist-editing rows; `tracks` has no separate source column and
  adding one was not worth a migration. Seeded rows therefore cannot be
  counted or rolled back on their own; the script's own log and state
  file are the record of what was seeded.
- **Lists as built.** 27 Apple genre charts plus the overall chart (ids
  from Apple's genre tree, checked live: Afrobeats 100051 under African
  1203, Amapiano 42, K-Pop 51, Gospel 1101, Metal 1153) and 16 editorial
  playlist search terms, one Apple Music playlist per term; 100 songs a
  page; about 21,000 songs before dedupe, an expected 10,000 to 13,000 new
  rows, so 15,000 enriched is reachable with the 6,000 already held.
  Seeding is about 264 calls, roughly 20 minutes once; the drain is about
  13 sittings at the observed 720 rows a sitting.

## Step 3b: enrichment throughput (server, founder-run)

Added 2026-10-22 after sitting 1 of Gate 3. Songs are now cheap to get and
slow to score: the drain stopped at 85 tracks because LRCLIB answered 429
at a 4 s pace and ReccoBeats found no match for about 30 % of chart songs,
and the hourly cron does 8 an hour. Three changes, no new infrastructure:

- **Two more cron triggers.** The Worker's free plan allows 5 triggers and
  uses 2 (`0 * * * *` maintenance, `2 * * * *` enrichment). Add `22 * * *
  *` and `42 * * * *` as enrichment-only runs: three times the pace, about
  570 tracks a day, each run inside its own subrequest budget, 20 minutes
  apart so LRCLIB sees a gentle rate.
- **A kinder drain.** The founder's drain and the seed script's drain back
  off on a call whose failures are all transient (429, 503): wait 60 s,
  then continue; they stop only when nothing is due, when `--max` is
  reached, or after three consecutive backed-off calls. Default
  `--delay-ms` becomes 10,000. A provider's own cool-down is already
  recorded per track by the runner.
- **Sittings from the founder's machine stay the burst tool.** A sitting
  at the new pace is about 300 tracks an hour. GitHub Actions is not used:
  the repository is private and a scheduled drain would exceed the free
  minutes.

Expected: the 9,000-row backlog from sitting 1 clears in about two to
three weeks of cron alone, or a few days with sittings. Step 4 no longer
waits for it.

## Step 4: never refuse (server), reshaped 2026-10-22

The original Step 4 ranked the whole seeded catalogue by the prompt's vibe.
Sitting 1 showed that is the wrong lever: scoring is the bottleneck, not
songs, and a vibe-only pool over half-enriched rows would be thin. The
reshaped Step 4 lets the DJ draw on what the model already knows about
music, and makes Apple the hallucination guard, the way the album program
does (`server/src/albums/verify.ts`: a candidate Apple cannot confirm in
the listener's market is dropped, never shown).

When step 1's floor fails for a listener with no personal data, and
`NEVER_REFUSE` is on:

1. **Propose.** One model call (Sonnet 5, the DJ's own voice) given the
   brief, the named artists and seeds, the shape, and the listener's
   storefront: return `targetCount + 8` songs as `{ title, artist, reason }`
   in the order they should play, mainstream-leaning unless the brief says
   otherwise, no two by the same artist in a row, at most three per artist,
   and a one-line reason each in the existing reason style. This replaces
   the curation call for this turn; there is no pool to score.
2. **Verify.** For each proposal, one Apple `searchSongs(storefront,
   "<title> <artist>", 5)`; keep the first hit whose credited artist key
   matches the proposed artist (`artistMatches` from the album program,
   adapted to credits) and whose title key matches. Cap `VERIFY_MAX` = 25
   searches per turn and `VERIFY_DEADLINE_MS` = 10 s. Insert the hits as
   catalogue rows through `addCatalogueSongs` (ISRC then Apple id dedupe,
   the 1,000 priority boost, never enriched in-request), so the catalogue
   learns every verified song for everyone.
3. **Assemble.** The verified songs, in the model's order, cut to
   `targetCount`, become the queue with the model's reasons. If fewer than
   `MIN_VERIFIED` (8) verify, one more proposal call asks for replacements
   naming the ones that failed; if still short, the DJ says what it could
   confirm and offers to loosen (the album program's "nothing verified"
   shape), never an empty answer.
4. **Say so.** The DJ's reply carries a notice like `CORPUS_NOTICE`: these
   picks are from the DJ's own knowledge, checked against Apple Music, not
   from the listener's listening, and naming more artists or adding their
   music sharpens them.

Budget per turn: the proposal call (1 to 2 fetches), up to 25 Apple
searches, the final reply round, the title, and the database over one
socket: about 35 subrequests, with the prompt-time fill's in-request
enrichment turned off on this path (its top-songs insertion stays, 6
calls, because it compounds). Wall time: about 15 s proposal, 5 to 10 s
verification, 15 s reply: under a minute.

The corpus path (step 1's `corpus` mode over the enriched catalogue) is
unchanged and still preferred when the floor passes, because scored rows
carry features the model's memory does not. Personal mode is untouched.
The first-run artists page stays; "Skip for now" goes to the prompt page
when the flag is on. Outside picks for personal listeners are a separate
program and unchanged.

Gating: `NEVER_REFUSE` in `wrangler.jsonc`, on since 2026-10-22 after the
founder listened to three proposed mixes (comfort, default, adventurous)
and called them acceptable. No catalogue size gate.

Known limits, accepted: the model's knowledge thins outside mainstream
and recent releases (a 2026 release it has not seen cannot be proposed);
Apple search by title can pick a cover or a live version when the credit
matches (title key plus artist key is the guard, with an exact-title pass
before the stripped one and a rejected-versions list); verified rows
arrive unenriched and are scored only once the cron reaches them.

As built (2026-10-22): a proposal asks for `targetCount + 8` songs capped at
`VERIFY_MAX` (22) searches, so a proposed queue holds at most 22 and a
60-track brief on this path gets 22, with the DJ saying how many it could
confirm; verification stops once the mix is full, so spare proposals do
not enter the catalogue; the replacement round is skipped after a 429 or
once the turn has run 50 s; a listener with explicit off has explicit
hits rejected; the three-per-artist rule is the model's, not code's; edits
(swap, extend) on a proposed mix go through the same propose and verify
with the current queue excluded. Clients learn the flag from `GET /health`
(public: `{ ok, service, neverRefuse }`, no session, no database), because
"Skip for now" can be pressed before any session exists; `GET /me` reports
it too. The flag reads on only when the Apple fill is wired, so a server
without Apple keys never routes a listener to a mix it cannot propose.
With the flag on, Step 1's "Skip for now" goes to the prompt page; the
export pages' "I've requested it" and a sync that brings nothing in still
go to the artists page.

## What this does not do

Spotify or Apple library reads without the listener's own sync; lyric
storage (embeddings only, as always); learning from chart data as if it
were the listener's taste; changing the mix size or the outside-picks
share. Apple Music API terms permit catalogue metadata use inside an Apple
Music client; the program stores metadata, ISRCs and derived embeddings,
not audio.

## Tests

Step 1: matching table-driven (accents, punctuation, credits, "x" and
"with"); floor thresholds; prompt seeds saved with source `prompt`; the
2026-10-21 case as a golden structural test (three seeds, one spelled
differently, mode `corpus`). Step 2: fill inserts and marks rows, respects
`FILL_BUDGET`, never runs in personal mode, twins short-circuit
enrichment, the second `resolvePoolMode` sees the rows, the funnel row is
written; a fake Apple client. Step 3: the seed route dedupes by ISRC and
Apple id, queues at front, reports counts; the script is tested against a
fake Worker for resume and stop rules. Step 4: corpus with no seeds builds
a pool from the vibe terms only, flag off keeps today's behaviour, the
golden set gains a vibe-only prompt per familiarity preset.

## Decisions requested

1. Step 1 floor: 25 tracks across 2 artists, or 40 from one (recommended).
2. Step 2 budget: `FILL_BUDGET` 24 subrequests, `FILL_PER_ARTIST` 10,
   `FILL_FLOOR` 12 (recommended), or smaller to keep the turn under a
   minute. (Taken; then lowered in review to 20 with a 12 s deadline once
   the whole turn's subrequests were traced: a turn with two curation
   calls was reaching 50.)
3. Storage for step 3: `halfvec` embeddings on the free plan (recommended,
   one migration and a re-index) or Neon's paid plan at 1024-float.
4. Step 3 scope: storefronts `ng`, `us`, `gb` and a 25,000-track first pass
   (recommended), or `ng` only to start.
5. Step 4 gate: ship behind `NEVER_REFUSE` and turn on after the three
   listening checks (recommended).

Taken 2026-10-22, after Gate 3 sitting 1 (recorded in `../../decisions.md`):

6. Step 4 is reshaped to model-proposed songs verified on Apple, as above;
   the vibe-only ranking of the seeded catalogue is dropped.
7. Enrichment throughput: two more Worker cron triggers and a kinder drain
   (Step 3b); no GitHub Actions, no new infrastructure.
