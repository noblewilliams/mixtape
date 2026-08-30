# Mixtape — Vision

*Last updated: 2026-08-29*

## One-liner

**Mixtape is your personal DJ.** Tell it what you want to hear — a mood, a moment, a memory — and it builds the exact queue for that session from everything it knows about your taste.

## The problem

Streaming apps have infinite catalogs but shallow understanding. Their playlists are made for segments, not for *you right now*. Building the right queue by hand takes the exact mental energy you don't have in the moment ("I want something for this drive / this heartbreak / this deadline") — so people fall back on the same saved playlists, or shuffle, and the moment passes unmatched.

## The promise

A perfect queue from a prompt. "Perfect" means the result matches what the listener actually wants to hear **right now**, drawing on every signal available:

- **Their history** — library, playlists, real play counts, recency, skips
- **Sound** — genre, BPM, energy, key, acoustic character
- **Meaning** — what the lyrics are actually about, matched to the prompt's emotional intent
- **The prompt itself** — parsed for mood, energy arc, era, familiarity level, exclusions ("no sad songs"), and anything else the listener expresses
- **The session** — every swap, pin, ban, and skip refines both this queue and the long-term taste model

And it's a conversation, not a slot machine: refine, cherry-pick, regenerate the back half, ask for "more like #4". The system thinks *with* the listener until the queue is right.

## Core concepts

| Concept | What it is |
|---|---|
| **Session** | The primary object. A generated queue for a moment — played like radio, ephemeral by default. Nothing is written to the user's library unless they ask. |
| **Playlist conversion** | Any session, live or from history, can become a real Apple Music playlist with one tap — days later included. |
| **Taste graph** | The per-user model built from library, play counts, playlists, recents, and in-app behavior. The moat and the memory. |
| **Track enrichment** | Per-track (not per-user) annotation: BPM, key, energy, genre tags, lyric-meaning embedding. Cached globally — the corpus compounds. |
| **Refinement loop** | The conversational editing of a live queue. Also the best taste-training signal we have. |

## What mixtape is NOT

- Not a streaming service — playback is the platform's (Apple Music first). We never touch audio delivery.
- Not a social *feed* — no posting, no follower counts, no sharing pressure. Social in mixtape means **taste**, not content: blended sessions from multiple people's histories, and finding the people whose taste most resembles yours (amended 2026-08-30 — see "Social: the taste graph meets other people" below; the original v1 stance was "personal DJ, singular").
- Not a lyrics app — lyric *meaning* powers matching invisibly; we never display lyric text (see licensing stance in the design spec).
- Not a discovery firehose — familiarity is a dial the listener controls, not a growth metric.

## Endgame

The long-term bar: **mixtape knows your music taste better than you can articulate it.** You stop making playlists. Before a run, a dinner, a flight, a low evening — you say one sentence, and what plays is what you would have picked if you had an hour and perfect recall of everything you've ever loved.

Milestones toward that:

1. **v1 — Personal tool (now):** iOS + Apple Music, TestFlight for founder + friends. Prompt → queue → refine → play → optionally save. Full enrichment pipeline. Daily-usable.
2. **v2 — The DJ learns:** skips/repeats/time-of-day feed back automatically; anticipatory sessions ("your usual Friday wind-down?"); richer arcs (warm-up → peak → cool-down).
3. **v3 — Web + reach:** web companion (MusicKit JS — no play counts on web, shares the same backend), App Store release, Sign in with Apple polish, licensed lyrics deal when revenue justifies.
4. **v4 — Social: the taste graph meets other people** (added 2026-08-30):
   - **Blend sessions/playlists**: one tape mixed from multiple people's histories and preferences — "DJ for the room", but grounded in everyone's real taste graphs, not a lowest-common-denominator shuffle.
   - **Taste twins**: find the users whose music taste is most similar to yours, and take actions from there (blend with them, borrow their discoveries, compare libraries). The enrichment corpus makes this computable: a user's taste vector is their play-count-weighted track/meaning embeddings, and similarity is a nearest-neighbor query over user vectors.
   - Requires a real multi-user base first (v3's App Store reach), plus a privacy model (taste sharing is opt-in; libraries are never exposed raw).
5. **Someday:** Spotify support if/when their API posture allows a new app (currently requires a 250k-MAU business for meaningful access), multi-platform households.

## Deeper history (added 2026-08-30)

Two upgrades to the taste graph's raw material, both feeding every milestone above:

- **Playlists as taste signal**: the user's *existing* playlists (their own hand-built curation — the strongest explicit taste statement they've ever made) ingested alongside the library, used both as seeds ("make me something like my 'Late Nights' playlist") and as taste-graph weight. v1 syncs songs + play counts but not playlist memberships — this is a known gap.
- **A per-day listening ledger**: "which songs did I listen to on which day," not just lifetime play counts. Apple never exposes per-day history directly — but it's derivable: sync regularly, snapshot per-song play counts, and the diff between snapshots IS the listens for that window. Compounding asset (the sooner sampling starts, the richer the history); enables recency-aware taste, "on this day" sessions, and real listening-diary features.
- **Catalog discovery**: recommendations beyond the user's own library (by genre/BPM/meaning-similarity over the enriched corpus + Apple Music catalog/recommendation APIs). v1's pool is deliberately library-bound; the familiarity dial's "adventurous" end eventually wants tracks the user doesn't own yet.

## Platform reality (why Apple Music first)

Researched 2026-08: Spotify removed Audio Features, Recommendations, and Audio Analysis for all new apps (Nov 2024) and gates extended API access behind a registered business with 250k+ MAU (May 2025). Dev mode caps at ~25 allowlisted users. Apple Music, via MusicKit, offers library + playlist read/write, real per-song play counts (native iOS only), recommendations, recently played, and full in-app playback for subscribers — everything v1 needs, with no approval gauntlet. Full comparison lives in the design spec.
