# Mix version history — implementation evidence

Implemented locally for server, web and native iOS. Migration 0029 is generated;
it has NOT been applied to production. No production deployment or binary install
was performed in this slice. A mobile client pointing at production needs the
matching backend release before version-history requests can succeed.

## Behavior

- Capture current legacy content before the first new change; never fabricate older versions.
- Save each completed generation/edit atomically with its immutable ordered snapshot.
- List/read owner-only history; paginated 50-version pages, including empty versions.
- Restore to a new increasing version with owner lock, expected-version check and
  retry identity. Mismatched retry inputs conflict; deleted historical recordings
  reject restore without deleting the current queue.
- Preserve removed-row provenance; emit no played/saved events and make no provider
  playlist or playback calls. Account/session deletion cascades stored history.
- Web and native: mix actions → Version history; old transcript version chips open
  that version. Preview, confirmation, retry, conflict and missing-history states.
- Current mix is refetched after successful restore. Leaving history does not play
  anything. Unknown-result retries reuse their request identity while the flow stays
  open; reopening history reads canonical versions rather than automatically retrying.

## Validation

- Server authoritative full suite: 81 passed files, 1 skipped; 1,323 passed tests,
  1 opt-in acceptance test skipped. Duration 265.63 seconds.
- New store and existing queue-store: 34 passed tests; new route test passed.
- Server TypeScript: passed.
- Web full suite: 45 passed files, 1 skipped; 374 passed tests, 1 skipped.
- Web production build: passed; existing >500kB bundle warning remains.
- Native focused history/conversation tests: 37 passed; analyzer clean.
- Native visual/short-phone run: 3 tests passed, including 320×568 at 200% text.
- Real web component inspected in local synthetic harness through list → preview →
  confirmation → success. Native rendered preview visually inspected in dark theme.
  These are synthetic local checks, not production-account or device acceptance.

Adversarial review covered ownership, stale writes, retry identity reuse, rollback
on missing recording, legacy emptiness, pagination boundaries, async disposal,
account scope, provider-write absence and preservation of unrelated shared changes.
Follow-on milestones (energy journeys, player/feedback, suggestions, Apple history,
social) remain unimplemented under the approved six-feature plan.
