# Revised-copy playlist apply implementation plan

**Status:** implementation complete; release pending

**Spec:** [conversational source-playlist editing](../specs/2026-09-05-conversational-source-playlist-editing-design.md)

**Approved board:** [iOS playlist editing with the DJ](../../mockups/approved/2026-09-06-ios-playlist-editing.md)

## Scope

This slice turns an approved private draft into a new Apple Music playlist and
leaves its Apple or Spotify source untouched. It adds prepare, native creation,
receipt confirmation, and unknown-outcome reconciliation. It does not enable
append, rebuild, Spotify write-back, or automatic mutation.

The interface stays deliberately small:

```text
server prepare(draft, current source fingerprint) -> immutable operation plan
native createRevisedPlaylist(plan)                -> durable receipt/outcome
server confirm(operation, exact result)           -> applied draft
```

The server owns policy and idempotency. The native adapter owns MusicKit and a
small on-device receipt keyed by the opaque operation ID. Flutter orchestrates
the two without inventing a provider result.

## Task 1 — deterministic apply plan

Red first for a versioned, owner-scoped `prepare-apply` route. Reject unchanged
drafts, stale source fingerprints, unresolved entries, unsupported modes, and
expired or conflicting plans. Return the same unexpired operation for repeated
prepares of the same draft version. The only selectable mode is
`revised_copy`; append and rebuild remain closed.

The desired fingerprint is a versioned SHA-256 over the ordered Apple catalog
IDs, with length framing so duplicates and order are unambiguous.

## Task 2 — confirmation and receipts

Red first for an idempotent `confirm-apply` route. Accept only the prepared
operation, exact draft version, `revised_copy` mode, bounded Apple library ID,
and exact desired fingerprint. In one transaction, mark the draft applied,
write the Apple/Mixtape origin receipt, append one apply event, and make a
repeat confirmation return the same success without duplicate evidence.

An expired plan may still be confirmed when Apple already completed the exact
operation; expiry prevents starting a new mutation, not recording its receipt.

## Task 3 — native revised-copy adapter

Red first at the Dart channel seam and Swift contract checks. Resolve every
catalog song before creating anything, create with typed MusicKit, persist the
operation-ID-to-library-ID receipt immediately after creation, add songs in
order, refetch, and return fixed `success`, `partial`, or `unknown` outcomes
with the resulting ordered-catalog fingerprint. Never retry additions merely
because a prior call lost its response.

## Task 4 — Flutter apply orchestration

Red first for preparing, applying, applied, blocked, source-conflict, partial,
and unknown states. The review confirmation calls the server plan, then the
native adapter, then server confirmation only for an exact success. Partial or
unknown outcomes expose reconciliation and keep the source-untouched promise.
The dispatcher rejects append/rebuild even if a malformed server response asks
for them.

## Task 5 — verification and release

Run focused server and Flutter tests, native contract checks, server
type-checking, Flutter analysis, authoritative full suites, and an adversarial
fix round. This slice uses the prepared columns already shipped in migration
`0025`; no new database migration is expected.

Production order remains: deploy the server contract, install the matching
client, run a disposable revised-copy device smoke, verify the new Apple
playlist's exact order and untouched source in Music, then record the provider
evidence. Cloudflare control-plane availability and explicit production/device
approval remain gates.

## Local verification

- Server prepare/confirm route coverage passes, including owner/version fences,
  unresolved blocking, exact confirmation, idempotent evidence, and renewal of
  the same operation ID after plan expiry.
- Dart bridge, API/model, provider, widget, and native contract tests pass.
- The authoritative server suite passes 1,311 tests and server type-checking is
  clean.
- The full Flutter suite passes 567 tests and Flutter analysis is clean.
- The iOS 16 device workspace compiles without signing.
- No database migration is required; migration 0025 already contains the
  prepared-operation and applied-receipt fields.
