# Exportify import implementation checks — 2026-09-08

Implemented locally against the approved 17-state board and its compact-action,
no-left-rail corrections. No commit, production migration, or deploy was made.
All import fixtures and browser interactions used synthetic music data.

## Automated checks

| Check | Result |
| --- | --- |
| Server, `npx vitest run --no-file-parallelism` | 79 files, 1,317 tests passed |
| Server, `npm run typecheck` | Passed |
| Web, `npm test -- --run` | 44 files, 371 tests passed |
| Web, `npm run build` | Passed; existing bundle-size advisory remains |
| Flutter import/onboarding focused suite | 168 tests passed |
| Flutter, `flutter analyze --no-pub` | No issues found |
| Flutter full workspace suite | 596 passed; one failure in concurrent playlist-controls work |

The full native failure was
`test/presentation/providers/playlist_context_provider_test.dart`,
“expired authentication clears revision without a recovery request”: expected
401, received an offline exception. This newly added playlist-controls module
was being edited in a separate session and was not changed as part of import.
Earlier full runs encountered different in-progress tests in that same module.
The focused import results are the stable acceptance evidence for this change.

Focused Flutter command:

```sh
flutter test --no-pub --reporter expanded test/import \
  test/screens/import_sheet_test.dart \
  test/screens/spotify_request_screen_test.dart \
  test/screens/home_waiting_test.dart test/screens/service_gate_test.dart \
  test/presentation/providers/listening_import_provider_test.dart \
  test/presentation/widgets/collection_review_form_test.dart
```

Coverage includes shared web/Dart snapshot and translated-header contracts,
quoted/multiline CSV, invalid/local identities, duplicate occurrences, empty
exports, multiple selected CSVs, cancellation, limits, explicit Liked Songs,
skipped files, partial playlist updates, stale/foreign targets, exact retries,
metadata-only changes, source isolation, official snapshot overlap, and retained
listening history. Existing official-package regression fixtures still pass.

## Rendered checks

- Real web components in `web/qa/exportify.html`, using the fake API and the real
  parser/import service. `?state=review` opens a synthetic two-song CSV review.
- Verified 500px and 320px mobile review layouts, labels, wrapped controls,
  disabled Upload before confirmation, role-dependent counts, successful import,
  and the taste-interview handoff. No decorative left rails remain in app source.
- Native widget check at 320px with 1.6x text scale verifies no overflow and the
  separate removal/review confirmations before replacing Liked Songs.
- Reading/upload Cancel lives beside the heading, with its normal touch target.
  Native reading progress follows actual parser events across the isolate.

## Release checks still outstanding

- Real Exportify Export All ZIP and filtered/single/multiple CSV manual refresh
  on desktop Chrome, Android Chrome, and a physical iOS device.
- Signed native device acceptance, including external-browser return and Files.
- Apply migrations 0027 and 0028, then release the compatible server before the
  new clients. Old clients receive a conflict if they attempt an unreviewed
  Account-data rollback after a quick import; the new clients offer fresh review.
- Validate current dark-mode/device behavior as part of signed release smoke;
  the approved board's dark states are design evidence, not a device test.

Personal exports and production credentials were not used for these checks.

## Continuation — 2026-09-09

The founder authorized real-export testing followed by production rollout, in
that order. The real Exportify Export All ZIP and optional filtered/individual
CSV paths have been requested; neither file has been supplied to this task yet.
Production work remains downstream of that acceptance step.

The previously failing playlist-context provider test file was rerun on
September 9: all nine tests passed. This resolves that specific earlier failure;
it does not replace full validation of an isolated release candidate.

The shared checkout still contains uncommitted Exportify, web-control, native
control, and auth work. Freeze only the reviewed release scope, then validate
and deploy from its clean worktree. Apply the required schema before the Worker
and publish compatible clients afterward. Do not trigger the main-branch web
auto-publish before the backend is ready.
