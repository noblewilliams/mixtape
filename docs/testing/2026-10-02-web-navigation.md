# Web navigation validation — 2026-10-02

Approved reference: `../mockups/approved/2026-10-02-web-navigation-cleanup.md`.

- Production build and TypeScript pass. Existing bundle-size warning remains.
- Full web suite passes; one existing skipped test.
- Browser: signed-in local app at localhost:4176, real imported Library content, Playlists/Sources navigation, Settings and Home/Mixes failure states checked. Light and dark selection verified. Responsive check at 390 × 844: no horizontal overflow; Home input computed 14px, composer 60px high and 20px from the viewport bottom.
- Populated Home inspected through the development-only `?ui-preview` route with clearly labelled synthetic mixes. Desktop uses two recent-mix columns; narrow width uses one scrollable column while composer remains visible.
- Voice tests cover editable transcription, retained drafts after errors, denied permission, cancellation, late permission/result handling and microphone cleanup. API test verifies multipart body, bearer auth, credentials, and AbortSignal without a JSON Content-Type override. No live microphone or remote transcription acceptance claimed.
- Regression tests preserve newly created mixes during pending collection reads, prevent stale preference edits during read/retry, and avoid presenting Retry during a listening-preference save.

Live session reads remain blocked by the pending `dj_sessions.case_color` schema migration. Workers remote AI was unavailable in the local backend configuration. Neither migration nor deployment was performed as part of this UI change.

## Follow-up — 2026-10-03

Resolved the Recent mixes 500: the configured Neon schema lacked `dj_sessions.case_color`. The ledger matched every existing migration hash and only `0033_tape_case_color` was pending. Both the isolated tape-color migration test and the full upgrade-chain test passed. Applied that existing migration and its ledger entry in one transaction with 5-second lock and 30-second statement timeouts; all five stored sessions received a colour. Read-only verification confirms the column exists, no pending migrations, and no hash mismatches. Retried Home through the signed-in browser: Recent mixes displays the account's mix and the local backend logs `GET /sessions 200 OK`. No application deployment was required.

### Session restoration follow-up

Refresh now shows a neutral session-check state until authentication resolves. The welcome page is shown only for a confirmed signed-out response; a failed session check offers Retry. Existing confirmed session data continues to render the app during background checks. Two regression tests cover pending-to-authenticated/signed-out transitions and failed-check retry. Verified a live reload displays “Checking your session…” without welcome copy or sign-in buttons before returning to Home.

### Retained-content refresh — supersedes the intermediate session-check screen

Founder chose to retain the last-loaded content. Per-tab workspace snapshots now restore the current page, selected mix/playlist, content, filters and drafts beneath a floating status badge. Live browser reloads verified a selected conversation and Library Sources remain visible during session verification. The badge continues while canonical reads finish. Restored content is inert until verification; tests confirm cached identity cannot authorize requests, gate closure prevents queued dispatch, user caches are isolated, and confirmed sign-out clears snapshots. Stale detail responses cannot overwrite intervening message or queue edits. Playback, recording, uploads and destructive confirmations are not resumed. The initial session-check screen remains only when no previous workspace exists to restore.
