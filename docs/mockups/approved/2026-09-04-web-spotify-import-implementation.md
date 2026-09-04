# Web Spotify import implementation departures

- **Recorded:** 2026-09-04
- **Board:** `docs/mockups/2026-09-04-web-spotify-import-states.html`
- **Supersedes:** only the clauses named below in `docs/mockups/approved/2026-09-04-web-spotify-import.md`. Everything else in that approval remains locked.

## Departures accepted during implementation

- **One sources row per connected source, named by its landed packages.** The board draws two Spotify rows, one per package. The server models one `spotify_export` source with one delete, so the view shows one row named "Spotify · extended history", "Spotify · account data", or "Spotify · both packages" from the source's `packages`, with Import again and Remove on that row.
- **Removal confirmation copy.** The board's "Your listening history stays" would be false: removing the Spotify source deletes the ledger, liked songs, artists, and playlists. Locked copy: "Remove your Spotify data? Deletes your listening history, liked songs, artists, and playlists from Mixtape. The DJ forgets nothing you told it in the interview, and the songs you pasted stay."
- **Interview steps 2, 3, and 5** carry titles and hints written in the board's register ("What do you play most these days?", "When do you listen, and to what?", "An era you keep returning to?"); the board draws only steps 1 and 4, which match it word for word.
- **Demo tile** is disabled with "Demo tape coming soon." until the web app has a demo-session mechanism; the board shows it live.
- **Both-packages state**, which the board does not draw: kicker "Spotify", heading "Data in", chip "Both in", nudge "Both packages imported <day>. Drop a newer ZIP any time to bring it up to date.", button "Drop a newer ZIP".
- **"Not personal yet" tile after the interview** reads "The DJ can offer a mix from what it already knows, clearly labeled."

## Implementation facts added

- The service choice is remembered per user per device in `localStorage` and cleared on sign-out; the gate never reappears for a listener who chose Apple and has not synced yet.
- A failed "I've requested it" shows a fixed alert and does not flip the page; the post is load-bearing for the waiting state.
- Day labels use the listener's local day; tests pin the runner's zone to UTC.
- Dark mode dialog error text is `#e9a3b3`.

## Import page

- **States the board does not draw.** `inspecting`, while the file is read on this device ("Reading on this device", the stage line, and "Choose a different file" so a read can always be abandoned), and `upload-failed`, when the server run stops before publishing ("Upload interrupted", "Nothing was published", "Try again" back to the inventory, "Choose a different file"). A third, `read-failed`, covers the parser itself failing to run on this device (the Worker script did not load or died): "Couldn’t read this file on this device. Try again." with "Try again" and "Choose a different file", and no diagnostics report, because none can be built.
- **Unreadable copy** says "couldn’t be read", in three variants: not a ZIP ("This file couldn’t be opened as a ZIP, so nothing was uploaded. Give Mixtape the ZIP Spotify emailed, unchanged."), a ZIP holding none of the Spotify export files ("This ZIP holds none of the Spotify export files, so nothing was uploaded."), and one broken file ("One of the history files couldn’t be read" or "One of the files couldn’t be read", "so nothing was uploaded."), each followed by the expected file names. The parser does not distinguish bad JSON from bad UTF-8, so neither does the copy.
- **Bare counts until parser stats land.** "Skipped rows" is the unresolved-row count alone (podcast, local-file, bad-timestamp, and private-session drops are not broken out) and the private-sessions note carries no count of private plays. Both fill in when the parser exposes `stats` (plan, "Inventory preview").
- **Diagnostics lines** carry each entry’s full path inside the archive, its size, and its row count, "unreadable", or "ignored", after a `source:` line and before the parser version (`parser web-spotify-export/1`).
- **"ignored" everywhere.** Files the parser never opens are labelled "ignored" in the inventory list and in the report; the board’s "never read" is not used.
- **Retry playlists** re-runs the whole import for the same file and options (idempotent server-side; the playlist sync runs again) rather than a playlists-only sync, under "Re-uploads the file; nothing is duplicated." The partial body reads "Your liked songs and artists are safe on the server. Nothing is lost; the playlists can follow with a retry." A retry records `import_completed` again and never a second `file_inspected`.
- **The run outlives the page.** The import run (its state, abort, and the parser’s Worker) belongs to the app for the signed-in user’s life: leaving for Home, a session, or a new tape never cancels an upload, coming back shows its progress, the browser asks before the tab closes mid-upload, and sign-out aborts and forgets it. Each import parses once: the inventory’s full default parse is what goes up unless the private-sessions switch was flipped.
