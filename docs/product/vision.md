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
- Not a social app — no feeds, no sharing pressure. Personal DJ, singular.
- Not a lyrics app — lyric *meaning* powers matching invisibly; we never display lyric text (see licensing stance in the design spec).
- Not a discovery firehose — familiarity is a dial the listener controls, not a growth metric.

## Endgame

The long-term bar: **mixtape knows your music taste better than you can articulate it.** You stop making playlists. Before a run, a dinner, a flight, a low evening — you say one sentence, and what plays is what you would have picked if you had an hour and perfect recall of everything you've ever loved.

Milestones toward that:

1. **v1 — Personal tool (now):** iOS + Apple Music, TestFlight for founder + friends. Prompt → queue → refine → play → optionally save. Full enrichment pipeline. Daily-usable.
2. **v2 — The DJ learns:** skips/repeats/time-of-day feed back automatically; anticipatory sessions ("your usual Friday wind-down?"); richer arcs (warm-up → peak → cool-down).
3. **v3 — Web + reach:** web companion (MusicKit JS — no play counts on web, shares the same backend), App Store release, Sign in with Apple polish, licensed lyrics deal when revenue justifies.
4. **Someday:** Spotify support if/when their API posture allows a new app (currently requires a 250k-MAU business for meaningful access), multi-platform households, shared sessions ("DJ for the room").

## Platform reality (why Apple Music first)

Researched 2026-08: Spotify removed Audio Features, Recommendations, and Audio Analysis for all new apps (Nov 2024) and gates extended API access behind a registered business with 250k+ MAU (May 2025). Dev mode caps at ~25 allowlisted users. Apple Music, via MusicKit, offers library + playlist read/write, real per-song play counts (native iOS only), recommendations, recently played, and full in-app playback for subscribers — everything v1 needs, with no approval gauntlet. Full comparison lives in the design spec.
