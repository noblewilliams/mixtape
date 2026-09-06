# Approved — iOS playlist editing with the DJ

- **Approved:** 2026-09-06
- **Board:** `docs/mockups/2026-09-05-ios-playlist-edit-states.html`
- **Minimum iOS:** 16

## Locked interaction

- Playlist detail remains useful without creating an edit draft.
- **Source** always means the last synced Apple Music playlist or Spotify
  export. **Private draft** always means Mixtape's proposed ordered version.
- Starting or resuming an edit never writes to Apple Music.
- The conversation shows the canonical draft version and a compact exact
  change summary. A stale turn refreshes instead of overwriting.
- Review shows additions between their proposed neighbours, removals, moves,
  replacements, unresolved blockers, and the real provider operation.
- A middle insertion, removal, replacement, or reorder says that Mixtape will
  create a revised Apple playlist and leave the source untouched.
- Only an independently verified trailing suffix may offer **Add songs to
  source**. Exact rebuild remains unavailable.
- Spotify exports never offer write-back to Spotify. Without Apple Music, the
  draft remains browseable and editable but provider apply is unavailable.
- Partial and unknown Apple outcomes reconcile before any retry.

## Visual and accessibility direction

- Keep Mixtape's slate/plum palette, artwork-led hierarchy, restrained neutral
  glass, compact controls, and marker-style titles.
- The screen follows the system light/dark appearance and supports reduced
  motion, reduced transparency, large text, narrow iPhone, large iPhone, and
  iPad portrait layouts.
- Source/draft meaning, apply mode, errors, and progress never depend on color
  or motion alone. Interactive controls retain at least 44-point targets.

## Implementation boundary

This approval covers native playlist browse/detail, draft conversation, exact
diff review, and truthful unavailable/recovery states. It does not authorize a
provider mutation by itself. Revised-copy creation, verified append, Worker
deployment, and source rebuild remain separate gates from the design spec.
