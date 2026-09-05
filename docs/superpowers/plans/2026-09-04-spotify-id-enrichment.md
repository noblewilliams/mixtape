# Spotify ID enrichment — Phase 3 first slice

Status: implemented, verified, and deployed in Worker version `7a6ec181-2292-4d56-b8a4-abb996d6857a`; provider-specific observation remains

Implements the Spotify-specific enrichment portion of the approved
[listening-export design](../specs/2026-09-01-listening-export-import-design.md).
An imported compilation track can carry the album artist instead of the song's
credited artists. Resolve its exact Spotify ID before searching by text, persist
credited artists and missing recording metadata, and use that artist in the same
pass's meaning lookup.

## Ownership

This slice owns `server/src/enrich/reccobeats-by-id.ts`, `pipeline.ts`, `runner.ts`,
their tests, and the small enrichment dependency wiring in `server/src/index.ts`.
It has no client UI or schema change. The concurrent playlist catalog task owns
the catalog client, artwork normalization, scheduler, schema/migrations, and
shared backlog/decisions edits. Keep its current contracts intact. Record this
slice's implementation details here and in the listening-export spec.

Apple ISRC cross-linking, source-safe membership, and fallback artwork are also
committed in `bba5de9`. Production migrations now reach `0024`; real-export
checks, provider smoke, and backfills remain outside this implementation slice.

## Contract

- Track and audio-feature lookups accept Spotify IDs in batches of at most 40.
  Match only exact requested Spotify URLs; never infer identity from ordering,
  names, or the provider's internal UUID. Ignore unrelated results and reject
  ambiguous duplicates and malformed success envelopes.
- Metadata and features have separate adapters, allowing credited artists and
  missing ISRC/duration to persist even when the features request fails.
- Correct export/sync artist credits with nonempty credited artists. Preserve
  catalog-corrected artists and metadata written concurrently. Fill missing
  ISRC/duration without changing either platform ID or library membership.
- A missing ID result can fall back to the existing title/artist feature search;
  an upstream error cannot. Errors use fixed categories, never response bodies,
  request URLs, or music metadata.
- The runner shares lazy lookup results within one batch only. Already-cached
  or exhausted feature stages make no ID requests, as before. No global cache,
  new cron, or scheduler contract is needed.
- Correction runs with the feature stage. Existing completed/exhausted tracks
  are not automatically reset or reprocessed; any historic backfill needs its
  own reviewed operation. Existing imports protect corrected artist provenance.

## Tasks

1. [x] ID adapters: red/green tests for exact identity, batches, partial results,
   feature values, malformed responses, and fixed-category errors.
2. [x] Pipeline: red/green tests for correction, same-pass meaning lookup,
   metadata protection, fallback, failure behavior, and repeat imports.
3. [x] Runner and runtime wiring: bounded batch lookups, cached-stage behavior,
   retry limits, and unchanged Apple enrichment.
4. [x] Adversarial self-review and fix round; focused tests, full serial server
   suite, typecheck, and diff hygiene. Record evidence and remaining gates.

## Evidence

- Public ReccoBeats example probe, 2026-09-04: `/v1/track?ids=...` and
  `/v1/audio-features?ids=...` both return `{ content: [...] }` with an exact
  Spotify `href`. Only field names/types/counts were printed; no user data was
  read. Existing metadata adapter already caps batches at 40.
- Primary references: [audio features](https://reccobeats.com/docs/apis/get-audio-features),
  [rate limits](https://reccobeats.com/docs/documentation/rate-limiting), and
  [Workers practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/).

## Review and fix round

- Exact-ID success, malformed envelopes, duplicates, empty feature records,
  and invalid duration handling were first reproduced in failing tests. The
  adapter now validates the Spotify origin/path, rejects duplicate identities,
  normalizes ISRC, and retains unknown feature values as null. A duration that
  rounds to zero or overflows the database integer is discarded.
- Pipeline integration proves that a staged re-import preserves the new artist
  credit and leaves listener history/membership unchanged. Concurrent catalog
  corrections win in the database update; a feature outage retains metadata and
  does not silently fall back to another lookup.
- Runner regression initially issued one request per track; it now shares a
  single lazy batch per endpoint/invocation, including errors. Tests cover the
  next invocation retry, cached/exhausted stages, and Apple text lookup parity.
- Runtime dependency wiring supplies the same adapters to the existing admin
  route and scheduled path. A route integration test uses the real adapters
  with synthetic provider responses and verifies admin auth and counts-only
  output. No scheduler API changed.
- Final validation: `npx vitest run --no-file-parallelism` passed 61 files /
  1,150 tests in 243.97 seconds in the shared checkout. `npm run typecheck`
  passed, and scoped `git diff --check` was clean. This slice adds 37 tests
  across ID adapters, pipeline, runner, and the admin route. The full-suite
  total also includes concurrent playlist work and is a snapshot of that run.
- During implementation, no production data was read or changed and no
  migration, deployment, staging, or push was performed. The slice was later
  committed and pushed with the combined candidate, then deployed through a
  separately approved release action.
