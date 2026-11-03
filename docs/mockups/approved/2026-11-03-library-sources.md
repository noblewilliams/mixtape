# Approved Library sources, sync alert and Add your music

Approved November 3, 2026: founder replied "Approve, build it" to
[library sources states](../2026-11-03-library-sources-states.html), from the
build 202611030734 smoke notes. Decisions: `../../decisions.md` → 2026-11-03
Library sources.

## Winning direction

Everything the board recommended, with its two open points taken as
recommended (the founder did not override them):

- **Library title buttons carry words.** A glass pill with "Sync" (two
  circling arrows) and "Your music" (library glyph). The More (…) menu and its
  one-row sheet are gone. Sync is hidden for a listener whose service is
  Spotify and who has no Apple Music library source.
- **Sources strip** above Playlists: one flush row of two halves, each one
  button: service mark, service name, status line. Apple Music shows the sync
  status ("Synced 2 Nov", "Syncing… 42%", "Sync didn't finish", "Not synced
  yet"); Spotify shows its existing status word or "+ Add music". Both open
  Add your music on their own segment. At 1.3× text and above the halves stack
  into full-width rows with a chevron.
- **Sync is a centred alert** (Cupertino alert material), not a sheet. Re-sync
  copy when a library source exists ("Sync Apple Music again?" with the last
  date), first-sync copy otherwise. Running shows a bar and "Hide" (the sync
  keeps going); done gives the run's counts and "Done"; failed gives the
  message with Cancel / Try again; access denied offers Open Settings.
  Opening the alert after an earlier run always starts at the confirmation.
- **Add your music, Apple pane:** status row (mark, "Apple Music library",
  status, "Sync again" text action) → "Listening history" section with
  "Choose your Apple file" as a tape button in plain sight → "How to request
  it from Apple" flush disclosure holding the unchanged steps. History added
  replaces the button and steps with its status and "Replace file". Never
  synced: the sync tape button is the one primary action and the file drops
  to a chip.
- **Spotify pane:** the same grammar: status row, "Saved music" (Exportify
  quick start and its row, hidden once saved music is in, when the status row
  offers "Import again"), "Listening history" with the official steps folded
  under "How to request it from Spotify".

Rejected: brand-colour app icons (the 2026-09-18 single-tone mark rule
stands); a bottom sheet for sync (needs confirmation, reads as a menu); the
Apple Music note as the Sync glyph (users could not tell what it did);
keeping the inset "Go deeper" box (hid the file picker behind a disclosure).

## Locked behaviour

- Accessible names: "Sync Apple Music", "Your music"; strip halves read as
  "Apple Music, <status>" and "Spotify, <status>".
- Status never by colour alone: tick + words, warn words, spinner + percent.
- Step copy for both services unchanged.

## Supersedes

- Smoke round four, note 3 (Apple Music note on the Sync button).
- The Library tab's More menu and chip-row sources (2026-09-17 shell, L1).
- `LibrarySyncSheet` (now `LibrarySyncDialog`).

## Owners

`client/lib/presentation/screens/tabs/library_tab.dart`,
`client/lib/presentation/widgets/library_sync_dialog.dart`,
`client/lib/presentation/screens/spotify_request_screen.dart`,
`client/lib/presentation/widgets/foundation/glass_cluster.dart`.
