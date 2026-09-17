# Mobile parity execution

Contract: [native parity spec](../specs/2026-09-08-mobile-parity-design.md).

| Slice | State | Evidence/gate |
|---|---|---|
| Source audit and scoped design | Complete | Native and web screens, APIs, auth, platform capabilities inspected |
| Seed/taste data contract | Complete | 10 red-first tests passed; focused analysis clean; independent review + canonical fixture fix round complete |
| Native state board | Approved | 32 states; 224 layout checks, no overflow/sub-48px buttons/script errors; exact Flutter-generated theme colors; picker/modal/account screenshots inspected |
| Home and session inline rename/archive | Implemented locally | Founder approved revision 2; 28 Home tests, 8 widget tests and 51 session-provider tests pass |
| Memory modal/recovery | Implemented and reviewed | Explicit modal replaces delayed swipe deletion; cancellation, unknown/retry, auth and focus checks pass |
| Inspiration state provider | Complete | 8 tests passed; focused analysis clean; 401 masking fixed in review, auth/disposal and stale-read regressions pass |
| Inspiration and curation UI | Implemented and reviewed | Floating picker, composer attachment, browse-to-Home draft handoff, taste confirmation/removal and canonical recovery |
| Account API | Complete | 8 red-first tests passed; focused analysis clean; direct token linking/unlink row identity reviewed against installed Better Auth |
| Google/account UI and SDK | Implemented and reviewed; public configuration pending | Native Google OAuth registration/configuration absent; see native-google-setup.md |
| Combined native checks and build | Passed locally | 712 Flutter tests, clean analysis, unsigned iOS simulator build; real provider/device acceptance remains separate |
| Provider/device/release acceptance | Not run | No production/account/library actions authorized here |

## Contract checkpoint (before UI approval)

At this checkpoint the new data files were not wired into product screens. API tests use synthetic HTTP responses; they do not establish a real provider login or production mutation. No dependency, signing, production, native platform configuration, importer or existing playlist-editor changes belong to this slice.

Commands: `flutter test --no-pub test/data/playlists/playlist_context_api_test.dart`, `flutter test --no-pub test/data/account_api_test.dart`; focused Dart/Flutter analysis on their source and test files. Browser board QA used local Chromium with no provider requests. At this checkpoint Home revision 2 was approved; other surfaces were awaiting approval.

Final focused checkpoint: **26 tests passed** (10 playlist API/model + 8 account API + 8 inspiration provider). Each source/test slice has clean focused analysis. The 18 API tests also passed together. Review round fixed a 401 being masked by a failed reconciliation read; expired authentication now stays explicit, clears the seed and blocks further writes. A pending read after disposal is ignored.

## Home revision 2 — founder feedback

Removed the Home Back button, standalone Playlist shortcut, explicit Open buttons and mix row dividers. Entire rows open mixes; Rename is in the actions menu. Added functional prototype left-swipe archive/Undo and dynamic prompt placeholders (pause on focus/input/inactivity/reduced motion). Spec, board and native Home now implement these interactions.

Revision checks: 224 layouts pass, plus browser assertions for absent Home Back/Playlist/Open/dividers, rotating placeholders preserving user text, menu Rename, row navigation and swipe archive/Undo. Light Home screenshot visually inspected. Founder approved revised Home; see [approval](../../mockups/approved/2026-09-08-mobile-home.md).


## Approved Home implementation checkpoint

Home now uses exclusive Active/Archived lists, whole-row navigation, compact actions, inline Rename with draft-preserving retry, and left-swipe Archive with Undo/Restore. The composer rotates examples without changing typed text and supports keyboard submission. Existing memory, music, sync, setup and sign-out destinations remain reachable through the root actions menu. Home has no back navigation.

Review fixed archive/Undo losing its context when the last active row disappears, slow reconciliation delaying successful metadata writes, and sign-out deactivating the menu anchor during dismissal. Canonical PATCH results are adopted immediately; stale reads cannot overwrite newer metadata. Tests preserve setup/import handoff and pull-to-refresh coverage.

Validation: `flutter test --no-pub --reporter expanded` passed **616 tests**; `flutter analyze --no-pub` passed. Actual Flutter widget renders were inspected in light/dark; the 320 × 568 layout with 200% text and a 260px keyboard passes without overflow or losing the multiline draft. Captures use synthetic sessions, not device/provider data. No signed build, deployment or physical-device smoke was performed. Conversation rename, memory confirmation, inspiration/curation and account UI remain separate unfinished slices.


## Remaining parity continuation — September 8

The founder requested continuation. The remaining board approval is pending; substantial new product UI has not been changed. Independent logic work now includes canonical memory and account reconciliation, playlist taste state and optional new-mix seed propagation, the official Google native SDK gateway, and auth navigation reset. Existing memory error rendering now hides stale notes after failed canonical reads instead of claiming they remain current; deferred swipe confirmation is still awaiting its modal replacement.

Google is unavailable by default until exact public iOS/server client IDs and the native callback scheme are supplied. Follow [native Google setup](../../testing/native-google-setup.md); local SDK mocks cannot close that gate. Account linking obtains a provider token without replacing the current Mixtape session. Sign-out invalidates late work and removes pushed protected routes/dialogs.

Remaining integration must preserve composer text when send is blocked by an inspiration write, expose inline conversation naming, implement memory confirmation and the floating playlist picker, wire taste/account/sign-in controls, and verify their approved visual states. Native build/provider/device acceptance remains separate.

The shared per-mix operation gate now serializes DJ sends against inspiration writes. Chat detail reads adopt seed state only when the captured generation/operation and revision remain current. Review also fixed an old account's failed-turn recovery overwriting a new account's chat, and auth rebuild leaving sign-in permanently busy. Regression tests cover both races. Last-used login hints persist only the provider name, not identity/profile data.


Final continuation checkpoint: `flutter test --no-pub --reporter expanded` passed **665 tests**; `flutter analyze --no-pub` reported **No issues found**; `git diff --check` passed. These are local shared-checkout results, not a frozen release candidate. New modal/picker/account/sign-in UI remains pending board approval; no native build, production/provider action or deployment occurred.


## Approved native integration — final checkpoint

The founder approved all remaining revision 2 screens; [approval record](../../mockups/approved/2026-09-08-mobile-parity.md). All scoped UI is now implemented locally. The earlier pending-approval checkpoints above are historical.

- Conversation actions reuse Home's inline name editor, with retry/draft retention, archive/restore/Undo, and protection against stale generated titles and recovery reads.
- Explicit memory Forget confirmation has dismissible compact actions, canonical result/reload handling, safe focus return and no deferred swipe deletion.
- Inspiration lives inside the outlined composer. The paged, searchable picker uses exact IDs, cancellation without writes, source exclusion, and live positioning when the keyboard opens. Send/seed changes cannot overlap. Choosing from playlist detail returns to the existing Home, preserving its draft; no mix is created before submission.
- Playlist personal-curation confirmation/removal preserves the entries and private-edit workflow; unknown or ineligible states remain truthful and safe to reload.
- Apple/Google sign-in and Account methods expose last-used hints, cancellation, final-method guards, safe errors and auth expiry. Google remains unavailable until its public native configuration is supplied.

Independent review/fix rounds covered metadata writes against initial reads and DJ turns, stale auth/recovery completions, unknown taste capability, duplicate confirmations, and picker geometry. Actual Flutter light/dark captures of Home attachment, Chat, memory modal, picker, playlist taste, Sign-in and Account were visually inspected. Narrow 320px, 200% text and keyboard-open cases are tested; synthetic renders are not physical-device evidence.

Validation:

- `flutter test --no-pub --reporter expanded`: **712 passed**.
- `flutter analyze --no-pub`: **No issues found**.
- `git diff --check`: passed.
- `flutter build ios --simulator --no-codesign --no-pub`: passed; output `client/build/ios/iphonesimulator/Runner.app`. CocoaPods lockfile and generated resource phase now include Google SDK dependencies. The command used the installed Ruby 3.3.5 CocoaPods path ahead of the incompatible system Ruby launcher; no global reinstall was needed.

Remaining: exact Google iOS/server client IDs and callback scheme, real Google/Apple account acceptance, physical iPhone playback/import/editor smoke, combined release-candidate freeze and authorized distribution/deployment. No production/account/library actions or signed release upload occurred in this implementation.


## Native Google configuration — September 9

The supplied public iOS OAuth client and reversed callback scheme are now wired.
Build with `--dart-define-from-file=config/google-ios.json` from `client/`; the
server audience uses the existing public web client ID from local backend config.
The configured unsigned simulator build passed; generated build settings and the
built app callback scheme were verified. All five Google gateway tests passed.
Real provider acceptance against the intended backend, physical-device smoke,
and release delivery remain open. See the updated native Google setup guide.
