# Native mobile parity with web

**Date:** 2026-09-08
**Status:** all scoped native UI approved and implemented locally; 712 tests, analysis and unsigned iOS simulator build pass. Native Google public configuration and real-provider/device acceptance remain open.
**Scope:** native iOS Flutter app. Android Chrome continues to use the web client; this does not promise native Android MusicKit support.
**Companions:** [web controls](2026-09-08-release-completion-design.md), [mobile board](../../mockups/2026-09-08-mobile-parity-states.html), [web approval](../../mockups/approved/2026-09-08-web-controls.md).

## Outcome and audited gaps

Give native listeners the same meaningful actions as web while preserving native playback, richer library signals, and private playlist editing. Functional parity means the same durable result; interaction parity means the approved gestures, inline names, compact menus and composer attachments behave consistently. Existing native Material 3 navigation, system themes and 48-point controls stay in place.

| Action | Native source at initial audit | Scoped change |
|---|---|---|
| Create/refine/play a mix, reorder/remove tracks, create playlist | Implemented | Regression coverage; preserve existing behavior |
| Browse/import sources and playlists | Implemented; Exportify under concurrent work | Integrate after its owner finishes; no duplicate importer |
| Rename mix | Home long-press dialog | Tap entire Home row to open; Rename action starts inline editing |
| Archive/restore | Home trailing icon and archived toggle | Left swipe, compact menu alternative, Undo and archived restoration |
| View/forget preferences | Memory list; delayed deletion after swipe Undo | Explicit Forget action -> confirmation modal; canonical reload after uncertain outcome |
| Playlist inspiration | Server supports it; native session model/API/UI omit it | Select/replace/detach, exclude source tracks, persistent composer label and conflict recovery |
| Personal playlist curation | Native model reads origin; no mutation UI/API | Explicit reversible confirmation with eligibility and canonical recovery |
| Google login | Only Apple native gateway exists | Native Google gateway, shared Better Auth account, visible cancel/error/retry states |
| Link/remove login methods | No native account screen | Explicit provider linking, list methods, prevent removing final method |
| Private playlist edit/review/revised copy | Native already implemented, web lacks it | Preserve; outside this parity implementation |
| Native play counts/last played | Native richer than browser | Preserve truthful capability difference |

Primary evidence: `client/lib/presentation/screens/{home_screen,chat_screen,memory_screen,playlist_detail_screen,sign_in_screen}.dart`, `client/lib/data/{dj/dj_api,playlists/playlist_api,auth/auth_repository}.dart`, `web/src/components/{SessionControls,MemoryControls,PlaylistAttachment,PlaylistTasteControls,AccountDialog}.tsx`.

## Home revision — founder feedback

Home is a root screen: no Back button. Keep the screen focused on the new-mix prompt and Active mixes/Archived mixes tabs, with a compact global actions entry for existing destinations. No standalone Playlist shortcut, no Open buttons, and no horizontal dividers between mix rows. Entire rows open mixes; Rename belongs to their action menus. Left swipe archives with Undo/Restore.

The empty new-mix input cycles complete example prompts every 4.5 seconds: a slow Sunday morning; high-energy workout; dinner with friends and soft vocals; music similar to favourite soul songs; a rainy drive home; instrumentals for focus. Pause while focused, once text is entered, while the app is inactive, and for reduced motion. Keep a stable accessibility label, never overwrite text or submit an example automatically, and cancel the timer on disposal. The input includes a compact submit affordance, enabled only for nonblank text. It remains reachable with the keyboard open and large text. A playlist chosen deliberately from browse detail may show its existing attachment in this composer; no attachment affordance appears on ordinary Home.

This revision supersedes the first board's name-tap-to-rename, explicit Open button, Home playlist shortcut and decorative row rules. It does not change the web implementation implicitly.

## 1. Session names and archive

Use a shared native row/name component. Tapping the entire Home row opens the mix. The separate actions control opens Rename and Archive/Restore; choosing Rename activates the inline editor. Do not show an Open button. Home mix rows have no divider lines. Inline editing selects the existing name, caps it at the server's 60 characters, rejects whitespace-only titles, saves on submit or intentional focus loss and cancels on Escape. A failed save retains the draft and exposes Retry; no optimistic success message. Prevent blur/submit double writes. Conversation actions expose Rename using the same editor. Queue changes and late DJ/session responses must not overwrite a newer manual name.

Left drag follows the existing native song-removal gesture, with vertical scrolling winning until horizontal intent is clear. A swipe cannot also open or rename the row. Archive changes only status; it does not delete transcript, queue or inspiration. Keep one serialized metadata write per mix. Undo restores status after successful archive, and Archived mixes remains the durable restoration path after the temporary Undo action disappears. Failed archive keeps/restores the visible active row. An in-flight operation must not navigate away from a different mix the listener has since opened.

Use an anchored native popup with content-width text actions and a dismissible barrier. Outside tap, Back and Escape dismiss it. Keep a screen-reader action and menu/button alternative to swiping. Restore never requires a gesture.

## 2. Memory controls

Replace the delayed swipe-delete/Undo UI with an explicit Forget button and modal: preference text, irreversible effect, Keep note, Forget note. Barrier tap/Back/Escape closes without issuing a delete. Once confirmed, closing the modal does not claim to cancel a request already sent. Disable duplicate confirmations while it resolves.

After DELETE, including a lost response, GET the canonical list. Absence confirms success. Presence means the note remains and can be retried. A failed read means the result is unknown: hide stale actionable notes and offer Reload notes; never offer restoration of a committed delete. Preserve 401 handling without logging note text or response bodies. Empty/loading/error states keep navigation available. Focus returns to a valid originating control or list heading.

## 3. Playlist inspiration

### Presentation

Home has no standalone Playlist action. The conversation composer exposes a compact Playlist text action. It opens an anchored floating picker; on short screens/with the keyboard it stays inside the safe area, scrolls internally, and never covers the active text field. Attached state is a short `Inspired by Night Bus Notes` text action plus an accessible detach action inside the composer. Tap the attachment to replace it or change Use different songs. No permanent full-width inspiration card.

Browse detail exposes Make a mix inspired by this. It opens the new-mix composer with that exact playlist selected; it does not create a session, send a prompt, confirm authorship, or alter any queue. Keep the existing Edit with the DJ action as a separate workflow.

Picker supports search, loading, empty, error/retry and cursor pagination. Exact internal IDs identify selections, with source and song count distinguishing duplicate names. Cancel and outside dismissal make no mutation. Large names truncate only in the compact attachment; the picker and accessibility label retain the full name.

### Contract and state ownership

- New mix: POST `/sessions` with optional `playlistSeed: {playlistId, excludeSourceTracks}`. Omit it when no attachment is selected. Existing create error recovery (persisted session with failed initial curation) must retain server identity and subsequently read canonical seed state.
- Existing mix: PUT `/sessions/:id/playlist-seed` with `{playlistId: string|null, excludeSourceTracks, expectedRevision}`. Adopt the returned canonical seed.
- GET session exposes optional `playlistSeed`. Missing legacy field is **unknown capability/state**, not a confirmed empty selection; do not synthesize revision zero. A reload affordance remains available.
- Model the actual statuses: none, ready, unavailable, insufficient_profile. Missing/deleted sources and fewer than three matched recordings show truthful text and allow replacement/detachment when revision is known.
- 409 refreshes only canonical inspiration state; do not interpret it as a queue-operations conflict, replace transcript/queue, or retry a mutation automatically. User retries against the refreshed revision.
- Serialize seed writes per session. Block send while a seed write is pending and block seed mutation during a DJ turn. Preserve unsent text. Late reads cannot replace a newer selection.
- Providers watch auth state and discard late completions on account change/disposal. Data/request ownership must prevent an old account's completion from clearing the new account or changing its state.

## 4. Personal curation

Keep Your taste separate from inspiration and private draft editing. No selection, import, sync or playlist edit automatically confirms authorship.

PUT `/playlists/:id/taste-confirmation` with `{confirmed: true|false}`. Confirmation needs a modal explaining that the listener personally chose the songs. Unknown origin is eligible only when the server's other capability fields are known, active and non-automatic. Mixtape-owned, editorial, replay and personal-mix playlists stay neutral/unavailable. A previously confirmed playlist can remove confirmation even if its current capabilities no longer allow confirmation.

After every attempted mutation, reload the canonical playlist. An uncertain response never changes the badge optimistically. Block another write until an unsuccessful canonical read has been retried successfully. Adopt summary changes without dropping loaded entries/order/pagination. Confirmation removal changes only taste evidence, not playlist membership or source content.

## 5. Native Google and account management

Apple and Google are equal Mixtape login methods; Apple Music permission remains separate. Reuse the server's existing direct ID-token auth contract. Native Google must acquire a provider-verified token through the supported native SDK, then exchange it with Better Auth. Never embed a client secret, put a Mixtape bearer token in a deep link, disable audience checking, or infer account identity from matching email.

A native Account screen lists linked login methods. Linking requires a current Mixtape session and explicit authentication with the additional provider. Use the existing authenticated link endpoint; do not call sign-in as a substitute for linking or replace the current token with an unintended account. A provider already attached elsewhere produces an honest failure without merging accounts. Unlink remains subject to the server's final-method guard; refresh canonical methods after uncertain results. Only retain the provider identifier for the last-used hint, not tokens/profile data.

Cancellation is quiet and returns to the initiating screen. Busy states prevent parallel sign-in/link/unlink requests. Auth expiry clears protected routes as well as provider state before exposing sign-in. This route-reset work is required: Home currently owns the only sign-out action, and adding Account on a pushed route would otherwise violate that invariant.

**Configuration gate:** native Google iOS client registration and callback scheme are absent from the repo. Confirm exact bundle ID and obtain the matching public iOS client ID/reversed scheme; configure `serverClientId` to the existing server-accepted Google audience. SDK/package and token-linking support must be checked against current official contracts before implementation. The installed Better Auth contract uses `accountId` as the Better Auth account-row ID for unlink (not the provider account identifier). References: [Flutter Google iOS setup](https://pub.dev/packages/google_sign_in_ios), [Google native integration](https://developers.google.com/identity/sign-in/ios/start-integrating). Local gateway mocks can be tested without credentials; real Google login/link acceptance cannot be claimed until configuration and provider testing succeed. Do not fabricate IDs or change production OAuth configuration as part of code work.

## 6. Boundaries and delivery

No new database migration is expected for mix/preferences/inspiration/taste. Auth delivery may require native dependency/configuration changes, but should use existing server endpoints. Preserve the uncommitted Exportify/native playlist-edit work and founder instruction files. No production deployment, account linking, library read/write or release upload follows from this spec alone.

The mobile state board adds platform-specific layout/focus and the new Account screen; prior web approval supplies behavior, not automatic approval for every new native surface. Keep unrelated shell redesign, native Android playback, web playlist editing, account deletion and new personalization features out of this work.

## Execution slices and acceptance

1. **Contracts (non-UI):** strict seed models/API and taste mutation; red-first tests for exact IDs/payloads, legacy absence, stale and ineligible responses, malformed payloads and auth failures.
2. **Session controls:** shared inline editor/swipe/menu; tests for vertical scrolling, swipe click suppression, cancel/blank/failure, archive/restore preserving data and stale title races.
3. **Memory:** modal plus canonical reconciliation; tests for outside dismissal, duplicate confirmation, lost delete response, read failure, auth transitions and focus behavior. Supersede old deferred-delete expectations explicitly.
4. **Inspiration and taste:** auth-scoped state, paged picker, Home/Chat/browse integration; tests for no creation on select, duplicate-name exact IDs, exclusion/detach, 409 without queue mutation, stale completion, unavailable source, keyboard/safe-area and confirmation eligibility/reversal.
5. **Auth:** verified SDK bridge and repository/provider contract, account route lifecycle and UI; test Apple/Google cancel/failure, missing token, linking conflict, final-method rejection, uncertain refresh and account switches. External OAuth configuration/provider smoke remains a separately named gate.
6. **Review and verification:** reviewer pass and fix round per slice, focused checks then full Flutter tests/analyze, build where toolchain allows, visual checks at 320/390/430/768 widths, light/dark, short keyboard-open screens, 200% text and reduced motion. Test physical iPhone playback/import/editor after combined changes; mock success never closes provider/device gates.

Record actual commands and results in the execution plan. Completion is per slice: do not describe all mobile parity as complete while auth configuration, combined checks or real-device acceptance remains open.
