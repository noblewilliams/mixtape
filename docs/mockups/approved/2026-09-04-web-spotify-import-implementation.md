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
- **Skipped rows and private plays come from the parser’s `stats`** (plan, "Inventory preview"). For the extended package "Skipped rows" reads "212 podcasts · 9 local files" (proper singular and plural, zero parts omitted, "None" when both are zero; bad-timestamp drops are not shown, and private-session drops belong to the switch, not this row). The private-sessions note counts the plays the switch would add: "41 plays hidden from followers stay out unless you choose otherwise." ("1 play … stays out" for one), or "No private-session plays in this file." with the switch still rendered when there are none. The account package keeps the bare unresolved-row count, and the done state’s "Unresolved" row is unchanged.
- **Diagnostics lines** carry each entry’s full path inside the archive, its size, and its row count, "unreadable", or "ignored", after a `source:` line and before the parser version (`parser web-spotify-export/1`).
- **"ignored" everywhere.** Files the parser never opens are labelled "ignored" in the inventory list and in the report; the board’s "never read" is not used.
- **Retry playlists** re-runs the whole import for the same file and options (idempotent server-side; the playlist sync runs again) rather than a playlists-only sync, under "Re-uploads the file; nothing is duplicated." The partial body reads "Your liked songs and artists are safe on the server. Nothing is lost; the playlists can follow with a retry." A retry records `import_completed` again and never a second `file_inspected`.
- **The run outlives the page.** The import run (its state, abort, and the parser’s Worker) belongs to the app for the signed-in user’s life: leaving for Home, a session, or a new tape never cancels an upload, coming back shows its progress, the browser asks before the tab closes mid-upload, and sign-out aborts and forgets it. Each import parses once: the inventory’s full default parse is what goes up unless the private-sessions switch was flipped.

## Mix rail (B5)

- The transfer tool is TuneMyMusic (`https://www.tunemymusic.com/transfer`), the one that accepts pasted text without an account; the handoff copies one "Artist – Title" line per track and opens the tool in the same gesture.
- **Rail gating.** The Spotify actions ("Copy for Spotify", "Send to a transfer tool", and the hint) render whenever any track has a Spotify id; the Apple controls (Connect, Play now, Create playlist) render whenever any track has an Apple id. A Spotify-only mix shows only the Spotify block, in the Apple slot; an Apple-only mix is unchanged; a mixed mix shows both, Apple first, with a 12px gap between the blocks. A mix in which no track has either id shows no rail action.
- Desktop and mobile hint copy both live in the DOM and toggle at the 760px breakpoint; the row link label shortens to "Open" on mobile while its accessible name stays "Open in Spotify: <title>", so the visible text is always a prefix of the name.
- `first_output` fires after a successful clipboard write for Copy, when the tool opens for the handoff, and on click for a row link; `first_personal_mix` fires once per user when a session comes back with `notPersonal` false after a completed listening export: the onboarding read's `importCompletedAt`, or a `spotify_export`/`apple_export` source with `lastImportedAt`. An `apple_live` library sync never counts. Both once-flags are written only after the post lands, so an offline or failed post is tried again on the next occasion (the server tolerates duplicates).
- After a message turn the session record is refetched and only `notPersonal` is merged in, so the "Not personal yet" banner updates; the queue, its version, and the messages stay as the turn's own response left them. A failed refetch adds no DJ error bubble; a 401 signs out.
- The output toast auto-dismisses after four seconds so its hint can be read; the undo window stays three seconds.
