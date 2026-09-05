# Playlist edit DJ implementation plan

**Status:** implemented, committed, pushed, and migrated; Worker deployment remains release-gated

**Spec:** [conversational source-playlist editing](../specs/2026-09-05-conversational-source-playlist-editing-design.md)

## Scope and ownership

This slice makes an active playlist draft conversational without adding any
provider write path:

- durable, draft-scoped user and DJ messages;
- bounded Apple catalog song search using a developer token and the listener's
  synced storefront;
- deterministic insertion placement from the draft's neighbouring track
  metadata;
- a separate playlist-context tool loop exposing only `search_catalog` and
  `edit_playlist_draft`;
- an authenticated, versioned message route;
- migration 0026, schema constraints, indexes, and account/draft cascades.

Apple append, rebuild, revised-copy creation, prepare/confirm, Flutter/web UI,
and taste writes are outside this slice. Existing uncommitted instruction and
launch files remain user-owned and out of scope.

## Task 1 — durable playlist-edit messages

Complete. Migration 0026 adds a draft-cascading, indexed transcript with strict
role/version coherence and monotonic sequence order. Reopening a draft returns
its newest 200 messages in chronological order. Production migrations 0025 and
0026 were applied from clean commit `a5f8185`; the 27-entry ledger has no hash
mismatches or pending migrations.

Red first for a `playlist_edit_messages` table keyed to the draft. Messages use
a monotonic sequence for transcript order, carry `user | dj`, and record the
draft version associated with a DJ reply. The draft foreign key has a covering
index and cascades on draft/account deletion. Generate and rehearse migration
0026, but do not apply it to production in this task.

## Task 2 — bounded catalog discovery

Complete. The existing developer-token client now supports catalog song search
with Apple's 25-item cap, the shared token cache, timeout, response-size bound,
and fixed error categories. Playlist discovery applies exact artist/album
filters, excludes current Apple IDs, upserts public catalog metadata, and only
returns bounded sanitized fields.

Red first by extending the Apple catalog adapter with:

```text
searchSongs(storefront, term, limit) -> CatalogSong[]
```

Use Apple's catalog search endpoint with `types=songs`, a strict 1..25 result
limit, bounded term length, the existing token cache, timeout, response-size
cap, song parser, and fixed error categories. Reject malformed result envelopes
instead of guessing. A playlist-edit catalog service upserts exact Apple song
IDs into `tracks` and returns only bounded display metadata and internal IDs.
No Music User Token is sent to the Worker.

## Task 3 — deterministic placement

Complete. A pure weighted transition score compares tempo, energy, year, genre,
artist, and album at every gap. Missing data is neutral, ties are stable, and a
metadata-free playlist appends. Multiple additions receive server-generated
occurrence keys so their sequential placement and order remain deterministic.

Red first through a pure placement interface. Candidate insertion evaluates
every gap in the current draft and minimizes discontinuity with its immediate
neighbours using available tempo, energy, release year, genre, album, and
artist metadata. Missing metadata is neutral. Ties remain deterministic and
preserve the order of multiple additions.

Direct request constraints remain the model's candidate-selection job; code
owns the final occurrence anchors. Existing songs are excluded by Apple catalog
ID unless the operation explicitly allows a duplicate.

## Task 4 — isolated playlist-edit tool loop

Complete. The separate loop has exactly two tools, a static system prompt,
bounded USER-altitude context/history, same-turn search-result authorization,
strict expected-version fencing, fixed error envelopes, and no provider write
dependency. Earlier committed draft changes are attached to a later turn error
instead of being hidden.

Red first for a new loop with a static system prompt and a bounded USER-altitude
playlist context. It exposes only:

```text
search_catalog(query, artist?, album?, limit?)
edit_playlist_draft(operations[], expectedVersion)
```

The loop persists the listener's message before any external call, caps
transcript/context/tool rounds, validates every tool input, and writes one
versioned draft mutation per edit tool call. Catalog and LLM work happen outside
transactions. A version conflict stops the turn and requires a fresh client
read; the listener's explicit expected version is never silently bypassed.
Tool results and logs use bounded fixed shapes and never serialize provider
bodies or prompts.

## Task 5 — authenticated route and verification

Complete. The message route is authenticated, tenant-safe, strict, and limited
to 16 KiB. The adversarial review fixed nullable DJ message versions, invented
internal track IDs, unbounded cumulative diff tool results, hidden partial turn
commits, and inaccessible transcript persistence. Focused coverage passed 74
tests; typecheck and Drizzle consistency passed; the authoritative serial suite
passed 78 files / 1,303 tests. Diff checks are clean for owned files.

Add:

```text
POST /playlist-edit-drafts/:draftId/messages
```

The strict body accepts `content` and `expectedVersion`, is limited to 16 KiB,
and preserves tenant-safe 404 behavior. Responses contain the persisted DJ
message plus the exact committed draft view. Cover "a couple" as exactly two
nonduplicate additions, artist-constrained catalog search, placement, removals,
version conflicts, malformed tool calls, upstream failures, prompt sanitation,
and cross-listener isolation.

Finish with an adversarial review, focused tests, server typecheck, Drizzle
consistency, full serial server tests, migration rehearsal, and diff hygiene.
Commit only owned files. The implementation is committed and pushed as
`a5f8185`. Deploying the Worker and any device/provider mutation remain separate
explicit approval gates.
