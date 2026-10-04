# Outside-library picks, with free-plan enrichment and ISRC twins

Status: approved by the founder 2026-10-03 (all four decisions as recommended;
Neon allowance confirmed). Phase A is deployed. Phases B and C are built and
reviewed and, as of 2026-10-04, committed except for the web "New to you"
mark, which waits on the uncommitted UI-polish work it sits on. Nothing from B
or C is deployed, and `OUTSIDE_PICKS` is off. Current state and remaining
steps: `../../backlog.md`. Plan:
`../plans/2026-10-03-outside-library-picks.md`. Decision: `../../decisions.md`.
Pulls forward `product/vision.md` → "Catalog discovery". Builds on the
2026-10-03 decision (playlist songs are pool candidates).

## User outcome

"Make me something for the drive" returns a mix that is mostly the listener's
own music, with a few songs they do not own that fit the brief. Each of those
is marked as new to them, and the DJ says so. A listener who wants only their
own music gets exactly that.

This is not a future feature. Part C ships it on the catalogue we already
hold, with no new external calls per mix. What stays future is growing the
catalogue from Apple's (see Non-goals).

## Constraints

The founder is on free plans and does not want to max out compute. Every part
below is designed against these budgets.

| Budget | Free limit | Source |
|---|---|---|
| Subrequests per Worker invocation | 50 | Cloudflare Workers limits, read 2026-10-03 |
| CPU per invocation (HTTP and cron) | 10 ms | same |
| Worker requests per day | 100,000 | same |
| Cron triggers per account | 5 | same |
| Workers AI | 10,000 neurons per day, hard stop on Free | Workers AI pricing, read 2026-10-03 |
| bge-m3 embedding | 1,075 neurons per million input tokens | same |
| Neon compute | 100 CU-hours per project per month; scales to zero after 5 idle minutes (400 hours at 0.25 CU) | founder-supplied summary of Neon's Free plan, 2026-10-03 |

Rules that follow:

1. No change may add a Worker invocation that wakes Postgres at a new time of
   day. New cron triggers sit in the minutes right after the existing hourly
   one, so the database wakes once per hour as it does now.
2. No batch size is raised on an estimate. A constant goes up only after a
   test measures the worst-case subrequests it implies.
3. A mix costs no more model calls and no more embedding calls than today.
4. Paid-plan numbers are never assumed. Where a paid plan would help, the spec
   says so and moves on.

## Facts this is built on (production, read-only, 2026-10-03)

- Catalogue: 6,438 tracks. 5,608 carry an Apple ID, 830 a Spotify ID, none
  carry both. 3,883 have an ISRC. 5,353 have features, 5,414 have meanings.
- Two listeners. The 830 Spotify rows are one account's Exportify import.
- 68 ISRCs are held by more than one row.
- Enrichment runs 3 tracks per hourly cron (`CRON_BATCH`), a size chosen for
  a database driver the Worker no longer uses, and shares its invocation
  with six other jobs.
- The pending enrichment queue is 687 tracks, all from that one import.
- The Exportify parsers on web and iOS do not read the ISRC column, and the
  import contract has no ISRC field.

## Part A (prerequisite): enrichment that fits the free plan

Goal: clear a fresh import in days, not weeks, without more invocations
around the clock and without exceeding 50 subrequests.

**A1. Twin copy, no external calls.** Before the enrichment batch, one SQL
statement per table copies `track_features` and `track_meanings` to rows that
lack them from a row sharing the same ISRC that has them. Bounded per run
(500 rows). Copied rows are marked `twin` and keep the donor's timestamps; the donor is
not recorded (that would need a column), and is any row sharing the ISRC. A track enriched this way never enters the external queue. This is
the cheapest throughput there is, and Part B makes it apply on day one of an
import.

**A2. Size the batch from a measurement.** Measured 2026-10-03: 5 outbound
calls per track in the worst case, 2 shared per batch, 7 for linking and the
thumbnail fallback in the same invocation. Shipped at 5 tracks per run.
Background: `CRON_BATCH = 3` was sized for
about 13 subrequests per track, counting every database statement, when the
Worker used the HTTP driver. It now uses a WebSocket pool, where statements
are not subrequests, so only external calls count: roughly 2 per batch for
the Spotify lookups plus 2 to 5 per track (feature search, lyrics,
embedding). A test wraps the external fetchers with a counter and asserts
the worst case per track; the batch constant is derived from that with
headroom. Expected result: 8 or more tracks per run. The other free limit is
10 ms of CPU per invocation, which more tracks per run does spend, so the
batch is raised in steps (3, 5, 8) with the cron log checked for CPU kills
between steps. That is a target to measure, not a promise.

**A3. Enrichment gets its own invocation.** Today cleanup, playlist catalogue
resolution, enrichment, Apple ISRC linking and two artwork jobs share one
50-subrequest budget. Add a second cron trigger two minutes after the first,
dispatched on `event.cron`. `0 * * * *` keeps cleanup, playlist catalogue
resolution and Apple artwork. `2 * * * *` runs twin copy, enrichment, Apple
ISRC linking and the Spotify thumbnail fallback, in that order, because
linking needs the ISRCs enrichment just produced and the fallback must come
after linking has had its chance (a fallback thumbnail sticks for about 30
days). Two of the five free triggers are used. The database is still warm
from the first run, so this adds no wake-up.

**A4. Founder-run drain for a fresh import.** `scripts/drain-enrichment.ts`
calls the existing admin `/enrich/run` endpoint in a loop, one batch per call,
with a delay between calls and a required `--max`. Each call is its own
invocation with its own budget. It runs only while the founder runs it, so
the database is awake only for that sitting. This is how the current 687 get
cleared; the hourly cron then keeps up with normal growth.

Daily budget check: an import of 1,000 songs is about 1,000 embeddings of a
few hundred tokens each, well under one percent of the daily neuron
allowance. A drain of 1,000 tracks at 8 per call is under 150 requests
against 100,000 per day. The provider rate limits (LRCLIB, ReccoBeats) are
the real ceiling, hence the delay in A4.

Not done here: raising the cron to every 15 minutes. It would quadruple
throughput and also keep Postgres awake four times as often.

## Part B (prerequisite): one recording, however it arrived

Goal: the system knows that an Apple row and a Spotify row are the same song,
at import time, so "outside the library" is judged by recording and enrichment
is not paid twice.

**B1. Carry the ISRC at import.** The Exportify parsers (web and iOS) read the
ISRC column through the same header mapping they use for the other columns,
uppercase it, and keep it only if it matches the ISRC shape. The track
snapshot contract gains an optional `isrc`. The staging table gains an `isrc`
column (one migration). Publish writes `coalesce(tracks.isrc, staged.isrc)`,
so an import never overwrites an ISRC enrichment already set. Official Spotify
exports carry no ISRC and are unchanged. Existing imports get their ISRCs by
re-importing the same files; no backfill script.

**B2. ISRCs for Apple rows, nearly free.** About 1,850 Apple rows have no ISRC. The
server catalogue client already fetches songs by Apple ID in batches of 300
and already parses the ISRC; the artwork job simply does not store it. Store
it (`coalesce`) in that job, and run one bounded pass over Apple rows that
have artwork but no ISRC: about 7 catalogue calls for the whole backlog,
inside the existing hourly invocation.

**B3. Twins are a state, not a conflict.** When the Apple-ID linking job
finds that the Apple ID for a Spotify row is already owned by another row
with the same ISRC, it records `twin` and stops retrying, instead of
`conflict` with a 30-day retry.

**B4. Rows are not merged.** Twins stay two rows linked by ISRC, as the
schema decision intends (`apple_id` is one column among peers). Merging would
rewrite foreign keys across user tracks, queues, the listening ledger and
playlist entries for a gain the read-time link already gives. Reads that must
be twin-aware are: the pool (already is), the outside-library test (Part C)
and the twin copy (A1).

## Part C: outside-library picks

### What counts as outside

A catalogue row is an outside candidate for a listener when all hold:

- it has a meaning embedding (it can be matched to a brief);
- its recording (ISRC, else the row id) is not among any of the listener's
  own rows, candidate or not, so a song they played twice is not "new",
  and is not in any playlist they keep, of any kind;
- it is playable for them: a listener with an Apple source or a legacy Apple
  library needs an Apple ID on the row or on its ISRC twin; a Spotify-only
  listener needs a Spotify ID;
- it passes the brief's hard filters (tempo window, era, explicit), exactly as
  a personal candidate does.

Candidly, on today's data: an Apple listener has a few hundred to a few
thousand outside candidates, almost all from one other library. A
Spotify-only listener has none, because no other Spotify importer exists yet
and Spotify IDs cannot be looked up (their API is closed to us). The feature
is built to be correct at any size and will feel thin until there are more
listeners. Part D is the lever for that.

### How many

The cap is set by the familiarity dial the DJ already chooses per brief, and
enforced in code after curation, not left to the model:

| Familiarity | Outside picks, at most |
|---|---|
| comfort | none |
| mix (the default) | 20% of the mix, rounded down |
| adventurous | 40% of the mix, rounded down |

A 15-track default mix carries at most 3. If the model returns more, the
extras are dropped and backfilled from the listener's own pool. The
intent gains one optional field, `allowOutside` (default true, the peer of
`allowExplicit`): the DJ sets it false when the listener, or a saved
preference such as "only play my own music", asks for their own music only,
and the cap is then none whatever the familiarity. "Show me new things"
style requests map to adventurous through the persona.

### How they are chosen

One additional bounded query per pool build, in the same database round trip:

1. Take the 200 nearest catalogue rows to the brief's embedding through the
   existing HNSW index. This is the step that keeps cost flat as the
   catalogue grows; it replaces a scan.
2. Drop the listener's own recordings and unplayable rows, apply the hard
   filters, collapse ISRC twins to the playable row.
3. Score with the corpus-mode formula that already exists: meaning
   similarity, tempo fit, and a familiarity term that is 0.7 when the
   listener already has other songs by that artist and 0 otherwise. A new
   song by an artist they know is the safest outside pick, so it ranks
   first. Learned artist taste and the playlist-inspiration profile apply as
   they do to personal rows.
4. Keep the top `4 x cap` rows, at most 60.

The curation call is the same single call. Outside rows are flagged in the
pool listing, the intent block states the cap, and the prompt drops "assume
they know these songs" for flagged rows. The cost is about 60 more pool
lines, roughly 2,500 input tokens per curated mix. No new model call, no new
embedding call, no new Worker invocation.

Swaps and extends follow the same rule: the batch's outside share is capped
against the whole queue after the edit.

### How the listener sees it

- The queue item gains `newToYou`, computed at read time (the track has no
  row of the listener's). No migration, and it clears by itself once they add
  the song. It is always false in a session flagged not-personal: the
  banner already says those picks are not the listener's own (founder,
  2026-10-03).
- A follow-up edit with no brief of its own ("add five more") brings in no
  outside songs, so it cannot undo an earlier "only my music".
- An empty library gets no outside songs; it gets the honest empty message.
- The generate and edit tool results tell the DJ how many picks are new and
  to say so plainly, as the corpus notice does today.
- Web and iOS show a small "new to you" mark on those rows. This is a visible
  UI change and needs a state board before build.
- "Create as playlist" on a mix with outside picks adds those songs to the
  listener's Apple Music library. That is the listener's action, but the
  confirmation should say it.

### Privacy

An outside pick reveals only that a song exists in the shared catalogue. It
never says whose library it came from, how often anyone played it, or how
many listeners have it. With two listeners the origin is inferable; that is
accepted for now and revisited before any public launch with a minimum
number of holders per recording.

### What it does not change

Corpus mode for listeners with no data, the "not personal yet" flag, the
playlist taste term, and the rule that lyrics are never stored or shown.

## Part D (optional, later): grow the catalogue

Only if the founder wants outside picks to feel rich before there are many
listeners. Each hour, in the existing invocation, one Apple catalogue call
fetches other top songs for a few artists already in the catalogue, and
inserts them as unowned rows for enrichment to reach in its normal order.
Budget: one catalogue call and one insert per hour. Not part of this build.

## Build order

1. A1, A2, A3 (server only).
2. B1 server contract and migration, then B1 parsers on web and iOS, B2, B3.
3. A4, then the founder drains the current queue and re-imports the
   Exportify files to stamp ISRCs.
4. C server (pool, cap enforcement, tool results, `newToYou`), behind a
   server flag that defaults off.
5. C state board for the "new to you" mark, founder approval, then web and
   iOS.
6. Flag on.

Steps 1 to 3 are worth shipping even if C is delayed.

## Tests

- A1: twin copy fills only missing rows, never overwrites, respects the
  bound, records the source.
- A2: worst-case subrequest count per track is asserted; `CRON_BATCH` times
  that count plus fixed overhead stays under 50.
- A3: each cron expression runs only its own jobs.
- B1: parser cases for a present, missing, malformed and translated-header
  ISRC column; publish never overwrites an existing ISRC.
- B3: an Apple ID held by an ISRC twin records `twin` and is not retried.
- C: a listener's own recording is never offered as outside, including
  through a twin; unplayable rows are excluded per platform; the cap holds
  for each familiarity level and after backfill; comfort and the saved
  "own music only" preference yield none; `newToYou` is true only for
  outside picks; hard filters apply; golden-set structural assertions only,
  no exact-track assertions.

## Decisions for the founder

Answered 2026-10-03: yes to 1 to 4 as recommended. 5 is settled: 100 CU-hours
a month. The hourly cron keeps the database awake about 6 minutes an hour,
roughly 18 CU-hours a month at 0.25 CU; the second trigger two minutes later
adds about 2 minutes an hour, roughly 6 more. A3 stays.

1. **Should the default mix include outside picks?** Recommended: yes, up to
   20%, because the request was for recommendations in ordinary mixes. The
   alternative is adventurous-only, which most listeners would never meet.
2. **Caps of 20% and 40%.** Recommended as a starting point; tune from
   removals of outside picks once there is data.
3. **Spotify-only listeners get none for now.** Recommended: accept. The
   alternative is a "find in Spotify" search link for Apple-only rows, which
   is a weaker experience and a separate design.
4. **Part D.** Recommended: decide after Part C has run on real mixes.
5. **Neon compute.** Confirm the current free allowance and idle timeout
   before A3 and A4 are built; if hourly wake-ups already use a large share,
   A3 stays and A4 becomes the only throughput lever.

## Non-goals

Apple recommendation APIs, a live catalogue search during a mix, merging twin
rows, taste-twin matching between listeners, any paid-plan dependency, and
any change to how Spotify listeners play music.

## Reopens if

Outside picks are removed far more often than own picks (lower the caps or
make them opt-in), measured subrequests leave no room to raise the batch
(then A1 and A4 carry the load), or listener count makes the privacy note
above inadequate.
