# Spotify fallback artwork — Phase 3 final slice

Status: implemented, verified, and deployed in Worker version `7a6ec181-2292-4d56-b8a4-abb996d6857a`; Spotify/Deezer-specific smoke remains.

The user authorized the remaining Phase 3 implementation while the real Spotify
and Apple exports are still pending. A Spotify track that does not acquire an
Apple catalog ID can receive a fixed public thumbnail without changing identity,
membership, taste, plays, playlists, or a listener's mix.

## Contract

- Prefer the official Spotify oEmbed endpoint using the exact validated Spotify
  track ID. Accept only a complete oEmbed envelope and an HTTPS `i.scdn.co/image/`
  thumbnail with no credentials, port, query, or fragment. Store its fixed URL;
  the existing clients already leave URLs without Apple size tokens unchanged.
- Only after a valid oEmbed miss, and only when the track has a valid ISRC, try
  Deezer's metadata endpoint by exact ISRC. Require the returned ISRC to match
  before accepting a strict `e-cdns-images.dzcdn.net` cover URL. Deezer artwork
  is display metadata only and never creates or changes a track identity.
- Provider reads have a five-second timeout and a 256 KiB response ceiling.
  Errors retain only provider, fixed category, and HTTP status. Never log or
  persist response bodies, request URLs, titles, artist names, or listener data.
- Claim at most three highest-priority tracks per pass. Require a current
  user-track row and a completed Spotify export source; exclude existing Apple
  IDs and known artwork. The existing artwork status row supplies a five-minute
  fenced claim and bounded retry. Provider calls run outside transactions, then
  completion rechecks source, Spotify ID, ISRC, Apple ID, artwork, and claim
  generation before writing.
- A successful Apple ISRC link clears any older fallback retry row so Apple
  artwork never inherits Spotify/Deezer backoff. The jobs remain failure-isolated
  and run metadata -> Apple ISRC -> Spotify/Deezer fallback -> Apple artwork.
- No schema change or migration was needed. The implementation made no
  production/provider request or private-library read; release work is specified
  in `../specs/2026-09-05-listening-export-release-validation-design.md`.

## Tasks

1. [x] Add strict, bounded Spotify oEmbed and Deezer exact-ISRC adapters with
   fixed-category failures and URL allowlists.
2. [x] Add a source-aware, priority-bounded runner with claim fencing, retry,
   race rechecks, listener-state protection, and provider-specific counts.
3. [x] Wire the maintenance order and isolate failure from Apple artwork.
4. [x] Complete the combined serial server check after the other active server
   task freezes its files; record final counts and review evidence below.

## Provider boundary

Spotify documents oEmbed as a public GET endpoint and documents nullable
thumbnail fields. Deezer's exact-ISRC route is not in a stable public reference;
official community material also says current API access requires a token while
new access requests are closed. The adapter is therefore a guarded best-effort
fallback behind Spotify, not an identity dependency. Release requires a
non-private runtime smoke. An authorization response backs off without affecting
oEmbed hits or the rest of maintenance.

## Sources

- [Spotify oEmbed tutorial](https://developer.spotify.com/documentation/embeds/tutorials/using-the-oembed-api)
- [Spotify oEmbed reference](https://developer.spotify.com/documentation/embeds/reference/oembed)
- [Deezer staff on current API access](https://en.deezercommunity.com/other-devices-49/deezer-api-current-track-82480)
- [Deezer community record of the exact-ISRC route](https://en.deezercommunity.com/features-feedback-44/api-search-for-all-tracks-by-isrc-74109)

## Review and verification

- New behavior was test-first. Provider tests pin exact request construction,
  fixed URLs, missing thumbnails, 404/no-data, ISRC mismatch, hostile hosts,
  rate limits, authorization, timeout, oversized/malformed responses, and fixed
  error messages.
- Runner tests pin oEmbed preference, Deezer-after-miss only, no-ISRC behavior,
  per-track failure isolation, due retries, the three-track priority cap,
  overlapping claims, expired work, current-source/identity/Apple/artwork
  rechecks, orphan exclusion, unchanged listener rows, and retry cleanup.
- Scheduler integration proves a Spotify track can miss Apple and receive oEmbed
  artwork in the same maintenance pass. Fallback failure does not stop Apple
  artwork or expose provider details.
- Focused validation passed 7 files / 101 tests, then the final owned regression
  set passed 4 files / 49 tests after the timeout hardening. The authoritative
  frozen combined server suite passed **73 files / 1,259 tests in 192.63s**. It
  includes this slice, playlist-inspired sessions, web browse/server work, and
  the 0014-to-current migration rehearsal. Server typecheck and diff hygiene pass.

## Release gate

Against live Worker version `7a6ec181-2292-4d56-b8a4-abb996d6857a`, run one
public-ID-only Spotify oEmbed request and, only after an oEmbed miss fixture, one
exact-ISRC Deezer request. Confirm response shape, access policy, latency, and
that no secret is needed or transmitted. Then observe aggregate fallback
categories and run the real-export smoke after the archives arrive. The
migrations and Worker are already deployed; the exports are not required for
the provider-specific smoke.
