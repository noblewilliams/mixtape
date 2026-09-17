# Six-feature implementation sequence — 2026-09-09

Scope and web/native UI approved. Preserve the proven core flows and existing playlist
editing files. Do not interpret this plan as completed implementation.

1. [x] Board approved; record: `../../mockups/approved/2026-09-09-next-features.md`.
2. [x] Implemented locally — snapshot retention and owner/version-safe mix restore; schema migration, route tests,
   legacy baseline, web/native history UI, restore conflict and idempotency checks.
3. [x] Implemented locally — Energy intent controls and deterministic journey evaluation; golden-set sequencing,
   hard-constraint/pin preservation, honest partial-feature display.
4. [x] Implemented locally — App-owned Apple playback and existing web transport; observed-time state machine,
   bounded account-scoped event outbox, opt-out/deletion, bounded feedback scoring,
   focused physical-device acceptance for interruptions/background/lock screen.
5. [x] Implemented locally — Pattern-based Home suggestions; eligibility, time zones, dismiss/off, explicit generation.
6. Apple archive reader; nested ZIP/CSV/JSON fixtures and bounded-memory stress tests,
   staged import review, real-layout validation, web-first then native parity.
7. Consent and private invitations, balanced blends, revocation/leave/block; then opt-in
   twin discovery with report handling and cache invalidation. No automatic contact access.
8. Integrate completed slices, run authoritative suites/builds, compare to approved board,
   prepare exact release and rollback references, then release within authorized scope.

Each step has a red-first test, implementation, independent-style adversarial inspection
and fix round. No sub-agents required. Record completed steps with evidence; do not mark
provider/device or real-archive acceptance complete from mocks.

Mix-history evidence: `../../testing/2026-09-09-mix-history.md`. Matching backend migration/deployment is still pending; do not describe mobile availability against production as shipped.

Energy evidence: `../../testing/2026-09-09-energy-journeys.md`. Coarse evaluation and prompt/structural golden cases passed; live auditory quality is not claimed. Migration 0030 and matching deployment remain pending.

Apple player/feedback evidence: `../../testing/2026-09-09-apple-player-feedback.md`. Migration 0031, matching deployment/native install, and physical-device player acceptance remain open.

Routine suggestion evidence: `../../testing/2026-09-09-routine-suggestions.md`. Migration 0032, matching release/native install and real-account acceptance remain pending.
