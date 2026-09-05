# Approved — Your music integration

Approved by the founder on 2026-09-04 in this task: “approved”.

Board: [Your music, together](../2026-09-04-web-your-music-integration-states.html).

## Decision

One `Your music` destination with `Playlists` and `Sources`. First use opens Sources; a completed snapshot opens Playlists, including completed-empty. Preserve the selected section during the signed-in visit. The Sources-first-on-every-return alternative was not selected because it adds a step to repeat browsing.

## Locked behavior

- Apple and Spotify are additive account sources. Browser Apple authorization is separate from Mixtape sign-in and from previously synced account data.
- Preserve the existing Spotify workspace, parser, waiting/interview/import/removal states, and app-owned run lifetime. Add shared navigation; do not rebuild the importer.
- Apple sync survives navigation. Shared upload ownership prevents overlapping Apple/Spotify playlist publication. Sign-out cancels work and clears private state.
- Use real stage counts, with percentages only for known denominators. Songs and playlists publish separately. Partial results retain saved songs and previous playlists; a lost completion response is unconfirmed until reconciled.
- Browse with explicit source identity, full-collection search/filtering, pagination, original entry order, duplicates, and unresolved/local-track fallbacks. Distinguish loading, empty, no results, initial failure, and next-page failure.
- Preserve the existing slate/plum palette, marker headings, neutral glass shell, compact controls and house motion. No Android-specific layout or product identity.
- Approval covers the board's 33 states, 320/390/760/768/1020/1240px layouts, light/dark, large text, reduced motion, opaque surfaces, visible focus, and at least 44px action targets. Keep the approved desktop-only Spotify paste affordance desktop-only.

## Scope and implementation

Expected owners: web App and music views, existing Spotify view, MusicKit/sync services, API client/fixtures, shared styles; server playlist browse/query routes and tests. Source-membership/schema work is owned by the separate handoff task. Do not infer ownership from provider IDs or duplicate that implementation.

Unresolved implementation details: persistent source totals/freshness, completion reconciliation, and shared run ownership must be test-pinned. Optional fields from older servers remain unknown, not fabricated. Use the approved fallback wording when data cannot support precise counts/dates.

This approval supersedes the unapproved 2026-09-01 Apple board for these surfaces only. Existing Spotify and shared-content-plane approvals remain in force. Memories, mix rename/archive, playlist-origin confirmation, playlist seeds/editing, Apple export parsing, new Spotify playback, production account actions, commit/push, migrations and deployment are not approved by this decision.
