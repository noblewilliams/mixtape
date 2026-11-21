# Durable mix turns and mix-ready notifications: plan

**Status:** draft 2026-11-22, awaiting the founder's go.

- Spec: `../specs/2026-11-21-durable-mix-turns-design.md`. Its decisions
  were answered on 2026-11-21, and gate 0 passed on 2026-11-22.
- Approved pop-up: `../../mockups/approved/2026-11-21-push-permission-modal.md`
  (board r3).

**Cadence:** house style.

- Each task goes to a fresh implementer agent on Opus, with red-first
  tests.
- Then a reviewer pass (Opus) and one fix round.
- Then one commit per task, with files staged by explicit path and a
  one-line message without attribution.
- At most two agents in flight.

**Order.** There are three tracks, which meet at G (rollout).

```
Server  S1 → S2 → S3 → S4 → S5 ──→ S6 → S7
iOS               C1 (after S5's wire is fixed in tests) → C2 → C3 → C4
Web               W1 (beside C1) → W2 (after S7)
```

- S1 to S5 are strictly sequential: each builds on the last one's files.
- Clients only need the wire contract in the spec, so C1 and W1 can start
  against fakes once S5's route tests pin the bytes. Their real-server
  checks wait for G stage 2.
- Mobile first: C-tasks take the second agent slot over W-tasks when both
  are ready.

## Before starting

- **The parallel quick fix** (iOS background task, local "Your mix is ready"
  notification, shorter loading copy) is in flight in another session. It
  touches `dj_api.dart`/`dj_providers.dart`, a local-notification service,
  and the loading copy.
  - C1, C2 and C3 start only once it is committed and merged into this
    branch's base, so they build on it rather than beside it.
  - Never stage another session's hunks.
  - The hand-over note in the shared notes folder
    (`durable-mix-turns.md`) tells it what to keep compatible.
- **Founder actions**, needed before the stage in brackets. None blocks S1
  to S5.
  - [S6 secrets, G4]: create an APNs key (Certificates, Identifiers &
    Profiles → Keys → new key with Apple Push Notifications service). Send
    its Key ID, and set `APNS_PRIVATE_KEY` with `wrangler secret put`
    yourself. Never paste the `.p8` into chat.
  - [C2]: turn on the Push Notifications capability for the App ID
    (`APPLE_BUNDLE_ID`), and confirm the Apple Developer account is active.
    The backlog records a lapsed App Store Connect access error on
    2026-11-20.
  - [S7 secrets]: the VAPID key pair. A script in S7 prints one locally.
    The founder sets `VAPID_PRIVATE_KEY` as a secret. The public key and
    subject are vars.
- **Migrations.** S1 adds `0055_…`. Production migrations run from a clean
  worktree of committed HEAD, with the founder's go, before the deploy that
  needs them (G1).
- **Deploys.** Every deploy goes from a clean `git worktree` of current
  `origin/main` HEAD after re-checking recent deployments (CLAUDE.md, and
  the deploy-race lesson). None happens inside a task: only at G, with the
  founder's go.
- **Formatting.** Format only the files a task touched, never a folder.

## Server tasks

**S1. Schema** (`server/src/db/schema.ts`, `server/drizzle/0055_*.sql`,
tests).
- `dj_turns`, `push_devices`, `apns_provider_tokens`, and
  `dj_sessions.current_turn_id`, exactly as in the spec ("Turn records",
  "Device registration", "APNs from Workers"). This includes the
  `unique (provider, token)`, the partial index on queued and running
  turns, the cascades, and `on delete set null` for `current_turn_id`.
- A check constraint on each enum-like text column, as `dj_sessions_kind`
  does.
- Tests (pglite):
  - The migration applies on top of 0054.
  - A session delete cascades its turns.
  - A user delete cascades devices and turns.
  - A duplicate `(provider, token)` is refused.
  - Deleting a turn nulls `current_turn_id`.

**S2. A turn that can be resumed** (`server/src/dj/loop.ts`,
`server/src/dj/turn-stop.ts`, `server/src/routes/sessions.ts`, tests).
This is a refactor with no behaviour change.
- Move the listener's message insert out of `runClaimedTurn`. The routes
  insert it, and `runDjTurn` takes `userMessageSeq`. Both routes still
  insert before the turn, so persist-first holds.
- Add an optional `recordWrites(writes)` hook on `DjTurnOptions`. It is
  called each time `TurnWrites` changes: message seq, rename, pill claim,
  plus `startingVersion` and the claim's title and notPersonal.
- `rollbackTurn` accepts writes loaded from storage, not only the
  in-memory object, and has a mode that **keeps** the listener's message
  (for a re-run) besides today's stop mode.
- Tests:
  - All existing loop, route and stop tests pass unchanged.
  - The hook fires with the right shape after each write.
  - A rollback from persisted writes undoes a rename, a queue version and
    a pill claim, and keeps the user message.

**S3. The turn job, platform-free** (new `server/src/dj/turn-job.ts`,
`server/src/index.ts` → `buildTurnDeps`, tests).
- Extract `buildTurnDeps(env, db)` from `buildRequestApp` (DJ deps, fill
  deps, MusicKit), so the request path and the job wire the DJ identically.
- `runTurnJob(env, job, io)`, where `io` is `{ db, deps, watchers, now,
  setTimer }`. It follows the spec's "Run (object side)" pseudo-code:
  - Claim the attempt with a conditional UPDATE (`attempt += 1`,
    `MAX_ATTEMPTS = 2`). On attempt 2, roll back first (S2).
  - Send a heartbeat every 15 s.
  - Stamp `step`/`step_at` on each step (names never stored).
  - Finish exactly once (`done`/`failed`/`stopped`, `error_kind` a code).
  - Catch everything; never rethrow.
  - Return what notify needs: status, title, `watched_result`.
- It builds the `result`/`error` body with the same builders the routes use
  today (`createMixTurn`/`mixMessageTurn` bodies), so they cannot drift.
- Tests (fake LLM, in-memory watchers, fake clock):
  - Success gives `done`, with the same body as today's route.
  - A `DjError` gives `failed`, with the same status and body.
  - A thrown error is caught, gives `failed('internal')`, and does not
    rethrow.
  - A duplicate run after finish does nothing.
  - Attempt 2 rolls back attempt 1's persisted writes, then runs clean.
  - Attempt 3 is refused as `lost`.
  - A stop gives `stopped`.
  - The heartbeat ticks on the fake clock.
  - The step stamp carries no names.
  - A deleted session ends quietly.

**S4. The Durable Object** (new `server/src/dj/turn-runner.ts`, exported
from `src/index.ts`; `server/wrangler.jsonc`; `routes/turn-stream.ts`
framing; tests).
- `TurnRunner` is a thin class: `start(job)`, `alarm()`, `fetch('/watch')`.
  It holds the job in its storage until finished.
  - `start` answers `busy` while an unfinished job exists, and otherwise
    stores the job and sets the alarm for now.
  - `alarm()` opens a pool with `buildDb`, runs `runTurnJob`, and ends the
    pool in a `finally`.
  - Watchers are a set of writers. A failed write removes one (gate 0
    showed this happens about 1 s after a drop).
- Move the SSE framing and keepalive out of `streamTurn` into a small
  `TurnStreamWriter`, used by both the old in-request path and the object.
  The bytes are unchanged, plus the new `turn` event after `session`.
- Attaching mid-turn writes the latest step first. Attaching after the end
  answers 204.
- wrangler: the `durable_objects` binding `TURN_RUNNER`, migration
  `{ tag: "v1", new_sqlite_classes: ["TurnRunner"] }`, and the vars
  `DURABLE_TURNS: "off"` and `TURN_PUSH: "off"`.
  - `DURABLE_TURNS=on` without the binding throws at wiring, like
    `buildShares`.
  - Document the binding and both vars in the config comments.
- Tests (Node, a fake storage and alarm shell; no workers pool, per founder
  answer 5):
  - Start → alarm → result to two watchers.
  - Busy refusal.
  - A watcher dropping mid-turn doesn't affect the turn.
  - Attach mid-turn and after the end.
  - The framing bytes equal today's `streamTurn` bytes for the same turn.

**S5. Routes over the object** (`server/src/routes/sessions.ts`, new
`routes/turns.ts`, `server/src/enrich/scheduled.ts`, tests).
- Behind `DURABLE_TURNS=on`. With it off, every path is today's.
- On `POST /sessions` and `/:id/messages`:
  - Keep every pre-turn refusal in today's order.
  - `Idempotency-Key`: a UUID v4, owned by the caller. Another user's key
    is a 400, and a replay attaches.
  - Persist-first in one transaction: the session (create), the user
    message, the `dj_turns` row (`queued`) and `current_turn_id`.
  - Then `stub.start`. `busy` answers today's 409 conflict body.
  - A stream request returns `stub.fetch('/watch')`. A JSON request reads
    that same stream to its end and answers with `c.json`.
- `GET /sessions/:id/turn/stream` (attach, owner only).
- `POST /sessions/:id/turn/:turnId/seen` gives a 204, sets `seen_at`, and
  is idempotent.
- The `turn: { id, status, step }` field on `GET /sessions` rows and
  `GET /sessions/:id` while a turn is queued or running. A lost turn
  (heartbeat over 90 s old) reads as omitted.
- Album sessions stay on today's in-request path.
- Stop-a-turn is unchanged. Confirm it in a test across the object path.
- The maintenance cron marks lost turns `failed('lost')` and calls notify
  (a no-op until S6).
- Tests:
  - Flag off: the whole existing suite is untouched.
  - Flag on:
    - Every refusal keeps its status.
    - Stream bytes equal today's bytes plus `turn`.
    - JSON equals today's body.
    - An idempotent replay attaches.
    - A foreign key gives a 400.
    - Busy gives a 409.
    - Attach and 204.
    - `seen`.
    - The list and detail `turn` field.
    - The lost-turn sweep.
    - A stop mid-turn.
- **Docs:** add a `docs/decisions.md` entry, "Mix turns run off the request
  in a Durable Object per session", in this task's commit.

**S6. Devices and Apple push** (new `routes/push-devices.ts`, new
`server/src/push/` with `apns.ts`, `provider-token.ts`, `notify.ts`,
`copy.ts`; `auth/link-anonymous.ts`; tests).
- `PUT /push/devices` and `DELETE /push/devices/:token` per the spec, with
  validation (APNs: 64 to 200 hex characters). Upsert moves the row to the
  caller.
- `linkAnonymousAccount` moves `push_devices` too.
- The provider token is shared through `apns_provider_tokens`: reuse it
  under 40 minutes, refresh with a conditional UPDATE, and the loser
  re-reads. It is an ES256 JWT signed with `jose`.
- `sendApns(device, payload)` sets the spec's headers (`apns-collapse-id =
  turnId`) and handles responses:
  - 410 or 400 bad token: disable the device.
  - 403 `ExpiredProviderToken`: re-sign once.
  - 429 or 5xx: give up.
  - Logs carry `{ event: 'turn_push', outcome, status, reason }` only.
- `notify(turn)`:
  - Stopped: nothing.
  - No watcher was written the result: push now.
  - A watcher was written the result: a second alarm 8 s later, which
    pushes unless `seen`.
  - It fans out to every live device of the user, and `seen` from any one
    suppresses all of them.
  - It records `notified_at` and `notify_outcome`.
- Copy (`copy.ts`):
  - Ready: "Your mix is ready" over the mix title, cleaned with
    `sanitizeTitleText(·, 40)`, or "Tap to play it." if the title is empty.
  - Failed: the spec's three "Oops" lines, picked by the turn's seed.
- The `turn` event's `push` flag is true when `TURN_PUSH=on` and the user
  has a live device.
- `TURN_PUSH=on` without `APNS_KEY_ID` and `APNS_PRIVATE_KEY` throws at
  wiring.
- Tests:
  - Device routes, the ownership move and the anonymous link.
  - Token reuse, refresh and a race with one winner.
  - Each APNs response branch, against a fake fetch.
  - Every notify branch, on a fake clock.
  - A payload snapshot shows no prompt or reply text.
  - The copy seed and the empty-title fallback.

**S7. Web push** (`server/src/push/webpush.ts`, `/health` VAPID key,
`scripts/vapid-keys.ts`, tests).
- RFC 8291 `aes128gcm` encryption and a VAPID JWT (ES256, `aud` = the
  endpoint's origin, `exp` ≤ 24 h), cached per origin for about 12 h, all on
  WebCrypto. Prefer a small WebCrypto library if the review finds one that
  is maintained and has no Node dependency. Otherwise hand-roll it.
- `push_devices.provider = 'webpush'` rows carry `keys`, and `notify` fans
  out to them. On 404 or 410, disable the device. On 413, 429 or 5xx, give
  up.
- `/health` serves `vapidPublicKey` when `TURN_PUSH=on`.
- `TURN_PUSH=on` without the VAPID keys throws at wiring.
- Tests:
  - The RFC 8291 appendix test vectors.
  - The JWT's claims.
  - Each response branch.
  - Fan-out across an APNs and a web device with one `seen`.

## iOS tasks

**C1. Data layer** (`client/lib/data/dj/dj_api.dart`, `turn_stream.dart`,
`dj_models.dart`, `presentation/providers/dj_providers.dart`,
`mix_activity_provider.dart`, tests).
- Every mix-turn POST sends a fresh `Idempotency-Key`, kept with the
  pending turn. A drop before the stream opened retries once with the same
  key.
- Parse the `turn` event (`TurnStarted { turnId, push }`). It rides on
  `ChatState` and the pending mix.
- `attachTurn(sessionId)` opens `GET /sessions/:id/turn/stream` through the
  same parser. A 204 means re-read the session.
- `DjSession.turn` (`{ id, status, step }`) is parsed from list and detail.
- `seen`: sent when a result lands with the mix on screen in the
  foreground, and when the app reopens onto a turn that finished meanwhile.
- **The quick-fix rule, revised.** At the result, if the app is in the
  background, post the local notification **unless** `push` was true.
  Against an old server (no `turn` event), behave exactly as the quick fix
  built.
- Tests:
  - The `turn` event, and an unknown event ignored.
  - Idempotency reused on a drop retry.
  - Attach resumes the step.
  - 204 re-reads.
  - `seen` sent once.
  - The local-notification rule both ways.
  - The `turn` field parsed.

**C2. Native push** (`client/ios/Runner/` AppDelegate, a new
`PushChannel.swift` with pbxproj target membership,
`Runner.entitlements`, new `client/lib/data/push/push_service.dart`,
tests).
- Add the `aps-environment` entitlement (development for debug,
  production for release) and the `mixtape/push` method channel:
  - `status` reports notDetermined, authorized or denied.
  - `requestAuthorization` asks for alert, sound and badge.
  - `register` gets the token back as hex.
  - A tap sends `{ sessionId, turnId, kind }` to Dart.
- **Chain, don't replace, the `UNUserNotificationCenter` delegate** that
  `flutter_local_notifications` installs. Forward what isn't ours, and hide
  a foreground push for the mix on screen. This is the riskiest piece: the
  reviewer checks it on a device that both the Spotify reminder tap and a
  push tap still route.
- `PushService`:
  - On launch with permission, `PUT /push/devices` with environment and
    app version.
  - At sign-out, `DELETE` before the bearer is dropped.
  - A user-scoped provider: it `ref.watch(authProvider)`s (CLAUDE.md rule).
- Tap routing: cold and warm start open the mix through the Mixes route. A
  `failed` kind puts the listener's words back in the composer.
- **This needs a new binary** (TestFlight). Shorebird cannot ship it.
- Tests:
  - `PushService` over a fake channel: register on launch, delete on
    sign-out, reset on auth change.
  - Tap routing for ready and failed.

**C3. The approved pop-up** (new
`widgets/foundation/mixtape_popup.dart`, new
`widgets/push_permission_popup.dart`, `first_run/making_screen.dart`,
`chat_screen.dart`, `home_screen.dart`, `tabs/you_tab.dart`, tests).
- Build exactly board r3 (the approval record lists every locked value):
  - `MixtapePopup`: centred, inset 22 pt, 30 pt corners, a 16 pt blur and a
    tint behind, tap outside to close, a 200 ms fade and scale (fade only
    with reduced motion).
  - The I1 art at 108 pt: hubs turning, the notification rising every
    3.2 s, static with reduced motion, and excluded from semantics.
  - Centred type: an 18 pt title, the body in smoke, a 50 pt paper pill
    and "Not now".
  - At 200% text: the cassette alone, and the pop-up scrolls.
- The triggers and the once rule (`push_ask_shown`, set on appear) follow
  the record:
  - About 3 s into the first prompt (Making, or the chat working state).
  - Home after sign-up.
  - An existing listener, once on Home.
  - Never stacked on AI consent.
  - Skipped when the OS has already decided.
- After Allow, Making gains the bell line "We'll ping you when it's
  ready."
- The You row "Mix ready notifications": on, off, and "Off in iOS
  Settings" with a link.
- Tests: widget tests for each trigger, the once rule, the OS-decided
  skips, each You state, 200% text, reduced motion, and VoiceOver labels.
  Add a simulator preview state (`MIXTAPE_PREVIEW`) for the device pass.

**C4. Coming back to a running turn** (`mixes_screen.dart`,
`mix_activity_provider.dart`, `chat_screen.dart`, tests).
- On relaunch, a Mixes row whose `turn` is queued or running shows "The
  DJ is on it…" and the working reel, from the server. Today this comes
  only from memory.
- Opening that mix attaches (C1) and resumes the caption. When it ends,
  re-read.
- The 25 s late read stays for old servers.
- Tests: the list from server state, attach on open, and a finished turn
  re-reads.

## Web tasks

**W1. Data and resume** (`web/src/api/client.ts`, `sse.ts`, `App.tsx`,
`Conversation.tsx`, the Mixes list, tests).
- Add the `Idempotency-Key`, the `turn` event, `attachTurn`, and the
  `turn` field on sessions.
- On load, a mix with a running turn attaches, so a reload mid-turn
  resumes the caption. The list shows the running state.
- `seen` when a result lands in a focused tab showing that mix.
- Tests: in the style of the existing `client.stream.test.ts`, plus
  attach-on-load and `seen` tests.

**W2. Web push** (`web/public/sw.js`, new
`web/src/components/PushPermission.tsx`, a blurred-overlay variant of
`ControlModal`, `first-run/Making.tsx`, `Conversation.tsx`, `Home.tsx`,
the settings, tests).
- The pop-up per the approval record's web column.
  - Offer it only where `PushManager` exists.
  - The once rule lives in `localStorage`, wrapped in try/catch.
  - The CTA click calls `Notification.requestPermission()`, then
    `pushManager.subscribe` with the `/health` VAPID key, then
    `PUT /push/devices`.
- `sw.js`:
  - `push` calls `showNotification` with `tag = turnId`, and skips it when
    a focused client shows that mix.
  - `notificationclick` focuses or opens `/app/` on the mix.
  - It still never touches API or auth requests.
- A settings row for mix-ready notifications.
- Tests:
  - The component: the once rule, the absent-`PushManager` case, and a
    denied permission.
  - The service worker's handlers, in a unit harness.

## G. Rollout (founder's go at each stage)

1. **Migrate and deploy dark.** Run migration 0055, then deploy S1 to S5
   with `DURABLE_TURNS=off` and `TURN_PUSH=off`, from a clean worktree of
   `origin/main`. Smoke it: the suite of today's flows is unchanged.
2. **`DURABLE_TURNS=on`.** Smoke with the founder's go (one model turn
   each):
   - stream
   - JSON
   - a drop then attach
   - a stop
   - a deploy mid-turn

   Watch turn logs for `attempt > 1` and `lost` for a week. Rollback: flip
   it off, and in-flight object turns still finish.
3. **Web** (W1, then W2 once S7 is deployed): it publishes on push.
4. **iOS TestFlight** (C1 to C4). Then the APNs secrets, then
   `TURN_PUSH=on`, then the device pass:
   - Kill the app mid-turn: exactly one push, and its tap opens the mix.
   - Background for 10 s, then foreground: no notification.
   - Background past 30 s: exactly one.
   - A failed turn gives the "Oops" push, and its tap restores the words.
   - The Spotify reminder tap still works.
   - The pop-up at all three triggers, and once only.
   - Desktop Chrome and the installed iOS web app get a web push pass.
5. **Docs.** Update the decisions entry with the as-built notes and close
   the backlog entry. The turn-steps spec's "Not proposed" section points
   to the durable-turns spec.

## Risks to watch in review

- **Delegate chaining on iOS (C2):** two libraries both wanting
  `UNUserNotificationCenter.delegate`.
- **Body drift:** `result`/`error` must come from the same builders as the
  JSON path. S3 and S4 pin this with byte-equality tests.
- **Persisted writes:** a rollback is only as good as what S2 records. Any
  new kind of write a turn makes later must join `TurnWrites`.
- **Free plan vs paid:** Durable Objects with SQLite are on both. Confirm
  the account's Workers plan before G1, because the CPU and subrequest
  limits the turn already relies on are the paid ones.
