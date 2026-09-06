# iOS playlist edit review implementation plan

**Status:** implemented and locally verified; release pending

**Spec:** [conversational source-playlist editing](../specs/2026-09-05-conversational-source-playlist-editing-design.md)

**Approved board:** [iOS playlist editing with the DJ](../../mockups/approved/2026-09-06-ios-playlist-editing.md)

## Scope

This slice makes synced playlists browseable on the Flutter client and exposes
the already-implemented private draft and playlist-DJ contracts. It does not
add any Apple Music write path.

## Task 1 — typed draft client

Red first for defensive draft/message/diff parsing and a long-timeout API that
creates or resumes a draft, reopens its transcript, and sends a versioned turn.
Translate server conflict, validation, upstream, malformed, HTTP, and transport
responses into a small fixed client taxonomy without leaking response bodies.

## Task 2 — user-scoped state

Red first for playlist collection, detail, and draft conversation providers.
Every provider watches auth, owns/cancels its long-running client, adopts the
server's complete canonical draft after a turn, and refreshes on a draft
version conflict instead of overwriting it.

## Task 3 — playlist browse and detail

Red first for loading, empty, retry, pagination, source identity, artwork
fallback, duplicates, unresolved entries, and the **Edit with the DJ** entry
point. Integrate Playlists and Sources under the existing **Your music** route
without rebuilding the source/import workflow.

## Task 4 — conversation and review

Red first for untouched, sending, changed, turn error, stale refresh, and exact
diff review. Keep source and private draft visible, show occurrence-aware
neighbours, and render apply as unavailable while the server's capability says
`applyAvailable: false`. No provider mutation is callable in this slice.

## Task 5 — verification

Run focused data/provider/widget tests, client analysis, the full Flutter test
suite, an adversarial review, and a fix round. Update the spec/backlog with the
verified boundary and commit only owned files when explicitly requested.

## Verified boundary

- The Flutter client browses playlist collections and ordered detail, including
  artwork templates, `artwork_bg_color` fallback, duplicates, and unresolved
  occurrences.
- Starting **Edit with the DJ** creates or resumes the private draft. Turns use
  optimistic versions, reload the complete canonical transcript after a
  conflict, and never write to a provider.
- Review names exact additions, removals, moves, and replacements. Apply remains
  unavailable and the UI says the source is untouched.
- Spotify exports remain private/read-only; unknown origins are labelled as
  imported instead of being presented as Apple Music.
- Focused Flutter tests, the full Flutter suite, Flutter analysis, focused server
  tests, server type-checking, and the authoritative serial server suite passed.

## Release order

The client now requires the server's compact `review` projection. Deploy the
committed Worker revision before distributing this client build. That deploy is
a separate explicit production gate. There is no database migration in this
slice; migrations `0025` and `0026` were already applied with the draft
foundation.
