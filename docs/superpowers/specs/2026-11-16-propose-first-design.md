# Propose first: all of music is the pool

Date: 2026-11-16. Status: decisions taken 2026-11-16 (founder: "take all
five", then a zero-cost rule for outside APIs; recorded in
`../../decisions.md`). Plan: `../plans/2026-11-16-propose-first.md`. S0–S9 built, reviewed and
committed on `feat/propose-first` 2026-11-16 (Gate 0 passed; report
`../../testing/2026-11-16-propose-first-spike.md`). Not deployed: migrations
0052 and 0053, G1, G2 (`PROPOSE_FIRST_USERS`), S10 and G3 are owed.

Follows `2026-10-21-everyone-gets-a-mix-design.md` (step 4, as reshaped on
2026-10-22) and `2026-11-09-every-song-earns-its-place-design.md`. Both made
model-proposed, Apple-verified songs a fallback. This spec makes them the
main source.

## The problem

The DJ can only pick songs that are already in our `tracks` table, and for
most listeners only songs that are already enriched. That table is small and
grows slowly:

- **Our catalogue is tiny next to Apple's.** We hold roughly 15k catalogue
  rows, and far fewer are fully enriched. Apple has 100M+. Most of what a
  prompt could reach is invisible to the DJ.
- **Enrichment is the bottleneck, not adding songs.** Gate 3's first sitting
  added 9k tracks in twenty minutes and enriched 85 of them before LRCLIB
  rate-limited us and ReccoBeats found no match for about 30% of chart songs
  (decisions 2026-10-22). The cron (every 10 minutes, decisions 2026-11-06)
  cannot catch up with a catalogue the size of Apple's.
- **Library listeners are boxed in by their library.** A listener with music
  of their own is curated from that music. Model proposals only fill a
  shortfall (`every-song-earns-its-place`, decision 2), plus `OUTSIDE_PICKS`,
  which is off in production. Mixes repeat the same artists, and genre
  prompts their library doesn't cover come back short.
- **Corpus listeners are already halfway there.** `CORPUS_PROPOSE_SHARE` is
  0.5 (`dj/loop.ts`): half of a corpus mix comes from the model and is
  verified on Apple. This path works in production and is what we build on.

## What the research found (2026-11-16)

No single API has every song plus lyrics meaning, BPM, mood and genre.

| Need | Source | Notes |
|---|---|---|
| Existence, playability, ISRC, genre, year | Apple Music API (in use) | 100M+ songs. Free. Genres are broad |
| Tempo, key, energy, valence, danceability, etc. | Soundcharts Audio Features API | "Millions of tracks", looked up by ISRC. Paid; their own pages say both $50/mo (10k queries) and $250/mo (500k). Rejected 2026-11-16 (no paid data APIs) |
| Same, free | ReccoBeats (in use) | ~70% match on chart songs, unpublished rate limits |
| BPM only | Deezer track API | Free; BPM often missing |
| Mood/genre tags | Last.fm tags | Mostly genre words; patchy |
| Lyrics meaning | Musixmatch commercial licence | Sales-quoted. Deferred, as the lyrics stance already says |
| Analysis from audio | Cyanite, Essentia | Needs audio files. Not viable |

**Founder rule (2026-11-16): no paid data APIs.** Claude tokens, Workers
Paid and the Apple Developer Program are the only spend. Soundcharts is out;
the feature stack below is free.

**The key point:** the curation model already knows nearly every notable song,
including what it's about, its era, its energy and its scene. That covers
"meaning" for the songs that matter most in a mix, without us handling lyric
text, and fits the lyrics stance in `docs/decisions.md`. What the model can't
do reliably is measure numbers, so tempo and energy come from a feature API.

## Direction

Every generate builds one candidate set from three sources, and the curator
picks from all of it:

1. **The listener's own music** (library, seeds, counted plays), as now via
   `buildPool`. It's the strongest taste signal and the default for
   "comfort" mixes.
2. **Model proposals**, taken from all of music for this brief, written with
   the listener's taste in view (top artists, recent mixes, saved
   preferences), and each one verified on Apple in their storefront
   (`proposeSongs` + `verifyProposals`).
3. **The shared catalogue's nearest neighbours** (`buildOutsidePool`). It's
   cheap, already enriched, and keeps working when the model is slow.

The mix's `familiarity` sets how the set is weighted, not where songs come
from. Every verified proposal joins the catalogue for everyone, as today. Our
database becomes a cache and a memory, not the universe.

Features are looked up **per mix, not ahead of time**: once verification
finishes, every candidate with an ISRC but no features goes through the free
chain (Step 1), is written to `tracks`, and used for sequencing right away.
The enrichment cron keeps embedding meaning for library songs, but stops
being something mixes have to wait on.

**Proposed songs get no meaning embedding.** The model already knows what
they are about, and a `track_meanings` row (about 5 KB at `halfvec`) for
every verified song would push the Neon free plan's storage. They get one
only if they later land in someone's library or turn up in mixes again and
again (Step 4).

As built (S6): `verifyProposals` inserts new rows with
`tracks.meaning_deferred = true` (`PROPOSAL_QUEUE` in `dj/catalogue-fill.ts`;
held rows keep their flag). The cron (`enrich/runner.ts`, `DEFER_MEANING`)
skips their meaning stage while the song is in no library
(`user_tracks.in_library`) and sits in fewer than `MEANING_RECUR_SESSIONS`
(3) distinct sessions' queues (any queue state), read live so nothing flips
the flag. Features still run. Migration 0053 adds
`queue_tracks_track_session_idx (track_id, session_id)` so the session
count is an index scan.

`allowOutside: false` ("only my own music", or a saved preference saying so)
still wins over everything here.

## Step 0: measure before building (spike, no production change)

A script under `server/scripts/`, run locally against production data with
read-only credentials.

- **Free feature coverage:** run 500 catalogue ISRCs (stratified: chart, deep
  library cuts, non-English, pre-1980) plus 200 from verified proposals
  through ReccoBeats, then Deezer by ISRC for what's left. Record each
  provider's hit rate, latency and 429s. For songs ReccoBeats does have, ask
  the model for its energy estimate and compare (mean absolute error), to
  decide whether estimates are good enough to sequence with.
- **Proposal quality for library listeners:** for the founder account and the
  Exportify test account, run 15 prompts from the 2026-11-09 pressure test
  through `proposeSongs` with taste context. Record the Apple verify rate,
  share of covers/live versions picked by mistake, and how often proposals
  are songs the listener already owns.
- **Token cost:** Sonnet input and output tokens per generate before and
  after, for a library listener (the new proposal call plus the larger
  curation pool).

**Gate 0:** verify rate ≥ 70% on mainstream briefs (the existing reopen
clause from 2026-10-22); measured energy (ReccoBeats) on ≥ 60% of verified
proposals; model estimates within 0.15 of measured energy on average. If
estimates miss that, sequencing uses measured energy only and Step 3's goal
shrinks to match.

## Step 1: a free feature chain looked up per mix (server)

- `enrich/features-chain.ts`, in order, stopping at the first that answers:
  1. **ReccoBeats** (in use): the full measured set. Free, no key.
  2. **Deezer by ISRC** (`api.deezer.com/track/isrc:<ISRC>`): tempo only,
     when its `bpm` is above 0. Free, no key; we already call Deezer for
     artwork.
  3. **Model estimate**: energy and valence for what's still missing, asked
     inside the proposal call itself (the model returns `energy` and
     `valence` beside each title), so it costs no extra call.
- `track_features` stays measured-only (ReccoBeats; its `source` column
  already exists). A row there is what makes a song count as enriched for
  the corpus pool and the cron, so Deezer tempo and model estimates go in a
  new table `track_feature_fallbacks` (with `tempo_source` and
  `mood_source`). Pools read measured values first, then the fallback. A
  measured value wins as soon as the cron gets one.
- `evaluateEnergyJourney` counts **measured** values only, so the DJ never
  claims a measured shape from guesses. Estimates may guide the order, but
  not the assessment.
- Misses follow the 2026-10-04 failure rules: an outage doesn't use up
  attempts, a real miss does. ReccoBeats 429s during a turn are not retried
  in the turn; the song falls through to Deezer and the estimate, and the
  cron tries ReccoBeats again later.
- GetSongBPM stays off: it needs a visible getsongbpm.com backlink wherever
  its data shows (CLAUDE.md). It reopens only if Deezer tempo coverage is
  poor in Step 0.

Tests: chain contract tests with fake HTTP (ReccoBeats hit; ReccoBeats miss
→ Deezer tempo; both miss → estimate; Deezer `bpm: 0` treated as a miss; 429
falls through); estimates never count in `evaluateEnergyJourney`; a measured
value overwrites an estimate.

## Step 2: one candidate set for everyone (server, behind `PROPOSE_FIRST`)

- New flag `PROPOSE_FIRST` (`"on"`/`"off"` in `wrangler.jsonc`, read once per
  request like `NEVER_REFUSE`). Off by default.
- With it on, `generate` for a **personal** listener runs `buildPool`,
  `proposeSongs` and `buildOutsidePool` in parallel and merges them into one
  pool. Proposals are told what the listener already owns, so they spend
  their slots on songs not in the library unless the brief asks for
  favourites.
- Weights by `familiarity` (decision 2 sets the numbers). They replace
  `OUTSIDE_SHARE` in `dj/pool.ts` (comfort 0, mix 0.2, adventurous 0.4),
  which today only caps catalogue outside picks:
  - `comfort`: mostly the library, proposals for the gaps.
  - `mix`: library and proposals roughly even.
  - `adventurous`: mostly proposals.
- Corpus listeners: `CORPUS_PROPOSE_SHARE` rises (decision 2), and the
  catalogue curation that covers misses stays.
- Edits (`edit_queue` swaps/extends) use the same merge, so "swap in some
  Kendrick" can reach Kendrick songs the listener doesn't own.
- Turn-level limits (`VERIFY_MAX` 22, `VERIFY_DEADLINE_MS` 10s,
  `VERIFY_CONCURRENCY` 4, all in `dj/propose.ts`) get re-measured, not just
  raised. Apple's rate limit is the real ceiling, and the existing
  `checking` turn step (`dj/turn-steps.ts`) should cover verification too.
- Every song the listener doesn't own keeps the "new to you" mark and the
  DJ says which picks are new, as `OUTSIDE_PERSONA_LINE` already requires.
- Spotify-only listeners: proposals are still verified on Apple (the only
  catalogue we can search). They get "Open in Spotify" search links like
  outside picks today, and that limit stays (decision 5).

Tests: golden-set structural assertions, never exact tracks. Library
listener + uncovered genre brief → no shortfall notice and ≥ half the mix
fits the genre label; `allowOutside: false` → zero proposals; `comfort` →
library majority; an edit naming an artist the listener doesn't own → that
artist appears.

As built (S7): `proposeFirstEnabled(env, userId)` in `src/index.ts` (exact
`"on"`, or the listener's id in the optional `PROPOSE_FIRST_USERS`), wired
as `DjDeps.proposeFirstFor` and resolved once per turn by `runDjTurn` into
`DjDeps.proposeFirst`. The personal blend reuses the corpus blend
(`blendProposals` in `dj/loop.ts`) rather than merging one pool: it runs
beside the library curation, which is asked for the whole `targetCount`
so it covers any proposal that fails or misses on Apple; the mix takes up
to the proposed share (`PROPOSE_SHARE`) of verified songs and the rest from
the curation in its order. Only a library that itself curates short is
topped up from the same round (`topUpFromBlend`), and only then can a
shortfall notice fire. A personal blend whose library curation fails fails
the turn, as before. A remake ("Remake with my music") never blends, and
with propose first active the OUTSIDE_PICKS outside pool is off (cap 0). Proposals use the personal
prompt with top artists, and the pool's own songs (up to 60) as the
exclude list. The mix stays personal (`not_personal` unset, no
`CORPUS_NOTICE`); `personalBlendNotice` replaces `blendedNotice`, the
listings and session context carry the "| new" marks, and the persona is
`PERSONA_PROMPT_WITH_PROPOSE_FIRST` (its own line: no "few", no cap). "New to you" needs no new column: the queue
view derives it from ownership. Open: the gate is `ownMusicBrief`, which
reads `comfort` as favourites, so `comfort`'s 0.25 share never applies
until comfort and favourites are told apart.

As built (short-mix fix, 2026-11-16): live, "lofi afro house slow living"
came back 1 to 3 songs: the round was sized to the proposed share, so a
library that curated next to nothing for the genre left too few unsearched
proposals to top up from, and proposals the sound check dropped were never
replaced. A personal blend's one proposal call now asks for the whole mix
(`proposalCount`: `targetCount + PROPOSE_EXTRA`, at most `VERIFY_MAX`) and
still verifies only its share up front; the unsearched rest are spares.
`topUpFromBlend` draws on them when the library is short, and once more
after the proposals' sound check if the mix is still short (the gap plus
`genreSpares`, one more check call at most). No second proposal call; the
corpus blend and flag-off paths are unchanged. The genre notice counts only
the mix's empty places. Separately, `pickHit` no longer reads "(Original
Mix)" or "(Extended Mix)" as a version (the canonical naming of house and
electronic releases on Apple); club, dub, radio mixes and remixes still
are. An exact title wins, then an original mix over an extended one the
proposal did not name.

As built (S8, edits): a personal listener's swap or extend goes outside
their music only when it cannot be covered from it: a named or artist-only
scope with no songs to draw on (after the existing catalogue and Apple
top-songs fill), or a curation that returns fewer than asked (nothing fits
the genre or mood). Then one proposal call per request asks for the songs
still needed plus `EDIT_SPARES` (2), all verified on Apple inside the
turn's `VERIFY_MAX` and deadline, so a song dropped afterwards (already in
the queue or batch, by track or by song, or failing the sound check) falls
back to a spare; `fillProposalFeatures` runs on what lands. A request
proposes only while the curation budget keeps one curation for each later
request in the batch, so the cap (6) is never tripped; with no room it is
short as before. A scoped request keeps only proposals and Apple hits
crediting its artists. Same gates as the blend: propose first active, an
intent the model chose (never the weak fallback from the listener's
words), never `ownMusicBrief`, `allowOutside: false` or a remake turn.
Landed songs are marked new (`outsidePicksNotice`). What is still short is
said once: proposals the sound check dropped by `genreCheckNotice`, the
rest by `editOutsideShortNotice`, one per scope (named artists, or none);
a swap with nothing confirmed keeps its original song. The machinery is
shared with the corpus (NEVER_REFUSE) edit path (`proposeEditSongs`),
which now asks for 2 spares too. Known limit: a saved "only my own music"
preference reaches an edit only through the op's own intent
(`allowOutside: false` set by the model), as for outside picks; an edit
with no intent of its own never goes outside.

## Step 3: sequencing uses the new features (server)

- Once candidates are chosen, the batch feature lookup runs (Step 1) before
  the order is committed, within the turn's deadline. A miss leaves the
  energy null, the way it is today.
- `evaluateEnergyJourney` stays an assessment, not a sort. With coverage up,
  far fewer mixes should come back `limited`. Track that rate before and
  after as the measure that Step 3 worked.

As built (S9, energy-aware interleave): in a blended mix (corpus or
personal) the feature chain now runs on the blended proposals before
`interleaveBlend`, which takes the intent's `energyArc` and an energy
getter: measured (`track_features`), then `track_feature_fallbacks`, then
the proposal's own estimate (Gate 0 passed, MAE 0.134), read in one query.
With `rise`, `fall` or `arc` and a usable energy for at least 2/3 of the
proposed songs, the proposed slots and the curated songs stay exactly
where the even spread puts them; only which proposed song takes which
proposed slot changes, matched to the arc's curve scaled to the
proposals' own energy range (least total distance). Unknown energies take
the slots left over, in their original order. `steady`, no arc or too few
known energies is the even spread unchanged, with no extra read. Curated
order (the curator's order and pins) is never touched; the journey
assessment remains an assessment.

## Step 4: rethink catalogue seeding (server, docs)

- Stop seeding the catalogue in sittings from Apple charts just to have
  something to score. Proposals now grow the catalogue with songs people
  actually asked for.
- The cron keeps meaning embeddings for library songs and anything verified
  more than once (they're useful for "more like this" and nearest
  neighbours).
- Update the design spec and `docs/decisions.md`, and close the Gate 3
  seeding sittings in `everyone-gets-a-mix`.

## Gates

- **Gate 0:** the spike numbers above.
- **Gate 1 (Step 1 live):** every new row has a tempo or energy from some
  source; measured share recorded as the baseline; no rise in turn errors.
- **Gate 2 (`PROPOSE_FIRST` on for the founder account only):** the
  2026-11-09 pressure test's 16 prompts re-run. "90s r&b slow jams",
  "soft jazz" and "focus music, no vocals" each come back on-brief and full
  length. Artist repetition across five mixes drops. No reply claims a song
  that isn't in the mix. Founder listening check on device.
- **Gate 3:** on for everyone. Watch for one week: verify rate, median turn
  time, Sonnet tokens per turn, Neon storage, "new to you" songs played vs
  skipped.

## Risks

- **The model drifts to obvious hits.** Proposals lean on the canon. Taste
  context and `familiarity` are the fix to try first; the 2026-10-22 reopen
  clause ("read as generic") applies.
- **Apple search picks covers, live or sped-up versions.** `pickHit` already
  guards this; Gate 2 checks for it directly.
- **Turn time goes up.** Proposal + verification adds a model call and up to
  22 searches. The parallel start in Step 2 and the turn-steps UI cover most
  of this; the 10s verify deadline still holds.
- **Free providers can vanish or throttle.** ReccoBeats has unpublished
  limits and Deezer's ISRC path isn't formally documented. The chain degrades
  to estimates rather than failing, and `track_feature_fallbacks` shows how much
  of a mix is guessed.
- **Measured coverage stays around 70%.** Free sources miss deep cuts and
  non-English songs most. That is the accepted cost of the zero-spend rule;
  a paid feature API is the reopen path once there are paying users.
- **Apple rate limits** at higher traffic: unknown today. Measure in Step 0
  and watch in Gate 3.

## Where this costs money

Outside APIs: $0. ReccoBeats, Deezer, LRCLIB and the Apple Music API are
free (Apple's is covered by the Developer Program we already pay for).

- **Claude tokens (the only real new cost).** One extra Sonnet call per
  generate for library listeners: proposals plus energy estimates, a few
  thousand input tokens and roughly 1–2k output. Corpus listeners already
  pay for it today. Curation also sees a bigger pool, so its input grows.
  Swaps that propose replacements add a small call each. Step 0 measures
  the exact numbers.
- **Cloudflare Workers.** Up to 22 Apple searches plus a few feature lookups
  per turn are subrequests, which Workers Paid doesn't bill separately.
  Turns run a little longer, but CPU time (what's billed) barely moves
  because the Worker is mostly waiting on network.
- **Neon.** Still the free plan. Verified songs add a `tracks` row each
  (small); skipping meaning embeddings for proposed songs keeps storage in
  check. Fewer cron enrichments (Step 4) mean less compute time awake.

## Not in this spec

- Licensed lyrics (Musixmatch) and any lyric text. The lyrics stance holds.
- Upload-based audio analysis.
- Spotify catalogue search (still closed to us).

## Decisions (founder, 2026-11-16)

1. **Feature data: free only.** ReccoBeats, then Deezer tempo by ISRC, then
   the model's own estimate, labelled as such. Soundcharts rejected: no
   paid data APIs while there are no paying users.
2. **Weights.** Proposals make up 25% of `comfort` mixes, 50% of `mix` and
   75% of `adventurous`; `CORPUS_PROPOSE_SHARE` goes from 0.5 to 0.75.
   Tuned after Gate 2.
3. **`OUTSIDE_PICKS` retires.** `PROPOSE_FIRST` replaces it.
4. **Cost cap: $0 for outside APIs.** Spend stays on Claude tokens and
   Workers Paid.
5. **Spotify-only listeners** get proposals as Spotify search links, as
   with outside picks today.

**Reopens if:** measured energy covers under 60% of proposed songs and
mixes audibly lose their shape, a free provider closes, or paying users
arrive (then a paid feature API is the first thing to revisit).
