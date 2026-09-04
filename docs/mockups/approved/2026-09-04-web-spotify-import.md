# Web Spotify import approval

- **Approved:** 2026-09-04
- **Board:** `docs/mockups/2026-09-04-web-spotify-import-states.html`
- **Winning direction:** B, a request page under Your music that becomes a living waiting card and then the import page and sources view.
- **Coexists with:** the pending `docs/mockups/2026-09-01-web-sync-playlist-states.html` board; the Spotify states are drawn as states of the same Your music view, not a second destination. This record supersedes nothing.

## Locked flow

- A one-time "Which do you use?" dialog after sign-in, shown only when the onboarding read reports no connected source and no library. Apple leads to the existing MusicKit connect flow; Spotify records `chose_spotify` and opens the request page. Copy: "Before your first tape / Which do you use? / Mixtape builds mixes from what you actually listen to. Tell it where that lives." with a footnote that the other can be added later from Your music.
- The request page shows the spec's eight steps word for word, with `spotify.com/account/privacy` as a link that opens in a new tab, the confirmation-email step set in bold, and an "I've requested it" primary control with the note that it marks today and that Spotify's two emails are the signal.
- After the checkpoint the same page becomes the waiting card: the elapsed wait in marker type, a status chip (Not requested / Waiting / 1 of 2 in), the confirmation-email nudge, three action tiles (interview, paste songs on desktop, demo tape), and the drop zone. The interview tile becomes "Interview done" with counts once complete. When one package is in, "Make a mix" appears beside "Drop the other ZIP".
- The interview is a five-step dialog, one question per step, stepper visible, Back/Next, artists as chips (up to 20, at least one required), free-text answers up to 300 characters with a counter. Completion refreshes the waiting card.
- The paste box (desktop only) takes one Spotify link per line, adds the resolved songs, lists unrecognised lines without affecting the rest, and shows seeds as removable chips.
- The import page: inventory before upload (file name and size, package, tracks, days with plays, years, the time zone used for local days, skipped-row counts, files read and files ignored with the word "ignored" or "never read", the private-sessions switch off by default, and the privacy line "Only these plays leave this device"); uploading with a live status chip, a decorative progress band, and Cancel; unreadable file with the expected file names and a content-free diagnostics report with Copy report; summary with counts, ledger range, the enrichment note, "Make your first mix" and "Import the account data too"; partial success (history published, playlists failed) as its own state with Retry playlists and Make a mix anyway.
- The sources view lists connected sources with import dates and ledger ranges, offers Import again and Remove, and confirms removal with copy that names what is deleted and what stays.
- The mix rail for a Spotify listener shows no Apple play or save control when no track has an Apple id; each track has an "Open in Spotify" link; the rail actions are "Copy for Spotify" (desktop) and "Send to a transfer tool", with a one-line hint. A corpus-mode mix carries the "Not personal yet" banner above the tracks with the line "Built from Mixtape's catalog and your interview, not your listening. Import your Spotify data for the real thing."

## Locked appearance

- Approved content-plane glass shell, tokens, and marker headings; cards are translucent white on the plane with hairline borders; attention states use the orange hairline, success the green chip, errors the pink chip.
- Status chips are monospace uppercase pills: neutral, `ok` green, `wait` amber, `err` pink, each with a text label and a dot; never colour alone.
- Primary control is the plum raised button; secondary is the translucent bordered button; destructive is the pink-bordered quiet button.
- The inventory uses a two-column definition list plus a monospace file list; ignored files are struck through and labelled.
- The dialog surface is the neutral warm gray used by account dialogs; it does not borrow mix paint.

## Locked behaviour and accessibility

- The status chip is the live region: "Uploading, 62 percent, days 3 of 4", "Import complete, 4,812 tracks", "Couldn't read this export". The progress band is `aria-hidden`.
- Every "Open in Spotify" link has a 44px target and an accessible name naming the track.
- The private-sessions control is a real switch with an accessible name and its default state announced.
- Reduced motion removes stripe travel and card transitions; the chip text carries the whole state.
- Large text grows content while chrome, targets, and layout hold; long artist names wrap inside tiles.
- Mobile web keeps the same hierarchy without side panes; the request page keeps all eight steps; the rail omits "Copy for Spotify" because Spotify's mobile app cannot paste links into a playlist; dark mode follows the approved deep-graphite canvas.

## Rejected direction

- A, a one-time checklist dialog: smaller build, but the instructions vanish when dismissed, the listener has nowhere to see how long they have waited, the drop zone would need its own home, and it competes with the pending Your music board for space.

## Intentionally unresolved

- Exact placement of the request page relative to the Apple states in the pending Your music board.
- Which transfer tool the handoff names; decided at build time by whichever accepts pasted text without an account.
- Whether the demo tape opens in place or as a new session.

## Implementation boundary

- Expected web owners: `web/src/App.tsx`, `web/src/components/Sidebar.tsx`, new components under `web/src/components/` for the service dialog, request and waiting page, interview, paste box, import page, sources view, and the rail additions in `web/src/components/QueuePanel.tsx`, plus `web/src/styles.css`.
- The import page drives `web/src/import/worker-client.ts` and `web/src/import/import-service.ts`; the page owns the one-playlist-run-at-a-time gate.
- Funnel events `chose_spotify`, `marked_requested`, `first_personal_mix`, `first_output` are posted by the page; `file_inspected` and `import_completed` by the import service; `interview_completed` by the server.
- Pin the locked values in `web/src/styles.test.ts` and add component coverage for every state above.
