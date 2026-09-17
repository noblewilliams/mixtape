# Release completion — execution evidence

**Date:** 2026-09-08 · **Baseline:** local `05ba8b1` plus the explicitly scoped changes listed below.
**Status:** in progress; no release candidate frozen, no deployment performed.
**Contract:** [release completion and web controls](../superpowers/specs/2026-09-08-release-completion-design.md).

## Fresh execution

| Check / action | Environment | State | Evidence / next action |
|---|---|---|---|
| Inspect source, docs, local Git refs | Shared checkout | passed | Local main and cached origin/main at 05ba8b1; founder instruction/launch edits preserved |
| Read current GitHub main | `git ls-remote origin refs/heads/main` | passed | Initial sandbox DNS failed; read-only retry outside sandbox returned 05ba8b15be647fcfde297d79bc1d4600a12b6c43 |
| Reconcile current-status documentation | Repository | passed | Handoff links this record; backlog remote/P4 wording and draft migration header corrected |
| Inspect existing API contracts | Server/web source | passed | Memory GET/DELETE, session PATCH, revision-checked playlist seed PUT, taste-confirmation PUT already exist |
| Four-control state board | Local Chromium | passed | 36 states × 3 widths × 2 themes: 216 layout checks; large text at 320px, no script errors or overflow; desktop/light and short 320px dark/large views visually inspected. Revision 2 explicitly approved September 8 |
| API contracts for web controls | Web application | passed | Three red-first regression tests; inspiration create/select and reversible taste confirmation wired with explicit revision and signal support |
| Product web controls | Local web UI | passed | Modal forgetting; minimal dismissible menus; inline rename; swipe/archive/undo/restore; floating playlist picker with composer text attachment; explicit reversible taste confirmation |
| Web regression/build checkpoint | Shared checkout, API-only delta | passed | 37 files / 352 tests; TypeScript + Vite production build passed. This is not final candidate validation |
| Final candidate full checks | Clean candidate worktree | not run | Candidate follows controls and fixes; historical test counts are not fresh passes |
| Current Worker, Netlify, DB ledger | Production metadata | not run | Refresh with available service access; no private library reads |
| Recovery point and deploy ordering | Production configuration | not run | Prepare concrete recovery reference and safe web/backend sequence |
| Privacy disclosure mapping | [Draft](privacy-disclosure-draft.md) | passed | Initial code-traced draft and Apple category mapping prepared; business facts, vendor settings and final disclosure review remain open |
| Worker/web release | Production | not run | Exact reviewed artifact and release authorization required |
| Signed archive / TestFlight | Apple distribution | not run | Inspect signing access, build and submit when authorized |
| Physical iOS / Android Chrome | Real devices | not run | Access required; responsive emulation cannot close these checks |
| Real export / funnel evidence | Both Spotify archives | blocked | Archive paths have not been supplied in this task |

## Historical evidence — not refreshed

- Production ledger through 0026 (27 matching migrations), recorded in the September 5 preflight. No additional migration is expected for revised copies.
- Worker provider-only cace81e on fd5f66b, version f2c5014b-a199-4398-bec9-e0dd22ac0d7e; rollback 7a6ec181-2292-4d56-b8a4-abb996d6857a.
- Netlify artifact 05dad49, recorded September 6.
- Revised-copy local verification: 1,311 server tests, 567 Flutter tests, clean analysis/typecheck and unsigned device build.
- Original v1/P4 device smoke passed on August 30. New release/device checks remain separate.

## Change boundary

Owned changes: this record, current spec, handoff/backlog reconciliation, draft-foundation status correction, approved web-control board and implemented controls, API client/contracts and regression tests, test adapter, and initial disclosure draft. Founder-owned AGENTS.md, CLAUDE.md and .claude/launch.json remain untouched. No commit, push, deployment, account/library mutation, or production migration has run in this task.

## Design revision — founder feedback, September 8

The founder requested a true modal for Forget, outside-dismiss minimal absolute
action menus, inline title editing, the existing left-swipe gesture for archive,
and a floating playlist widget with a text attachment inside the composer. The
spec and board now reflect this direction. Revision 2 passed 216 layout checks with no script errors, overflow, or sub-44px buttons, plus 9 interaction checks for modal/menu dismissal, inline rename, swipe archive and attachment removal. The composer was pinned after visual review exposed a short-screen reachability problem. The approved revision is now implemented in the product UI. Browser validation uses the local synthetic harness, not provider or production accounts.

## Implementation and verification — September 8

- API and UI changes stay in the web client. Server contracts and migrations already exist; no server/schema/native edits belong to this controls change.
- Scoped components and `web-controls.css` keep the concurrent import styling untouched. The signed-in workspace remounts on account change; new control requests abort or ignore late results. Session metadata guards preserve a rename when an older session read arrives.
- Archive only changes status; Undo and Archived mixes restore it. Conversation/queue data stay intact. List, sidebar and closet share the gesture and inline editor.
- Uncertain note deletion and taste confirmation reread canonical state. Playlist selection sends the expected revision and refreshes on conflict; selecting a playlist alone does not create a mix or change the queue.
- Synthetic Chromium checks pass for inline rename, source exclusion, outside dismissal, drag archive/undo, preserved conversation/queue, modal focus/Escape, and eight responsive/theme layouts (320, 390, 768, 1240px; light/dark), plus closet inline editing and the picker at 320 × 568px. Desktop picker, Forget modal and mobile collection screenshots were visually inspected.
- Shared-checkout production build passed. At the 12:56 checkpoint, the shared web suite had 344 passes and 20 failures in four import-related files under concurrent Exportify edits. This is not a final combined candidate pass.
- Isolated validation copies committed `05ba8b1` web/fixtures plus only this controls delta; the API/test-adapter overlay excludes Exportify hunks. Final isolated suite: **42 files / 365 tests passed**, followed by a successful TypeScript and Vite production build. After adding late-result guards to existing create/send flows, the affected 18 tests and production build were rerun successfully. No shared checkout reset or staging was used.

Remaining: freeze and validate the combined candidate after concurrent work finishes; refresh production metadata and recovery references; finalize operator/vendor/privacy facts; authorized deployment and signed distribution; physical-device and real-export acceptance. Local synthetic checks do not close these gates.

## Native parity follow-on

The controls implemented above are web-only. The founder requested native parity after source comparison exposed missing inspiration/curation and Google/account controls plus different rename/archive/forget interactions. Track [native parity](../superpowers/specs/2026-09-08-mobile-parity-design.md) and its [execution plan](../superpowers/plans/2026-09-08-mobile-parity.md) before describing release work as smoke-testing only. All scoped native controls are now approved and implemented locally: 712 Flutter tests pass, analysis is clean, and the unsigned iOS simulator build succeeds. Google public native configuration, real-provider/device acceptance and release delivery remain open; the native UI integration gate is closed.
