# Release completion and web controls

**Status:** revision 2 approved 2026-09-08; web controls implemented locally. Release preparation and external acceptance gates remain open; see the execution evidence record.
**Date:** 2026-09-08
**Baseline inspected:** local `main` at `05ba8b1`. Local `origin/main` matches;
initial sandbox DNS failed; subsequent read-only verification outside the sandbox confirmed remote main at the same commit. Production
state below comes from September 6 records and must be refreshed before release.

## Outcome

Finish the release of the implemented Spotify import, web music, playlist
intelligence, and native playlist editor, and implement the requested web memory,
session management, playlist inspiration, and taste-confirmation controls.
Produce a tested release candidate,
complete the work possible with available tools, and leave a precise list of
checks that require account access, a physical device, or real archives.

The founder explicitly included these deferred web controls on 2026-09-08.
Other deferred product features remain separate work. Writing this specification
does not authorize publishing, provider mutations, or private library access.

Read with:

- [Program handoff](../../handoff.md)
- [Backlog](../../backlog.md)
- [Existing release and real-export acceptance contract](2026-09-05-listening-export-release-validation-design.md)
- [Playlist editing contract](2026-09-05-conversational-source-playlist-editing-design.md)
- [Revised-copy implementation and verification](../plans/2026-09-06-playlist-revised-copy-apply.md)

This document organizes remaining execution; the existing contracts continue to
define import semantics, source ownership, playlist writes, and privacy rules.

## Starting point

- Original v1 phases are recorded as complete and founder-verified.
- Spotify import phases 1–3, web Your music, catalog resolution, playlist taste,
  and playlist inspiration are implemented with recorded rollout evidence.
- The latest draft editor, native review, and revised-copy apply are committed.
  The last recorded production Worker contains only the earlier feature set and
  provider-CDN repair. The editing runtime still needs release verification.
- Production migrations through `0026` are recorded as applied. Revised-copy
  apply requires no additional migration. Never replay the chain blindly.
- Latest recorded local checks: 1,311 server tests, 567 Flutter tests, clean
  typechecking/analysis, and an unsigned device build. These are historical
  evidence, not fresh candidate verification.
- Real Spotify archives, signed distribution, and physical acceptance have no
  completion evidence in the reviewed records.

## Ownership and prerequisites

| Work | Can proceed during implementation | Prerequisite for completion |
|---|---|---|
| Reconcile docs, inspect code, local tests/builds, synthetic browser QA | Yes | Local dependencies and tools |
| Design and implement the included web controls | Yes, design first | Reviewable state board, then visual approval before product UI changes |
| Repair reproducible defects in the existing release contract | Yes | Red-first regression coverage; design approval if a substantial UI change is needed |
| Draft privacy disclosures and release evidence | Yes | Founder supplies business facts that code cannot establish |
| Read deployment metadata, migration ledger, aggregate health | With available authenticated access | Working network and service access; no private music payloads |
| Prepare signing/archive and upload configuration | With available credentials | Developer account, certificates, provisioning; interactive login may require founder |
| Publish Worker/web, upload TestFlight, create recovery branch | After preparation | Authorization for the concrete target and artifact; reuse authorization already given for that exact scope |
| Operate real-account flows and disposable playlist tests | When access is available | Authorized account/device access; founder handles inaccessible prompts or physical actions |
| Validate real exports | After archives arrive | Both Spotify packages supplied outside the repository; approved private-data handling |

Do all independent preparation before requesting missing access or approval.
An unavailable device or archive does not prevent completing local work. Never
substitute an emulator or fake provider result for physical provider evidence.

## Work package 1 — reconcile the release record

Create `docs/releases/2026-09-08-release-completion.md` during execution as the
single evidence record. For each check record the SHA, artifact/environment,
command or action, result, date, and any blocker. Use states `passed`, `failed`,
`not run`, or `blocked`; distinguish historical evidence from fresh execution.

Update the handoff and backlog with links to that record. Correct current-status
claims that contradict later evidence: the missing Git remote, original P4
smoke, migration-0025 pending header, and obsolete release versions. Preserve
dated historical reports and annotate superseded checklists rather than treating
every old unchecked box as unfinished implementation.

Refresh remote HEAD, deployed Worker version/base, Netlify artifact, migration
ledger, and available iOS build information. If access fails, record the precise
verification gap; do not label a previously recorded outage as still ongoing.

**Acceptance:** every current-release item has a status, evidence pointer, and
next action; no undocumented claim that local code is deployed or device-proven.

## Work package 1A — complete the included web controls

Interaction revisions requested by the founder on 2026-09-08 are incorporated
below. The revised board still requires visual review; these requests supersede
the first board’s inline forgetting panel and full-width inspiration section.

### Design contract

Create `docs/mockups/2026-09-08-web-controls-states.html` during execution, using
the real shell, tokens, icons, typography, and existing approved Your music
design. Show the following four features together so desktop and mobile action
placement can be assessed. Include populated, loading, empty, error/retry,
mutation-in-progress, confirmation, conflict, and success states; narrow/short
viewports, both themes, large text, keyboard focus, and reduced-motion behavior.

Render and inspect the board, then request approval and record it under
`docs/mockups/approved/`. This follows `.agents/skills/ui-state-board/SKILL.md`:
“For a substantial unapproved visual change, create and present the board before
editing product UI code.” Spec acceptance alone is not approval of unseen screens.

### A. What the DJ knows

Expose a discoverable memory view using the existing web `listMemories` and
`deleteMemory` methods and owner-scoped `/me/memories` routes. Show actual notes,
their scope when present, loading/empty states, and a per-note Forget action.
The founder requires confirmation in a modal before deletion. Backdrop click and Escape dismiss without deleting; trap focus and restore it to the originating action. The server
hard-deletes notes and has no restore endpoint: never show an Undo action after
deletion or pretend a failed request succeeded. Refresh canonical state after
an uncertain response. Treat an already-absent note as resolved after refresh.

Do not introduce freeform creation/editing, inferred memory, or a new backend
memory model. Existing conversational remembering remains the creation path.

### B. Session rename, archive, and restore

Add accessible actions to the existing session navigation and an archived-mixes
view. Tapping/clicking a mix name turns it into an inline input; Enter or blur
saves valid input, Escape cancels, and failure preserves the draft. Provide a
separate Open action so renaming and navigation do not compete. Action popovers
are absolutely positioned, use minimal text buttons, and close on outside click
or Escape. Swipe/drag left archives using the existing song-removal gesture: a
6px horizontal intent threshold, vertical-scroll escape, action reveal on a
short drag, and commit on release beyond 65% of row width. Preserve the current
3-second undo affordance, cancellation behavior, reduced motion, and keyboard
access to Archive. Suppress click-to-edit after a swipe. Use `PATCH /sessions/:id` with `title` or `status: active|archived`;
the existing list includes archived sessions, so filter them deliberately.
Restore means unarchive, not restore an earlier mix version.

Use the canonical returned title/status. Validate nonblank input and honor the
existing 120-character request bound and sanitized 60-character display limit.
Disable duplicate submissions and retain input on error. Renaming must not
overwrite a newer open-session response. Archiving preserves transcript and mix;
if the open mix is archived, return to Home after success. Restore refreshes the
active list and offers an explicit way to open the mix. No permanent deletion.

### C. Playlist inspiration

Add “Make a mix inspired by this” from playlist detail. It opens the ordinary
mix composer with an explicit selected playlist and waits for the listener to
submit a brief. Pass `playlistSeed` to the existing `POST /sessions` contract.
Use a compact floating playlist widget anchored above the main composer. Once
attached, show a small text attachment inside the input (Inspired by [playlist]),
with a detach action. Opening the attachment exposes replacement and the option
to use different songs in the floating widget. Outside click and Escape dismiss
the widget without changing selection. Keep it within the viewport on short
screens, using internal scrolling. Do not use the earlier full-width inspiration
section or prominent Replace/Clear buttons. Existing sessions keep the same
compact attachment representation across follow-ups.

Reuse `PUT /sessions/:id/playlist-seed` with `playlistId`,
`excludeSourceTracks`, and `expectedRevision`. Read canonical `playlistSeed`
from session responses. Expose none, ready, unavailable, insufficient-profile,
and stale-selection states. A profile requires three resolved recordings;
the UI explains insufficient coverage rather than inventing readiness.

Choose exact owned playlist IDs through existing browse/search/pagination.
Duplicate names must remain distinguishable; never select the first name match
silently. On a stale revision, reload and ask the listener to retry the intended
selection; do not automatically overwrite another change. Selecting, replacing,
clearing, or toggling exclusion leaves the existing mix intact until an explicit
DJ request. It neither edits the source nor confirms it as taste evidence.

### D. Confirm a playlist as personal taste

On playlist detail, explain that a listener can confirm songs they personally
curated to inform future mixes. Use the existing
`PUT /playlists/:id/taste-confirmation` with `{ confirmed: boolean }` and refetch
the canonical detail. Offer a reversible confirmation control; removing the
confirmation removes only that evidence, not the playlist or listening history.

Unknown origin stays neutral by default. Mixtape-created, editorial, Replay,
personal-mix, or inactive playlists cannot become positive evidence through
this control. Preserve the server's eligibility checks and creation-receipt
precedence. Do not infer ownership from a name, curator label, or provider alone.
Show a truthful unavailable state when eligibility is unknown. If the browse
projection lacks enough facts, add a small additive eligibility field computed
from the same server rules, with route coverage; no schema change is expected.
Handle a `409` by refreshing eligibility rather than locally forcing success.

### Shared implementation and verification

Primary seams: `web/src/api/client.ts`, `web/src/App.tsx`, session domain/state,
`Sidebar.tsx`, `PlaylistBrowser.tsx`, and new focused components as needed.
Keep network/state ownership above transient dialogs. On sign-out/account change,
cancel work, clear user data, and ignore late responses; no private notes or
playlist details enter persistent browser storage or diagnostics.

Add red-first API/component/state tests for each feature: success, validation,
failure, uncertain completion, double submission, canonical refresh, account
switch, and conflict where supported. Test that inspiration never mutates a
playlist or existing mix on selection, unconfirmation preserves other evidence,
and archive/restore preserves session contents. Reuse existing server contracts;
add backend tests only for changed contracts or uncovered integration behavior.

**Acceptance:** all four features work against real application components,
match the approved board, pass focused and full web checks, and are included in
production browser acceptance. No native or web playlist editing surface beyond
these controls is added by this work package.

## Work package 2 — freeze and verify the candidate

Complete work package 1A above before freezing the combined candidate. Local
release preparation may proceed alongside design review; publishing must use
the final reviewed artifact rather than an earlier pre-controls snapshot.

Inspect the complete application diff from the deployed runtime to the candidate,
including the draft foundation, DJ loop, native review projection, and apply
contract. Select one committed SHA and use a clean worktree for release builds.
Preserve founder-owned `AGENTS.md`, `CLAUDE.md`, and `.claude/launch.json` edits.

Run the existing authoritative checks once for the final candidate:

| Surface | Checks |
|---|---|
| Server | `npx vitest run --no-file-parallelism`; `npm run typecheck` |
| Schema | Drizzle consistency and existing upgrade rehearsal through the candidate journal |
| Worker | Minified deployment dry-run and binding/size inspection with no secret values |
| Web | `npm test`; `npm run build` |
| Flutter | `flutter test`; `flutter analyze`; unsigned iOS build |
| Fixtures | `node fixtures/listening-exports/build.mjs --check`; both parser contract suites |
| Repository | Scoped diff review, `git diff --check`, exact artifact provenance |

Fix candidate defects with focused regression tests first, then rerun affected
checks. A claimed baseline failure must reproduce on the prior revision. Do not
repeat broad checks after success without a changed candidate or new concern.

**Acceptance:** all required gates pass, or a specific unresolved failure remains
visible and prevents the affected release step. No placeholder tests count.

## Work package 3 — finish local browser acceptance

Reuse the actual-component synthetic harness at `/qa/your-music.html`, existing
import fixtures, and injected provider/API seams. Verify keyboard navigation,
focus, narrow layouts, 200% zoom, light/dark appearance, reduced motion and
transparency, loading, permission denial, cancellation, offline, partial results,
lost-response reconciliation, and account changes.

Cover Sources, playlist collection/detail, Spotify inspect/import/output,
memory forgetting, session rename/archive/restore, playlist inspiration and
taste confirmation. Verify controls stay reachable and do not clip at short
and narrow viewport sizes. Exercise the built artifact separately where useful;
the QA harness is not a production entry and must not ship in `dist`.

Repair failures within the approved UI and behavior. The new controls follow
work package 1A's state board; further redesign requires its own approval.

**Acceptance:** a surface/state matrix records actual browser results and fixes.
Desktop responsive emulation remains separate from real Android Chrome evidence.

## Work package 4 — prepare recovery and disclosures

Inspect migration order/hashes and current schema postconditions with bounded,
read-only queries. Reuse existing scripts and tests; add small operator checks
only where a concrete evidence gap exists. Scripts touching production stay
dry-run by default, require `--apply` for writes, and emit fixed categories and
counts rather than response bodies or credentials.

Verify available Neon recovery facilities and record a recoverable reference,
retention/expiry, and recovery procedure. A branch created now protects the
current state; it cannot prove a pre-migration snapshot existed. Historical
before/after assertions without a baseline remain explicitly unverified.

Inspect Netlify publishing configuration and document how the candidate reaches
production only after its backend is compatible. Prepare any configuration
change for review before applying it. Record previous Worker/web artifacts and
rollback steps; database restoration is never an automatic rollback action.

Draft `docs/releases/privacy-disclosure-draft.md` from the actual data path:
normalized listening history, memberships, playlists, artists, provider lookups,
retention/deletion, on-device archive parsing, and third-party processing.
Prepare an App Store disclosure mapping. Mark missing operator/contact,
retention-policy, and business facts as questions; do not invent them or claim
publication. Verify current platform disclosure requirements during execution.

**Acceptance:** recovery and release order are concrete and reviewable; privacy
copy is traceable to implementation, with unresolved facts clearly identified.

## Work package 5 — release and production acceptance

Once the concrete release is authorized and access is available:

1. Reconfirm the production ledger and selected artifact compatibility. Expect
   no new migration; stop and investigate any unexpected mismatch.
2. Deploy the candidate Worker from its clean worktree; record version and
   rollback reference. Verify health, auth guards, and editing route availability.
   A `401` alone proves neither authenticated behavior nor feature correctness.
3. Verify or promote the matching web build after backend readiness. Run the
   authorized Apple/Google auth, Your music, sync/browse, mix, output, and the
   four new web-control flows. Use synthetic/disposable records for deletion
   and taste changes unless specific founder records are authorized.
4. Produce the signed iOS archive and upload to TestFlight when signing and
   account permissions allow. Record build number, commit, upload/processing
   status, and installability separately. Never claim submission from a local build.
5. On an accessible authorized device, exercise private draft editing and apply
   to a disposable revised copy. Verify exact ordered contents, duplicates,
   untouched source, receipt confirmation, and repeat-operation reconciliation.
   Append and rebuild remain disabled. Stop on partial/unknown outcomes; inspect
   the existing operation rather than creating another playlist blindly.
6. Observe aggregate health, import errors, enrichment and catalog progress for
   a bounded documented window. No indefinite monitor is created by this spec.

If device control is unavailable, supply the exact manual steps and expected
results, complete all independent work, and retain the physical check as open.

**Acceptance:** versions and provider outcomes are evidenced per surface. Failed
checks stop distribution or invoke the documented application rollback, with no
silent database reversal or repeated provider writes.

## Work package 6 — real-export acceptance, when available

Inspect both Spotify packages outside the repository. Convert layout differences
into minimal invented fixtures, repair both parsers if necessary, and rerun their
shared contract suites. Apple archives may inform future work but are not
importable through an implemented Apple export adapter in this release.

Execute the existing real-world matrix on accessible iOS, desktop Chrome, and
Android Chrome. Validate manual totals for three recordings including a dual-ID
case, local dates and the 30-second rule, private-session choice, memberships,
playlist order/duplicates, source deletion, enrichment, personal mixes, outputs,
and unchanged re-imports. Use a disposable test account/source for destructive
deletion checks where possible; never remove founder data as an incidental test.

Run the existing counts-only funnel report and record actual
`import_completed` and `first_output` evidence. Missing archives or physical
surfaces remain external dependencies, not synthetic passes.

**Acceptance:** the real-data matrix passes on each required surface or names
the exact outstanding case. Phase 4 remains closed until its evidence gate passes.

## Exclusions

These are feasible future engineering tasks, but are not prerequisites to finish
the implemented release and are not silently included here:

- Memory creation/editing UI and a browser version of the native playlist editor.
- Direct playlist append, in-place rebuild, or Spotify write-back.
- Apple export parser, relay/embed probes, and broader v2 features.
- Historical legacy-membership reconciliation and mix version history.
- Unrequested backfills, resetting enrichment retries, or live mutation probes.

## Completion definition

**Preparation complete** means the four web controls, approved visual design,
candidate, local verification, browser QA,
release procedure, disclosure draft, and reconciled documentation are finished;
remaining dependencies have concrete artifacts ready for action.

**Release complete** additionally requires deployment, distribution, physical
and real-export acceptance, disclosures, and funnel evidence. A blocked external
gate does not make the release complete. The final report must distinguish these
two milestones and list only the work that actually remains.
