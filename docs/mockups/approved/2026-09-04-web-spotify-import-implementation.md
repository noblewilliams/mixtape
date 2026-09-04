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
