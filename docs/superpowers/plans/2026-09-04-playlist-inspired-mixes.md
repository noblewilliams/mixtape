# Playlist-inspired mixes implementation plan

Status: implemented and verified locally; release remains.

Spec: [playlist-inspired mixes](../specs/2026-09-04-playlist-inspired-mixes-design.md).

## Ownership and prerequisites

- This task: new playlist-seed module/tests, ordinary session routes and DJ
  loop/contracts/pool/queue-store integration.
- Web task: playlist browse store/routes/read contracts, web UI, API client and
  sync orchestration. Do not edit those files as part of this backend slice.
- Export task: membership and ISRC lookup migrations 0022–0023, schema/journal,
  catalog client, enrichment runner/scheduler/index. Schema ownership was handed
  over after 0023; this slice generated 0024 without modifying those paths.
- Shared backlog/decisions/handoff currently contain that task's changes. Use
  these dedicated documents until ownership is available for a scoped update.
- No deployment or production data access. Do not widen the pinned release
  candidate automatically to include this new feature.

## Task 1 — selection and authenticated session contract

Complete. Optional create-session seed, revision-checked select/clear, read
shape, and latest-published-profile semantics are implemented in a session-owned
selection row. Migration 0024 follows the coordinated 0022–0023 handover.

Red/green through session HTTP routes and the seed store: owned selection,
atomic creation, read-after-write, restart persistence, unchanged old callers,
foreign/malformed/missing IDs, unavailable source, replace, clear and conflicts.
Generate/inspect the migration and test upgrade plus account/source deletion.
Review for tenant leaks, accidental library/taste writes and stale selection.

## Task 2 — bounded profile and pre-limit ranking

Complete. Minimum coverage is 3 resolved recordings; deterministic profile
sampling is capped at 200 recordings and 5 per normalized artist. Seed weight is
0.15 and missing axes are neutral 0.5. Inside seed fit: meaning 0.45, tempo 0.20,
energy 0.15, artist 0.10, genre 0.05 and center-year 0.05.
Use existing enrichment fields; do not create another enrichment pipeline.

Red/green through the profile interface and `buildPool`: exact identity,
duplicates/ISRC siblings, uneven artist distributions, missing/invalid axes,
large playlist cap, candidate eligibility unchanged, deterministic ordering,
seed influence before the final LIMIT, ordinary scoring unchanged, prompt
filters win, and full-source exclusions beyond the profile sample.
Review query cost, parameterization, memory bounds and score weights.

## Task 3 — DJ selection and follow-up

Complete. Added bounded name lookup and selection/clear tools using Task 1's
interface; the loop reuses the store rather than duplicating ownership logic.

Red/green through `runDjTurn` with fake external LLM/embedder and real test DB:
name ambiguity asks, no unsolicited selection, follow-up retains inspiration,
source updates use a fresh published profile, generation/swap/extend share the
profile, unavailable source blocks new picks without discarding the queue,
and all playlist-derived context stays sanitized at user altitude in both
conversation and curation.
Review tool-call order and failed-turn/retry behavior.

## Task 4 — commit-time fencing and integration

Complete. Red/green controlled races cover selection/source revision fencing,
including a source fingerprint update while replacement curation is in flight.
The queue transaction rechecks the seed revision, selected playlist, activity,
fingerprint, and queue version before accepting generated picks.

Original target: selection change/clear during curation, sync during
profile loading, source deletion before queue commit, queue edit during a
seeded swap/extend, and conflict retry. Keep network work outside transactions;
seed protection must cover every path that adds generated picks.
Review adversarial cases and fix findings before expanding scope.

## Task 5 — verification and handoff

Complete locally. The authoritative combined-worktree server suite passes 70
files / 1,235 tests; focused playlist/session coverage, typecheck, Drizzle
consistency, and diff hygiene pass. Spec, plan, backlog, and decisions document
the API response, coverage, unavailable-source and shortfall states.
Commit/push/deploy and real-library/device checks require separate authorization.

Production code and migration 0024 are changed locally. Nothing has been
committed, pushed, migrated, deployed, read from production, or sent to a music
provider by this slice.
