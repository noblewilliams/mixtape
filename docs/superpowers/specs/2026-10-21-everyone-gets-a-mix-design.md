# Everyone gets a mix

Status: decisions taken 2026-10-21, all five recommendations (recorded in
`../../decisions.md`). Step 1 implemented and committed 2026-10-21 (Tasks 1
and 2, each reviewed); Gate 1 owed. Steps 2 to 4 not started. Plan: `../plans/2026-10-21-everyone-gets-a-mix.md`.
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

When, after step 1, a named artist (from the artists page or the prompt)
has fewer than `FILL_FLOOR` (12) enriched tracks in the catalogue:

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
   spends on the model and the database. Per filled artist the fill costs
   2 Apple calls, 1 ReccoBeats search call per track for features
   (`resolveAndFetchFeatures`, no Spotify ids here), 1 LRCLIB call per
   track for lyrics, and 1 Workers AI call per track for the embedding.
   Budget: `FILL_BUDGET` = 24 subrequests per mix turn, so about 6 tracks
   fully enriched in-request per turn; the rest wait for the hourly cron
   (`ENRICH_BATCH_CAP` 8) and the next prompt.
4. Then `resolvePoolMode` runs again. With 6 fresh tracks per artist across
   two or three artists the 25-track floor is usually met together with
   the catalogue's existing rows; when it is not, step 4 applies.

The "Making your mix" page already covers the time. The DJ's first reply
says the picks come from the shared catalogue, as today. Fill never runs
for a listener in `personal` mode. A filled track is an ordinary catalogue
row afterwards: the next listener who names that artist finds it.

Funnel: `catalogue_filled` with the count, on the session.

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

## Step 4: never refuse (server)

Once step 3 has landed and the catalogue passes 15,000 enriched tracks:

- `resolvePoolMode` returns `corpus` for any listener with no personal
  data, whatever the seeds, with `seedTracks` and `seedArtists` reported as
  today. `insufficient_seeds` is no longer produced.
- `buildPool` in corpus mode with no matched seeds ranks the whole
  catalogue by the prompt's vibe (the existing meaning and feature terms,
  familiarity 0 everywhere) and by genre when the brief names one. The DJ
  is told, through the existing `CORPUS_NOTICE`, that these picks are from
  the shared catalogue and that naming artists would sharpen them.
- The first-run artists page stays (it makes the first mix better), but
  "Skip for now" from Step 1 of 3 now goes straight to the prompt page.

Gating: step 4 ships behind `NEVER_REFUSE` = off in `wrangler.jsonc` and is
turned on only after a founder listens to three vibe-only mixes (comfort,
default, adventurous) from the seeded catalogue and calls them acceptable.
Before step 3, a vibe-only mix for a rap prompt over the current catalogue
would be an off-genre mix, which is worse than the refusal.

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
   minute.
3. Storage for step 3: `halfvec` embeddings on the free plan (recommended,
   one migration and a re-index) or Neon's paid plan at 1024-float.
4. Step 3 scope: storefronts `ng`, `us`, `gb` and a 25,000-track first pass
   (recommended), or `ng` only to start.
5. Step 4 gate: ship behind `NEVER_REFUSE` and turn on after the three
   listening checks (recommended).
