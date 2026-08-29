# P3b — DJ Conversation Client Implementation Plan

> Execute task-by-task: fresh implementer per task, reviewer pass + fix round per task (house cadence, see CLAUDE.md). TDD red-first for all Dart logic; widget tests over fake APIs; Swift verified by `flutter build ios --no-codesign` + founder device smoke at the end.

**Goal:** The DJ conversation on the iPhone: sessions-first Home, chat screen with inline queue widget, drag/swipe queue editing, hand-off playback to Apple Music, and save-as-playlist — a pure client build over the deployed P3a API.

**Architecture:** Server-canonical state (no optimistic queue edits in v1): every mutation POSTs and re-renders from the response. One `DjApi` typed client (long-timeout) → Riverpod notifiers (auth-scoped per CLAUDE.md rule) → three screens. Two new bridge methods (SystemMusicPlayer hand-off, playlist creation).

**Working directory:** `~/Documents/work/mixtape` — client work in `client/`. Branch `main`.

## Binding API contract facts (from P3a + its final review — do not re-derive)

- Base: `AppConfig.apiBaseUrl`; bearer auth via existing ApiClient/TokenStore.
- `POST /sessions {prompt}` → `{session:{id,title,status,queueVersion,updatedAt}, messages:[...], queue:[...]}`; DJ errors → **502/409** `{error: kind, message: listener-ready, queue?, queueVersion?}` (message renders verbatim in the transcript as a DJ apology bubble).
- `GET /sessions` → `{sessions:[{id,title,status,queueVersion,updatedAt}]}` newest-first ≤50, INCLUDES archived (client filters).
- `GET /sessions/:id` → `{session, messages (last 200, ascending, roles user/dj), queue}`.
- `POST /sessions/:id/messages {text}` → `{djMessage, queue, queueVersion}`; same error shape.
- `POST /sessions/:id/queue-ops {ops, expectedVersion}` → `{queueVersion, requested, added, removed, queue}`; **409** `{error:'stale', queue, queueVersion}`; manual ops are remove/move ONLY (`{op:'remove',position}`, `{op:'move',from,to}` — 0-based); swap/extend → 400 `{error:'dj_required', message}`.
- `PATCH /sessions/:id {status}` → archive/unarchive.
- **409 rule:** trust the body's queue/queueVersion when present, else refetch `GET /:id`.
- **Two 400 shapes:** zod-default `{success:false,error:{...}}` AND `{error,message}` — parse both, prefer `message`, fall back to a generic string.
- **Failed turns leave a user message with no dj reply** (and a retry can duplicate it) — transcript renders this state plainly (no dedup magic in v1; consecutive identical user bubbles are acceptable).
- **Latency envelope:** turns run 20–40s. DJ endpoints use a 120s timeout (NOT ApiClient's 30s default). Typing indicator throughout; composer disabled while in flight.
- QueueTrack: `{position, trackId, appleId, title, artist, reason, durationMs}` — `appleId` drives playback/playlists; `reason` shows on tap.

---

### Task 1: DJ API layer — models + typed client

**Files:** create `client/lib/data/dj/dj_models.dart`, `client/lib/data/dj/dj_api.dart`; tests `client/test/data/dj_api_test.dart`.

- Models with `fromJson` (and `toJson` only where sent): `DjSession {id,title,status,queueVersion,updatedAt}`, `DjMessage {id,role,content,queueVersion?,createdAt}`, `QueueTrack {position,trackId,appleId,title,artist,reason?,durationMs?}`, `SessionDetail {session,messages,queue}`, `TurnResult {djMessage,queue,queueVersion}`, `QueueOpsResult {queueVersion,requested,added,removed,queue}`.
- `DjApi(ApiClient)` — but DJ calls need `timeout: 120s`: construct with a second long-timeout ApiClient (same TokenStore) or add per-call timeout support; pick the cleaner and keep ApiClient's public surface stable.
- Methods: `createSession(prompt)`, `listSessions()`, `getSession(id)`, `sendMessage(id, text)`, `applyQueueOps(id, ops, expectedVersion)`, `setStatus(id, status)`.
- Error taxonomy: `DjApiException {kind, message, queue?, queueVersion?}` from 502/409 bodies (listener-ready message preserved); `StaleQueueException {queue, queueVersion}` for queue-ops 409; both 400 shapes parsed into a plain message. NetworkException/ApiException pass through from ApiClient semantics where unhandled.
- Ops builders: `QueueOp.remove(position)`, `QueueOp.move(from,to)` — 0-based, documented.
- Tests (MockClient): each method's URL/verb/body; 502 with message+queue → DjApiException carrying both; queue-ops 409 → StaleQueueException with fresh queue; both 400 shapes → readable message; timeout config asserted (a 40s-delayed mock with the DJ client does NOT throw — use small configured numbers to keep the test fast, e.g. djTimeout 500ms vs mock 200ms and inverse).
- Commit `feat(client): dj api layer`.

### Task 2: Providers — sessions list + chat state machine

**Files:** create `client/lib/presentation/providers/dj_providers.dart`; tests `client/test/presentation/providers/dj_providers_test.dart`.

- `djApiProvider` (over apiClientProvider's token store), auth-scoped rule applies to all stateful providers below (`ref.watch(authProvider)` in build).
- `sessionsProvider` — AsyncNotifier<List<DjSession>>: loads on build, `refresh()`, client-side filter helper for archived; `archive(id)`/`unarchive(id)` call setStatus then refresh.
- `ChatState { SessionDetail detail; bool sending; String? transientError }` + `chatProvider = AsyncNotifierProvider.family<ChatNotifier, ChatState, String sessionId>`: build → getSession; `send(text)`: append the user's bubble locally (server persists it regardless of outcome), sending=true → sendMessage → on success append djMessage + replace queue/version; on DjApiException append an error bubble (role dj, its listener-ready message, flagged `isError: true` in a local wrapper type) + adopt attached queue when present; on 409-kind ditto; sending=false.
- `applyOps(ops)`: server-canonical — call with current queueVersion; success → replace queue+version; StaleQueueException → replace from body + set transientError 'queue was updated — showing the latest'; DjApiException('dj_required') → transientError with its message.
- New-session flow: `startSession(prompt)` on a `sessionStarterProvider` (plain async provider fn) returning the sessionId; error → rethrow DjApiException for the Home screen to render (it may carry sessionId for a created-but-failed session — surface via exception field if the body includes it).
- Tests (fake DjApi injected): initial load; send happy path (bubbles ordered user→dj, queue replaced); send failure (user bubble persists + error bubble with the server's message + queue adopted from exception); ops success; ops stale (queue replaced, transientError set); archived filter; auth transition resets (container with authProvider override flipped → state rebuilds).
- Commit `feat(client): dj session providers`.

### Task 3: Bridge — hand-off playback + playlist creation

**Files:** modify `client/ios/Runner/MusicKitBridge.swift`, `client/lib/data/musickit/musickit_bridge.dart`; tests extend `client/test/data/musickit_bridge_test.dart`.

- Swift channel methods:
  - `playQueue {appleIds: [String]}` → `MPMusicPlayerController.systemMusicPlayer`: `setQueue(with: ids)` + `prepareToPlay`/`play()`; result true on dispatch. Comment: hand-off — playback lives in the Music app and survives our app closing. Main-thread hop as elsewhere.
  - `createPlaylist {name: String, appleIds: [String]}` → `MPMediaLibrary.default().getPlaylist(with: UUID(), creationMetadata: MPMediaPlaylistCreationMetadata(name: name))` then sequential `addItem(withProductID:)` per id; returns `{added: Int, failed: Int}` (per-item failures counted, not fatal). Requires the existing NSAppleMusicUsageDescription (already present).
- Dart seam: `playQueue(List<String> appleIds) → bool`, `createPlaylist(String name, List<String> appleIds) → ({int added, int failed})`; MusicKitException wrapping per the established pattern; empty-list guard → MusicKitException before the channel call.
- Tests: channel payload shapes both directions, PlatformException → MusicKitException, empty-list guard.
- `flutter build ios --no-codesign` must pass (Swift compiles).
- Commit `feat(client): playback hand-off + playlist bridge`.

### Task 4: Chat screen + queue widget

**Files:** create `client/lib/presentation/screens/chat_screen.dart`, `client/lib/presentation/widgets/queue_card.dart`; tests `client/test/screens/chat_screen_test.dart`.

- ChatScreen(sessionId): transcript (ListView, newest at bottom, auto-scroll on new message), bubbles: user right-aligned, dj left with a subtle DJ accent, error bubbles in the dj column with a muted/error tint rendering the server's listener-ready message verbatim + a small retry affordance (retry = resend last user text). Typing indicator row while sending (three-dot shimmer, "the DJ is listening…" after 10s). Composer: text field + send, disabled while sending, 2000-char cap matching the API.
- QueueCard (inline, rendered under any dj message whose queueVersion != null AND == current version — i.e. ONE live card at the latest queue-bearing message; older queue-bearing messages show a compact "queue updated · v{n}" chip instead): shows first 3 tracks + "+N more · ~M min" (durationMs sum where known), tap → push QueueScreen.
- Keep styling within the existing Material3 deepPurple theme; this is v1 utility polish, not a redesign.
- Widget tests (fake DjApi via provider overrides): transcript renders roles; send flow shows indicator then dj bubble; error bubble shows server message + user bubble retained; QueueCard appears only on the current-version message and taps navigate (use a NavigatorObserver).
- Commit `feat(client): chat screen + queue card`.

### Task 5: Queue screen — reorder, remove, play, save, reasons

**Files:** create `client/lib/presentation/screens/queue_screen.dart`; tests `client/test/screens/queue_screen_test.dart`.

- QueueScreen(sessionId) watching chatProvider's queue: ReorderableListView of tracks (1-based numbering displayed); drag end → `applyOps([move(from,to)])`; Dismissible per row → `applyOps([remove(position)])`; both against current version (server-canonical refresh from response; on stale → snackbar transientError + rebuilt list).
- Row tap → expands the reason inline (or bottom sheet) — the "why on tap".
- App bar actions: **Play in Apple Music** (bridge.playQueue over the queue's appleIds; success → snackbar 'playing in Apple Music'; MusicKitException → friendly snackbar) and **Save as playlist** (dialog for name, default session title; createPlaylist; report added/failed counts).
- Empty queue → friendly empty state ('ask the DJ for a tape').
- Widget tests: rows render with numbering; dismiss triggers remove op with correct 0-based position + expectedVersion (fake api captures); reorder triggers move op; stale response replaces list + shows snackbar; play button calls bridge with appleIds in order (fake bridge); save dialog flows to createPlaylist with entered name; reason revealed on tap.
- Commit `feat(client): queue screen`.

### Task 6: Home rework — sessions-first

**Files:** modify `client/lib/presentation/screens/home_screen.dart`, `client/lib/main.dart` (routes if needed); tests update `client/test/screens/home_screen_test.dart` + root gate tests.

- Home: prompt field ("What do you want to hear?") + submit → sessionStarter → navigate to ChatScreen (loading state on the field while creating, 120s-tolerant); below: sessions list (title + relative updatedAt; tap → ChatScreen; long-press or trailing menu → archive; archived hidden behind a small toggle). Library sync moves to an AppBar action (sync icon) presenting the existing sync UI in a bottom sheet or secondary screen — the P1 sync tests keep passing with minimal relocation.
- Failed session creation → the DjApiException message inline under the field; if it carries a sessionId, still navigate (session exists with the user message; chat shows the retry affordance).
- Widget tests: prompt submit navigates on success; failure shows message; failure WITH sessionId still navigates; sessions list renders + tap navigates; archive hides from default list; sync still reachable and functional (relocated test).
- Commit `feat(client): sessions-first home`.

### Task 7: Founder device smoke (P3 exit gate)

- `flutter run --dart-define=API_BASE_URL=https://mixtape-api.goalympics.workers.dev` on the iPhone.
- Script: open app → existing sessions visible (incl. the terminal smoke session) → new prompt → queue card appears → open queue → drag reorder → swipe remove → chat "swap track 2 for something older" → verify honest update → **Play in Apple Music** (leaves app, Music plays the tape) → back → **Save as playlist** → verify in the Music app's library → archive a session.
- Record outcomes + any UX friction in docs/decisions.md; update README status to P3 complete.

---

## Out of scope (resist)
- Optimistic UI / offline queue edits · streaming responses · transcript pagination beyond last-200 · in-app player · P2.5 · taste-signal learning (P4) · visual redesign beyond the existing theme
