# P3 — The DJ Conversation: System Design

*Status: approved by founder 2026-08-29 (design conversation) · spec for plan-writing*
*Supersedes the P3/P4 sketch in [the v1 design](2026-08-29-mixtape-v1-design.md) build-phases section — see decisions log.*

## Scope

P3 turns mixtape from plumbing into the product: a **conversation with your DJ** that produces and refines a queue, plays it through Apple Music, and can save it as a playlist. Founder decisions baked in:

- **Full mini-conversation** — refinement happens IN the chat (this pulls the old P4 refinement loop forward). Queue widgets render inline in the conversation.
- **Manual gestures coexist** — drag-to-reorder and swipe-to-remove on the queue view post the same edit ops the DJ uses; the conversation always sees the current state.
- **Playback = hand-off** to the Apple Music app (SystemMusicPlayer). No in-app player in P3.
- **Save as playlist** is in P3 (moved from P4).
- **Per-track "why" on tap**, not inline.
- **Queue length parsed from the prompt** ("2 hours of…", "30 songs"), default ~15 tracks.
- Curation LLM: **Sonnet 5** (`claude-sonnet-5`), escalation lever unchanged (repo CLAUDE.md).
- P4 slims to: taste-signal learning (skips/removals/repeats → smarter queues) + polish.

## Architecture

Two sequenced plans:

### P3a — Engine + API (server only)

**Data model** (new tables; all queue state is server-canonical):

- `dj_sessions` — id, userId, title (derived from first prompt), status(active/archived), createdAt, updatedAt
- `dj_messages` — id, sessionId, role(user/dj), content (text), queueVersion (nullable — set when this message produced/changed the queue), createdAt. DJ tool-call internals are NOT stored, only surfaced text.
- `queue_tracks` — sessionId, position, trackId FK, reason (the "why", shown on tap), state(active/removed), addedBy(dj/user), removedBy nullable. One live queue per session; versions are implicit (queueVersion counter on session).
- Migration also adds the **HNSW index** on `track_meanings.embedding` (cosine) — deferred from P2, needed now.

**The agent loop** (`POST /sessions/:id/messages`, session-authed):

1. Append user message; load session history (bounded window) + current queue state.
2. Run Sonnet 5 with tool definitions:
   - `generate_queue(intent)` — intent: mood/themes text, tempo range, energy arc, era range, explicit allowed, familiarity, target length (parsed count or duration). Executed by the retrieval engine below; replaces the session queue.
   - `edit_queue(ops[])` — ops: remove(position), move(from,to), swap(position, intent-for-replacement), extend(count, intent), replace_range(from,to,intent).
   - Tool results (the resulting queue summary) go back to the model for its conversational reply.
3. Persist DJ message (+ bumped queueVersion when the queue changed); respond with message + full current queue. Non-streaming v1; the client shows a typing indicator.

**The retrieval engine** (code, not LLM, except the final pass):

1. Intent themes → bge-m3 embedding (Workers AI, same model as track meanings).
2. Candidate pool SQL: user's `user_tracks` JOIN features/meanings, hard-filtered (tempo window, era, explicit), scored = w₁·feature-fit + w₂·cosine(meaning, intent) + w₃·log(playCount) familiarity weighting — tracks missing features/meanings still compete on the dimensions they have (coverage is never 100%). Pool ≈ 15× target length, capped ~300.
3. Sonnet curation pass (prompt-cached pool): select + sequence for arc, one-line reason per track. Structural golden-set tests (constraints hold, no dupes, count honored), never exact-track assertions.

**Manual edit endpoint** — `POST /sessions/:id/queue-ops` (same ops schema, addedBy/removedBy=user, no LLM call). Records land in `queue_tracks` so the next conversational turn sees them; removals are the first taste signals (P4 reads them).

**New secret**: `ANTHROPIC_API_KEY`. Cost: ~5–10¢ per session generation + ~1–3¢ per refinement turn (cached pool), per the v1 budget.

### P3b — Conversation UI (client)

- **Home becomes sessions-first**: prompt box ("What do you want to hear?") + session history list (server-backed). Library sync moves to a settings/profile corner.
- **Chat screen**: messages + inline **queue widget** (compact card: first 3–4 tracks + count + total duration; tap → full queue view). Widget always reflects the CURRENT queue (single canonical object), not a snapshot.
- **Queue view**: ReorderableListView (drag) + Dismissible (swipe-remove) posting queue-ops; tap a track → its reason; buttons: **Play in Apple Music** (bridge hand-off) and **Save as playlist**.
- **Bridge additions (Swift)**: `playQueue(appleIds)` via `MPMusicPlayerController.systemMusicPlayer` setQueue(with: storeIDs)+play; `createPlaylist(name, appleIds)` via `MPMediaLibrary.getPlaylist(with:creationMetadata:)`. Both behind the existing MethodChannel + Dart seam; errors → typed MusicKitException.
- Providers follow the auth-scoped rule (repo CLAUDE.md): session state watches authProvider, cancels via onDispose.

## Error handling

- LLM failure/timeout mid-turn → DJ message "lost my train of thought — try again"; queue untouched (tools are transactional: replace-on-success).
- Empty/thin candidate pool → engine widens filters once, and the DJ says so ("stretched beyond your usual here").
- Hand-off failures (no Apple Music sub, denied) → typed errors → friendly copy.
- Token/window growth: history window bounded (last N turns + queue state summary); sessions are cheap to archive.

## Testing

- Engine: golden-set structural tests over seeded PGlite taste graphs (constraint satisfaction, ordering sanity, pool math), fake embedder.
- Agent loop: fake Anthropic client (inject via seam — same DI pattern as EnrichDeps); tests assert tool-call plumbing, queue versioning, persistence — never model quality.
- Client: widget tests over fake session API; bridge Dart seam tests; Swift hand-verified on device (P3 smoke: prompt → queue → tweak in chat → drag/swipe → play in Music app → save playlist).

## Out of scope (P4+)

- Taste-signal learning (the data is being collected from day one; the *learning* is P4)
- Streaming responses, anticipatory sessions, familiarity dial UI, in-app player, web
