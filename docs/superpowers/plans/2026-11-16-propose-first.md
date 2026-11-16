# Propose first — plan

**Status:** decisions taken 2026-11-16 (founder: "take all five", then
zero-cost outside APIs; "Write the plan"). Nothing built yet.
- Spec: `../specs/2026-11-16-propose-first-design.md`.
- Decision: `../../decisions.md` → 2026-11-16 Propose first.

**Cadence:** house style. Each task goes to a fresh implementer agent (Opus)
with red-first tests, then a reviewer pass and one fix round, then one
commit per task with files staged by explicit path. At most two agents in
flight. Server only: no client task. The "new to you" mark and the
`checking` turn step already exist on web and iOS.

**Order:**
1. S0 (spike) first. Its numbers set Gate 0, and nothing ships before it
   passes.
2. S1 → S2 → S3 → S4 → S5 (data path). S2 and S3 can run side by side once
   S1 is committed.
3. S6 (meaning deferral) any time after S1.
4. S7 → S8 → S9 (propose first, behind the flag). They need S4 and S5.
5. G1, G2, then S10 (retire `OUTSIDE_PICKS`), then G3. S11 (docs) rides with
   each task and closes at the end.

## Before starting

- **Branch.** Cut `feat/propose-first` from `main` once `feat/stop-turn` is
  merged, or from `feat/stop-turn` if it isn't yet (say which in the first
  commit's PR). Run implementers in a worktree; never stage another
  session's hunks.
- **Migration number.** Check `server/drizzle/` for the highest number
  before S1. The plan assumes `0052` (after `0051_turn_stop`).
- **Deploys** go from a clean `git worktree` of committed HEAD, never the
  working tree (CLAUDE.md).
- **No paid APIs.** No task adds a key-gated or billed provider. If one
  seems needed, stop and ask.

## A correction to the spec, found while planning

The spec's first draft put a `features_source` column on `tracks`. That
won't work as written. A `track_features` row is what makes a song count as
enriched:
- `resolvePoolMode` and the corpus pool both test
  `EXISTS (SELECT 1 FROM track_features …)` (`dj/pool.ts` ~413, ~922);
- the cron skips a song's features stage once its row exists
  (`enrich/runner.ts`, `SKIP_FEATURES`).

A Deezer-tempo-only or model-estimated row in `track_features` would put a
song in the corpus before it's really scored, and stop ReccoBeats from ever
being retried for it.

**So:** `track_features` stays measured-only (ReccoBeats, as now; its
`source` column already exists). Fallback values go in a new table
`track_feature_fallbacks`. Pools read measured values first, then the
fallback. The energy-journey assessment reads `track_features` only, so it
stays measured-only without a code change there. The spec now says this.

## Shared contract

- **`track_feature_fallbacks`**
  `(track_id uuid pk → tracks.id on delete cascade, tempo double, energy double, valence double, tempo_source text, mood_source text, fetched_at timestamptz default now())`.
  - `tempo_source` ∈ `deezer` | `model`.
  - `mood_source` (energy and valence) = `model`.
  - Values are range-checked on write: tempo 40–250, energy and valence 0–1;
    anything else is stored as null.
- **`tracks.meaning_deferred boolean not null default false`.** It's set
  true when a row is first inserted by the proposal path.
- **Proposal JSON** gains optional `energy` and `valence` (0–1) per song,
  beside `title`, `artist` and `reason`. Missing or out-of-range values are
  dropped, never fatal.
- **`PROPOSE_FIRST`**: `"on"`/`"off"` under `vars` in `server/wrangler.jsonc`,
  default `"off"`, read once per request in `src/index.ts` like
  `NEVER_REFUSE` (`proposeFirstEnabled(env)`). For G2,
  `PROPOSE_FIRST_USERS` (comma-separated user ids) turns it on for those
  users only; removed in S10.
- **Shares:** `PROPOSE_SHARE = { comfort: 0.25, mix: 0.5, adventurous: 0.75 }`
  for personal listeners. `CORPUS_PROPOSE_SHARE` becomes 0.75 when
  `PROPOSE_FIRST` is on (0.5 when off, so production doesn't change until
  the flag flips).

## Tasks

### S0. Spike: free coverage and proposal quality (founder-run)

About half a day. `server/scripts/propose-first-spike.ts`, run locally with
read-only `DATABASE_URL` and the dev Anthropic key. It writes a markdown
report to `docs/testing/2026-11-16-propose-first-spike.md`.

- Sample 500 catalogue ISRCs (stratified: chart, deep library cuts,
  non-English, pre-1980), run them through ReccoBeats (existing
  `enrich/reccobeats.ts`), then Deezer
  `GET https://api.deezer.com/track/isrc:<ISRC>` for misses. Record hit rate
  per provider, how often `bpm` is 0, p50/p95 latency, and 429s.
- For the founder and Exportify test accounts, run the 15 prompts from the
  2026-11-09 pressure test through `proposeSongs` (`listener: 'personal'`,
  with top artists) and `verifyProposals`. Record verify rate, wrong-version
  picks (judged by eye from the report), share of songs already owned, and
  input/output tokens per call.
- For proposals ReccoBeats measured, compare the model's energy estimate
  (prompt from S3, inlined here) with the measured value: mean absolute
  error.

**Gate 0** (spec): verify rate ≥ 70% on mainstream briefs; ReccoBeats
energy on ≥ 60% of verified proposals; estimate error ≤ 0.15. If estimates
miss, S9 uses measured energy only.

### S1. Schema: fallbacks table and meaning deferral

About 1 hour.
- `src/db/schema.ts`: `trackFeatureFallbacks` table and
  `tracks.meaningDeferred`, per the contract.
- `drizzle/0052_propose_first.sql` plus journal entry.
- Tests: a migration test in the style of
  `test/enrich/apple-isrc-migration.test.ts` (table and column exist,
  cascade delete, default false).

### S2. Deezer tempo by ISRC

About 1.5 hours.
- `src/enrich/deezer-tempo.ts`:
  `createDeezerTempoClient({ fetchLike })` →
  `tempoByIsrc(isrc): Promise<number | null>`.
  - `bpm` ≤ 0, a missing field, or Deezer's `{ error: … }` body (which comes
    back as 200) → null.
  - 5xx, a timeout or a fetch failure → `EnrichSourceError` with
    `transient: true`, following the 2026-10-04 rules.
  - 4s timeout. Reuse the artwork client's `fetchLike` wiring in
    `src/index.ts`.
- Tests (`test/enrich/deezer-tempo.test.ts`): hit, `bpm: 0`, error body,
  500, timeout, ISRC uppercased in the URL.

### S3. Proposals carry energy and valence estimates

About 2 hours.
- `src/dj/propose.ts`:
  - The proposal prompt asks for `energy` and `valence` (0–1, "your best
    estimate of how the recording feels") per song. Both prompts change,
    each staying a static string so it still caches.
  - The parser keeps them on `Proposal`. `verifyProposals` carries them onto
    `VerifiedProposal` as `estimate?: { energy, valence }`.
  - Out-of-range or non-numeric values → undefined.
- Tests (`test/dj/propose.test.ts`): parsed when present; dropped when
  missing, a string, or out of range; an old-shape reply still parses; both
  prompts are still exported constants.

### S4. Per-turn feature chain for proposed songs

About 3 hours.
- `src/enrich/features-chain.ts`:
  `fillFeaturesForTurn(db, deps, songs: { trackId, isrc, title, artist, durationMs, estimate? }[], { deadlineMs, concurrency })`.
  - Skips songs that already have a `track_features` row.
  - **ReccoBeats** (existing fetch): a hit is written to `track_features`
    exactly as `enrich/pipeline.ts` does (`source: 'reccobeats'`).
  - **A miss or a 429** is not retried in the turn. The song falls through
    to Deezer tempo (S2), and then the S3 estimate, both written to
    `track_feature_fallbacks`.
  - A real ReccoBeats miss records an `enrichment_failures` row as the cron
    would, so the cron's backoff applies.
  - Never throws. Returns `{ measured, fallback, skipped }` for logging.
- Wire it into the DJ turn after verification, for verified proposals only,
  within `FEATURES_DEADLINE_MS = 6_000` and concurrency 4. Its subrequests
  count in the turn's subrequest budget
  (`test/enrich/subrequest-budget.test.ts` updated).
- Tests (`test/enrich/features-chain.test.ts`, fake HTTP):
  - ReccoBeats hit → `track_features`;
  - miss → Deezer tempo plus estimate in fallbacks;
  - 429 → fallthrough and no attempt used up;
  - deadline hit → the rest get estimates only;
  - an existing measured row is untouched.

### S5. Pools read measured, then fallback

About 1.5 hours.
- `src/dj/pool.ts`: every query that selects `f.tempo`, `f.energy`,
  `f.valence` (`buildPool` ~1052, `buildOutsidePool` ~1271, the seed query
  ~505) also `LEFT JOIN track_feature_fallbacks fb` and selects
  `COALESCE(f.x, fb.x)`.
  - Corpus membership and `resolvePoolMode` stay on `track_features` and
    `track_meanings` only: no change there.
- Tests (`test/dj/pool.test.ts`):
  - a song with fallbacks only shows its estimate in the pool;
  - measured beats fallback when both exist;
  - a fallback-only song is **not** corpus-eligible;
  - `evaluateEnergyJourney` via `mix-history` still sees null for a
    fallback-only song (`test/dj/mix-history.test.ts`).

### S6. Proposed songs skip meaning embeddings

About 1.5 hours.
- `src/dj/catalogue-fill.ts`: `addCatalogueSongs` takes
  `{ meaningDeferred: true }` from the proposal path (`dj/propose.ts`) and
  sets it on insert only. It never clears an existing row's flag, and never
  sets it on a row that's already held.
- `src/enrich/runner.ts`: `SKIP_MEANING` also skips when
  `t.meaning_deferred` holds and the song is in no library
  (`NOT EXISTS user_tracks … in_library`) and sits in fewer than 3 sessions'
  queues. So a song that enters a library, or recurs, gets its embedding
  without a flag flip.
- Tests (`test/enrich/due-tracks.test.ts`, `test/dj/catalogue-fill.test.ts`):
  - a deferred catalogue song isn't due for meaning but is due for features;
  - a deferred song in a library is due;
  - one in 3 sessions' queues is due;
  - seeding and sync inserts aren't deferred.

### S7. `PROPOSE_FIRST`: personal mixes blend proposals

About 4 hours. The core change.
- `src/index.ts`: `proposeFirstEnabled` (plus the `PROPOSE_FIRST_USERS`
  override), passed into `DjDeps` as `proposeFirst`. `server/wrangler.jsonc`:
  `"PROPOSE_FIRST": "off"` plus its comment line.
- `src/dj/loop.ts` (`executeGenerate`, around the `blending` line):
  - With `proposeFirst`, `neverRefuse`, `deps.fill`, and an outside-allowed
    brief (`!ownMusicBrief(intent)` and `allowOutside !== false`), a
    **personal** listener blends too.
  - `blendProposals` takes the share from `PROPOSE_SHARE[intent.familiarity]`
    for personal and `CORPUS_PROPOSE_SHARE` for corpus. It uses the
    `listener: 'personal'` prompt with `topArtists`, and tells the model the
    listener already owns the curated pool's songs (pass the pool's
    title/artist list, capped at 60, as `exclude`) unless the brief asks for
    favourites.
  - The curation call for a personal pool is unchanged: thinking stays as it
    is, and the corpus-only `thinking: 'off'` stays corpus-only.
  - Curated songs are asked for at `targetCount − want`, so the mix isn't
    padded from the library; the existing shortfall path still tops up.
  - Model notices: a personal blend never sets `not_personal` and never
    sends `CORPUS_NOTICE`. It sends a new
    `personalBlendNotice(count)` ("N of these picks are songs they don't own
    yet, chosen for this brief and checked on Apple Music; say which"). The
    persona uses the `PERSONA_PROMPT_WITH_OUTSIDE` variant when
    `proposeFirst` is on.
  - Verified personal-blend proposals are written with `outside: true`, so
    clients show the existing "new to you" mark.
  - S4 runs on the blend's verified songs.
- `CORPUS_PROPOSE_SHARE` → a function of `proposeFirst` (0.75 on, 0.5 off).
- Tests (new `test/dj/propose-first.test.ts`, fake LLM and Apple):
  - flag off → byte-identical behaviour to today (reuse
    `outside-picks-flag-off.test.ts`'s approach);
  - personal + `mix` + 20 songs → ~10 proposed, interleaved, marked outside;
  - `comfort` → library majority; `adventurous` → proposal majority;
  - `allowOutside: false` and an own-music brief → zero proposals;
  - a personal blend never sets `not_personal`;
  - the uncovered-genre golden case (library with no jazz, "soft jazz") →
    no shortfall notice, and ≥ half the mix labelled jazz.

### S8. Edits use the blend

About 2.5 hours.
- `executeEditQueue` swaps and extends: with `proposeFirst`, a swap or extend
  that names an artist, genre or mood the pool can't cover proposes from
  outside (with 2 spare proposals per edit, closing the backlog's "a swap
  proposes one song" note), verified the same way. `allowOutside: false`
  still wins.
- Tests: "swap in some Kendrick" with no Kendrick in the library adds a
  Kendrick song; with Kendrick in the library it uses the library row; a
  failed verify keeps the original song and says so.

### S9. Energy-aware interleave

About 2 hours.
- `interleaveBlend` gets an optional `energyArc` and an energy getter.
  - With an arc set and energy known (measured or fallback) for ≥ 2/3 of
    the proposed songs, each proposed song goes to the free slot whose
    position on the arc's target curve is closest to its energy.
  - Otherwise, the current even spread.
  - Curated order is never changed (the curator's order and pins stand).
- If Gate 0's estimate error failed: the getter returns measured energy
  only.
- Tests (`test/dj/interleave-blend.test.ts`): `rise` puts low-energy
  proposals early and high late; unknown energies fall back to the even
  spread; curated relative order is preserved; length and counts are
  unchanged.

### S10. Retire `OUTSIDE_PICKS` (after G2)

About 2 hours.
- Remove the flag and `PROPOSE_FIRST_USERS` from `src/index.ts`,
  `wrangler.jsonc` and `DjDeps`.
- With `proposeFirst` on, `outsideCap(intent)` feeds `buildOutsidePool` as
  the third source (spec Direction, source 3). With it off, cap 0 as now.
- `conversationVariant` picks the outside persona and tools on
  `proposeFirst`, otherwise the fill variant.
- `outside-picks-flag-off.test.ts` becomes a `PROPOSE_FIRST` off test.
  Delete what only tested the old flag.

### S11. Docs

Rides with each task; closes after G3.
- Spec: a status line per step, plus as-built notes.
- `docs/backlog.md`: a Propose first entry, kept current; close the
  "swap proposes one song" note after S8; mark the everyone-gets-a-mix
  Gate 3 seeding sittings closed (spec Step 4).

## Gates

- **G0** (after S0): spike numbers against Gate 0. Founder reads the report.
- **G1** (S1–S6 deployed, flag off): migration applied; the cron's feature
  and meaning counts look right (`/enrich/run` report); a corpus mix
  (`NEVER_REFUSE` path, which already proposes) shows estimates for proposed
  songs in the pool; no rise in turn errors in Workers logs.
- **G2** (S7–S9 deployed, `PROPOSE_FIRST_USERS` set to the founder):
  - Re-run the 16 pressure-test prompts.
  - "90s r&b slow jams", "soft jazz" and "focus music, no vocals" are
    on-brief and full length.
  - Artist repetition across five mixes drops.
  - No reply claims a missing song.
  - Founder listening check on device.
  - Median turn time recorded.
- **G3** (S10 deployed, flag on for everyone): one week of verify rate,
  median turn time, Sonnet tokens per turn, Neon storage, and "new to you"
  songs played vs skipped. Reopen clauses in the decision apply.
