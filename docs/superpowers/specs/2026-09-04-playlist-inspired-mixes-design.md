# Playlist-inspired mixes

Status: approved and implemented locally; release approval pending.

Parent: [artwork and playlist intelligence](2026-08-31-artwork-playlist-intelligence-design.md),
playlist-as-seed section. This completes a separate part of Phase 3; it does
not implement conversational playlist editing or release the pending foundation.

## User outcome

“Make me a mix like Late Nights, but calmer.” The result is a new ordinary mix.
The source playlist is read-only. Later requests such as “more upbeat” keep the
selected inspiration unless the listener changes or clears it.

Recommended defaults:

- Original songs may compete normally; exclude them only when requested. This
  retains the parent spec's default. “Different songs” means not in the source
  playlist, not songs the listener has never heard.
- Keep the existing candidate rules. Inspiration ranks the listener's eligible
  tracks; it does not add playlist-only tracks or open catalog discovery.
- Keep the existing personal/corpus eligibility gate and honest corpus notice.
  Selecting a playlist does not silently replace the interview threshold or
  create saved-library membership, play counts, artist seeds, or taste evidence.
- Any active playlist owned by the listener may be deliberately selected,
  including editorial, unknown-origin and Mixtape-created playlists. Explicit
  session inspiration is different from inferred long-term preference.
- The current request wins over the reference, including era, explicit-content,
  tempo, and other user constraints. The reference supplies soft context, never
  new hard constraints. Existing saved preferences still reach curation.

## Proposed caller contract

The main seam remains ordinary sessions, not a new playlist-edit session type.

1. `POST /sessions` accepts optional
   `playlistSeed: { playlistId: UUID, excludeSourceTracks?: boolean }` alongside
   `prompt`. Existing callers are unchanged. Validate ownership and usability
   before spending an LLM call or persisting a new session; create the session
   and seed selection atomically.
2. `PUT /sessions/:id/playlist-seed` selects/replaces/clears inspiration, with
   `{ playlistId: UUID | null, excludeSourceTracks?: boolean, expectedRevision }`.
   This changes context only, never the mix or provider playlist. Return the
   authoritative seed state and revision. A stale revision returns 409.
3. `GET /sessions/:id` includes the seed state and honest availability/coverage.
   Missing, foreign and malformed identifiers use fixed errors without leaking
   another listener's playlist names or existence.
4. The DJ gets a bounded playlist-name lookup tool and a selection tool using
   the same store as the HTTP callers. The selection tool only acts on an
   explicit request. Duplicate exact names and uncertain matches require a
   clarifying question; never choose the first result silently. An explicit
   clear removes inspiration without regenerating the current mix.

Name lookup searches only active playlists belonging to this listener. Start
with normalized exact-name matches and literal case-insensitive substring
suggestions, capped at five plus a `hasMore` flag. No fuzzy track matching or
cross-user search. This is deliberately narrower than automatic fuzzy playlist
selection in the parent sketch: suggestions assist clarification, not guessing.

## Durable selection, live profile

Persist only the selected internal playlist reference, exclusion preference,
and revision in a session-owned record. Do not copy an entire private playlist
or its embeddings into session storage. The session/user relationship is
authoritative; selection validates both session and playlist ownership.

The musical profile comes from the latest fully published sync, loaded once per
turn. Follow-ups use that published version, not half-uploaded staging rows.
Include the sync/fingerprint reference and coverage in returned context so an
updated source is not presented as the old snapshot. A source update does not
automatically regenerate an existing mix.

If the source becomes unavailable, do not silently fall back to an unrelated
mix or forget its exclusion rule. Preserve the current mix and ask the listener
to choose another source or clear inspiration before generation/swap/extend.
Routine edits such as removing/reordering existing mix tracks can still work.
Source/account deletion must not retain a hidden private profile copy.

The session selection is migration 0024, after the export task's migrations
0022–0023.
Index relationship lookups and keep validation/writes short. Never hold a
database transaction open around embedding, curation, or provider calls.

## Musical profile and ranking

Use only exactly resolved canonical tracks. Deduplicate by recording (ISRC,
falling back to internal track ID), so repeated playlist entries do not amplify
influence. Unresolved/local entries remain visible in coverage but do not turn
snapshot titles into guessed catalog identities.

Aggregate available meaning embeddings, measured tempo/energy, era, genre and
artist information. A useful profile requires three resolved recordings. The
profile deterministically samples at most 200 recording identities, with at
most five per normalized artist; source exclusion still reads the full resolved
recording set. Missing axes score at neutral 0.5. The seed contributes 0.15 to
the convex score: meaning 0.45, tempo 0.20, energy 0.15, artist 0.10, genre
0.05 and center-year 0.05. The learned-taste and confirmed-playlist weights
remain 0.12 and 0.10; the earlier base terms preserve their proportions.
Do not transfer thousands of embeddings into the Worker or dump the full
playlist into a model prompt. Minimum useful profile coverage and sample caps
must be pinned in the implementation plan before the ranking task begins.

The seed influences candidate ranking before the pool's final size limit, not
only after prompt-only ranking has already discarded useful candidates. Keep
ordinary unseeded scores unchanged. Add a bounded seed-fit contribution whose
initial weight and missing-axis treatment are structural-test-pinned; preserve
the locked learned-taste and confirmed-playlist weights. Prompt-derived hard
filters run before seed ranking; no seed-driven filter widening.

The conversation and nested curation call receive the same compact profile and
coverage notice at USER altitude only. Playlist names, descriptions, genres,
artists and sample titles pass through `sanitizeForPrompt`. None are system
instructions. No lyric text is stored or exposed.

When exclusion is requested, filter every resolved source recording, including exact
canonical identities outside the profile sample and their ISRC siblings. Do
not claim exclusion is complete when unresolved entries lack usable identity;
return that coverage limitation. Never backfill excluded recordings just to
meet the requested mix length.

## Race and failure contract

- A seed selection revision fences generation and replacement commits. A slow
  curation based on an earlier selection must not overwrite a mix after the
  listener changes/clears its inspiration.
- Read one consistent published source/profile per turn. Check source activity
  and relevant version/fingerprint again before committing generated picks;
  retry within existing bounds or return a conflict with the mix untouched.
- Apply that protection to generate, swap and extend, including conflict retry.
  Do not introduce network work under queue-store transaction locks.
- Empty/unusable playlists, missing source, insufficient candidates and upstream
  LLM failures are distinct fixed outcomes. Never claim a playlist-shaped mix
  when no usable musical evidence was available.

## Scope boundaries

In: server selection/read contract, conversational name clarification, profile,
ranking, source exclusion, follow-up behavior, tests and documentation.

Out: browse UI or seed controls on iOS/web, origin confirmation UI, catalog
discovery, playlist-only candidate admission, Spotify cross-linking/enrichment,
provider writes, playlist edit drafts/apply, deploy, device or private-library
probes. UI integration uses the approved contract in a later coordinated task.

## Acceptance

- Own playlist selection works by ID and through a disambiguated name request;
  foreign or unavailable playlists cannot leak into context or ranking.
- The chosen seed survives restart and follow-up; replace/clear has explicit,
  revision-checked semantics and does not itself edit a queue.
- Known matched profile shapes affect ranking before truncation; duplicate
  entries/artists cannot dominate. Missing enrichment is honestly represented.
- Prompt constraints and source exclusions win, including cross-platform ISRC
  siblings; ordinary nonseeded behavior and corpus gates remain unchanged.
- Context reaches conversation and curation only as sanitized user data.
- Sync/source-deletion/selection races preserve the queue or return a conflict,
  and no provider playlist is changed by any path.

## Local verification

Focused session/DJ coverage includes ID selection, name ambiguity, same-turn
selection plus generation, restart/follow-up persistence, unusable source
blocking, pre-limit ranking, full-source exclusion, strict tool-schema parity,
and a source-fingerprint change during delayed replacement curation. Migration
0024 passes Drizzle consistency checks and server type-checking is clean. No
migration, deploy, production read or provider write was performed.
