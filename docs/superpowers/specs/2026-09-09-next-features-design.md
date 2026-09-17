# Mixtape next features — 2026-09-09

Status: scope and visual board approved. Mix history, energy journeys, Apple player/listening feedback, and routine suggestions implemented locally; matching migrations and deployment pending. Remaining slices are planned.

## Accepted scope

Implement mix version history, richer energy journeys, observable playback feedback,
anticipatory mixes, Apple deeper-history import, private blends and opt-in taste twins.
The founder confirms account creation, import/sync, mix creation, playback and playlist
creation already work. Preserve these flows. Editing an existing saved playlist is
excluded; restoring a mix changes only that session and never a saved playlist.

Approved recommendations: play inside Mixtape where Apple Music supports it and keep
the existing handoff available. Spotify continues with export/manual refresh and output
handoff; do not imply observable Spotify playback. Taste-twin discovery is off until
explicitly enabled; blends are private and invite-only. Never expose raw libraries,
listening timestamps, private prompts or DJ memories to another listener.

## Current foundations and corrections

- `server/src/dj/queue-store.ts`: replaceQueue deletes active rows, while applyOps bumps
  the queue version. Historical message chips are not recoverable snapshots.
- `server/src/dj/curate.ts` already instructs rising/falling/steady/arc sequencing;
  `contracts.ts` accepts energyArc. Improve measurement and controls, not a parallel DJ.
- `client/ios/Runner/MusicKitBridge.swift`: native playQueue uses the system player.
  `web/src/musickit/client.ts` already sets the queue, plays and pauses through MusicKit.
- The server accepts apple_media import contracts. Apple archive adapters remain absent.
- Auth-scoped providers, staged imports, bounded taste scoring, enrichment and source
  ownership already exist. Reuse them rather than introducing a second identity model.

## 1. Mix versions

Save immutable ordered snapshots in the same short transaction as every committed mix
mutation, including generation and manual/DJ changes to a mix. Capture current content
before the first new mutation of a legacy session. Preserve title-independent identity,
reasons, pins and occurrence order. Do not fabricate missing pre-upgrade versions.
List/read/restore require owner auth. Restore checks the expected current version under
the session lock and creates a new version; it never rewinds a counter or rewrites a
saved playlist. Restoring must not manufacture listening/taste feedback. Retry uses an
idempotency key, including unknown-success recovery. Account deletion removes snapshots.
Acceptance: A→B→restore A creates C; concurrent edits and lost responses do not overwrite
or double-restore; snapshot writes roll back with failed mutations; foreign owners denied.

## 2. Energy journeys

Retain existing rise/fall/steady/arc intent. Offer plain-language presets in the composer,
with conversation still authoritative for explicit revisions. Persist the chosen intent
and evaluated journey on the mix version. Rank and sequence only eligible candidates;
exclusions, distinct recordings and pins win over the shape. Unknown energy is unknown,
not zero. Measure coarse opening/middle/ending groups with sufficient feature coverage;
show limited confidence instead of a fake precise curve. Validate deterministic structural
properties and a curated golden set. Sonnet stays the curation model. No Opus escalation
without observed quality evidence. Changing a preset proposes a new mix version, never
silently mutates a playing queue or saved playlist.

## 3. Player and feedback

Add an app-owned native MusicKit player; extend the existing web player with state,
transport, progress and event observation. Keep native Send to Music as an explicit
alternative. Subscription/authorization/unavailable-track errors preserve the mix.
Queue changes/restores do not replace an active playback session without explicit Play.
Use platform callbacks and monotonic played-time accumulation, not a wall-clock guess.
Seeking is not listening; buffering, calls and unknown interruption are not dislikes.
Deduplicate events using account + playback session + occurrence + sequence identity.
Capture the played mix version, track and source so late events cannot attach to a new
queue/account. Bound an on-device retry outbox; clear it on sign-out or opt-out. Do not
write per-second progress to the server. Learn from bounded patterns of intentional
skips, observed substantial listens and intentional repeats; define thresholds in tests
before enabling scoring. Imports and observed events must not double-count the same
history. Missing background coverage remains unknown. Include a learning on/off control
and deletion of learned playback evidence; maintain explicit preferences independently.
Acceptance includes calls, headphones, lock screen, background/resume, external controls,
network loss, seek/repeat, logout, stale queue, duplicate retry, unavailable songs and
MusicKit authorization loss. Device coverage is required for new player behavior only.

## 4. Suggestions

Generate bounded, explainable suggestions from repeated session patterns in the listener's
time zone, never one sensitive prompt. Proposed initial threshold: three qualifying
sessions on distinct days across two weeks; tune from evidence. No predictions before
sufficient evidence. Suggest a brief on Home; user explicitly requests a mix, with no
auto-play, auto-save, background LLM generation or notifications. Dismissal suppresses the
same suggestion for a bounded interval; global off persists. Changes in time zone,
insufficient evidence, account transitions and stale source availability are tested.

## 5. Apple deeper history

Primary path remains live Apple sync; Go deeper offers Apple's own Data & Privacy export.
Parse locally, web first then native with the same fixtures. Stream bounded CSV/JSON and
handle nested stored/deflated ZIP members using temporary disk where needed. Never send
the source archive, payment/identity files or raw rows to the backend. Explicitly allowlist
music files and cap compressed/expanded sizes, row counts and paths. Verify actual Apple
layout and track-ID semantics with a representative archive before claiming real-data
acceptance; no fuzzy title match becomes a catalog identity. Review counts, dates and
unresolved entries; partial history is honest. Stage through existing import protocols;
repeats are idempotent and cannot remove live Apple memberships or fabricate days.
Cancel disposes buffers/temp files. Test nested/multipart archives and a generated 1GB
stress case with a memory budget; malformed or ambiguous IDs remain unresolved.

## 6. Social taste

Taste twins require explicit separate discovery consent and enough listening evidence.
User previews a chosen display name and broad taste summary. Compare normalized,
confidence-aware aggregate taste representations. Avoid meaningless numeric match
percentages and fabricated matches for a small population. Raw source memberships,
private sessions, timestamps and memories stay inaccessible. Disabling discovery removes
visibility immediately, including cached results. Block prevents discovery/invites in both
directions. Report requires a durable abuse-review process before public discovery ships;
private invitations can release separately while that process is established.

Blends use revocable, expiring, high-entropy invitations, authenticated explicit acceptance,
and bounded group size (proposed first release: 2–6 listeners). Show exactly the identity
and taste summary shared before join. Each participant may leave; owner may end the blend.
Recheck membership/consent revisions at generation and before publication. A participant
leaving invalidates stale generation. Already created personal copies are not remotely
rewritten; they contain output tracks, never source transcripts or private histories.
Balance per-person contribution rather than letting the largest library dominate. Apply
hard exclusions and source/catalog availability, dedupe recordings, and label unavailable
playback honestly. No synchronized listening party, contacts upload, public feed or
existing-playlist edits. Sharing controls copy links only; the app sends no unsolicited
messages. Tests cover owner/member/nonmember access, brute-force limits, revoked tokens,
leave/block/report, opt-out caches, sparse/no-common pools and stale async publication.

## Delivery and approvals

Board: `docs/mockups/2026-09-09-next-features-states.html`. Light/dark web and native,
320–1240px, 200% text, short screens and reduced-motion reading. Compact controls with
44px web / 48px native targets; no decorative left border. Appearance approval is separate
from the already approved feature scope. Shared checkout holds unrelated concurrent work;
use isolated scoped code work and preserve it. No deployment from a dirty working tree.
Each feature uses red-first domain/route and widget/provider tests, then an adversarial
review and fix round. Existing proven core flows are preserved as regression coverage,
not reclassified as unknown. Production release requires the exact candidate and evidence.

## References

- https://developer.apple.com/documentation/musickit/applicationmusicplayer
- https://developer.apple.com/musickit/
- https://support.apple.com/en-us/102283

Open operator inputs: representative Apple export, new playback device acceptance,
and a staffed report-handling path before public discovery. They do not block local
fixtures, implementation or private invitation work. Initial thresholds/caps above are
proposed implementation defaults, not claims about shipped behavior.

## Board verification

Rendered 58 states in eight configurations (464 checks): web 1240 light/dark,
web 768 light, web 320 dark with 200% text; native 390 light, native 768 dark,
native 320 light/dark with 200% text. No horizontal preview overflow or undersized
visible button targets. Short-screen mode used in the six additional configurations
and native large-text pass. Desktop history, native large-text player, consent and
energy screens visually inspected. Discovery enable is disabled before consent and
enabled after selecting it. This verifies the review artifact, not product code.
