# Playlist edit draft foundation implementation plan

**Status:** implemented and verified locally; migration 0025 and deployment remain approval-gated

**Spec:** [conversational source-playlist editing](../specs/2026-09-05-conversational-source-playlist-editing-design.md)

## Scope and ownership

This slice delivers only the provider-independent server foundation:

- immutable base plus mutable ordered draft snapshots;
- occurrence identity that preserves duplicate songs;
- deterministic add/remove/move/replace operations and diff;
- one resumable active draft per listener and source playlist;
- authenticated create/resume, read, mutate, and abandon routes;
- migration 0025, schema constraints, indexes, and account/source cascades.

No LLM tool, Apple mutation, apply plan, Flutter/web UI, taste write, or provider
call belongs to this slice. Existing uncommitted documentation from concurrent
tasks is out of scope.

## Task 1 — schema and migration

Complete. Three indexed tables store the draft header, immutable/mutable entry
roles, and compact events. Migration `0025_ordinary_sinister_six.sql` was
generated and the `0014–0025` rehearsal passed. It has not been applied to
production.

Red first with schema/migration tests for the three draft tables, every foreign
key and covering index, occurrence uniqueness, active-draft uniqueness, valid
statuses/roles/origins, nonnegative versions/positions, snapshot metadata
checks, and terminal-field consistency.

Add Drizzle schema and generate migration 0025. Rehearse the complete committed
migration chain and account/source deletion. Review the generated SQL before any
production action; this plan does not authorize applying 0025.

## Task 2 — deterministic draft domain

Complete. Occurrence anchors preserve duplicate songs, and an `O(n log n)`
longest-increasing-subsequence diff finds minimal moves without quadratic memory
for a 10,000-entry playlist.

Red first through a small pure interface:

```text
applyDraftOperations(entries, operations) -> entries
diffDraft(base, draft) -> additions/removals/moves/replacements
```

Cover duplicate recordings, stable occurrence keys, source-entry preservation,
anchor insertion, contradictory/missing anchors, repeated keys, zero-length
drafts, minimal moves, replacement identity, and deterministic results. This
module accepts no database or provider dependency.

## Task 3 — deep draft store

Complete. One store creates/resumes, reads, mutates, and abandons drafts. Source
copying happens in one SQL statement; mutation locks and version-checks the
header, performs no external work, writes the new ordered role in bounded
batches, and returns the exact committed version.

Red first through one store interface that creates/resumes, reads, mutates, and
abandons a draft. Creation copies the currently published source into base and
draft roles in a short transaction. Mutation computes outside-provider logic,
locks the draft, rechecks the expected version, replaces only draft rows,
records compact events, and increments once.

Cover owner scoping, one active draft, exact order/duplicates/unresolved entries,
version conflicts with no partial write, disappeared source, terminal drafts,
and safe cascading deletion. No network or model work may run in a transaction.

## Task 4 — authenticated routes

Complete. The four routes are authenticated and tenant-scoped. Strict payloads
are bounded to 50 operations / 16 KiB; malformed and foreign identifiers use the
established safe responses. Capability remains honest: revised-copy planning is
visible, but apply is unavailable in this server-only slice.

Red first for:

```text
POST   /playlists/:playlistId/edit-draft
GET    /playlist-edit-drafts/:draftId
POST   /playlist-edit-drafts/:draftId/operations
DELETE /playlist-edit-drafts/:draftId
```

Validate UUIDs, strict bounded payloads, expected versions, operation count,
anchors, and catalog track ownership/identity. Malformed, missing, and
cross-listener identifiers share the established safe response behavior.
Responses include the current ordered entries, deterministic diff, and
conservative `revised_copy` capability only.

## Task 5 — adversarial review and verification

Complete. The review fixed a quadratic diff implementation and a post-commit
response race. Focused coverage passed 28 tests; server typecheck and Drizzle
consistency passed; the authoritative serial suite passed 76 files / 1,284
tests. Diff checks are clean for owned files.

Review tenant isolation, duplicate handling, transaction length, lost updates,
source mutation, cascade cost, payload bounds, prompt/provider leakage, and
future apply compatibility. Fix every concrete finding, then run focused tests,
server typecheck, Drizzle consistency, migration rehearsal, the authoritative
serial server suite, and diff hygiene.

Commit only owned implementation/plan files. Deployment, migration 0025,
private-data reads, and device mutation remain separate approval gates.
