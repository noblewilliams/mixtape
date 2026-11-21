# Durable mix turns: the mix always lands, and the listener is told

Date: 2026-11-21. Status: **draft, awaiting the founder** (open decisions at
the end). Spec only; no plan yet.

## Why

A mix turn takes 20 to 50 s, and 159 s was seen on 2026-11-10. It runs on
the request that asked for it (`POST /sessions`,
`POST /sessions/:id/messages`). When the client goes away, the streamed path
hands the turn to `ctx.waitUntil`, which gives it **at most 30 s more**
(turn-steps spec, "Workers facts that decide this"). iOS suspends an app a
few seconds after it goes to the background. So a listener who asks for a
mix and then locks the phone can lose the turn halfway, and nothing tells
them. They come back to their own words with no reply, or a half-made mix.

The turn-steps spec (2026-11-13) set this aside under "Not proposed: run the
turn off the request". Its reopen clause was "turn logs or listener reports
show mixes lost to a closed app". The founder's report on 2026-11-21 meets
it.

A quick fix is being built in parallel in the main session. It has three
parts: an iOS `beginBackgroundTask`, which buys about 30 s more of an open
stream; a local "Your mix is ready" notification when the turn ends while
the app is in the background; and shorter loading copy. That covers turns
that end within about 30 s of backgrounding. This spec covers the rest:
**the turn runs on the server whatever the client does, and the server
tells the listener with a push when it is done.**

## What has to hold

- **A turn that started always ends:** done, failed, or stopped, and never
  half-written and silent. The client being killed, the network dropping or
  a deploy landing mid-turn changes none of that.
- **One turn, one result.** No retry (by the client, the platform or us)
  makes a second mix or a second DJ reply.
- **The wire contract stands.** Old builds (TestFlight 1.0.2 (5)/(6), 1.1.x,
  the live web bundle) post a turn and read JSON or the 2026-11-13 stream,
  byte for byte. New clients keep working against a rolled-back server.
- **Steps still reach a client that is watching**, as they do today. A new
  thing they can do: reach a client that **comes back** to a running turn
  (relaunch, reload, another device).
- **Stop-a-turn (2026-11-15) keeps working** with the same contract.
- **No listener words in logs.** Turn logs stay "counts and codes only". The
  push payload carries no lyric text, ever.
- **Platform-agnostic schema.** Device tokens are keyed by provider and
  platform, with APNs as one row type among future peers.
- **Workers facts** from CLAUDE.md: no NODE_ENV, so every flag and secret is
  checked explicitly and fails fast. Deploys go from a clean worktree of
  committed HEAD.

## Cloudflare facts that decide this

Checked against the Cloudflare docs on 2026-11-21 (Workers Paid):

| | Durable Object (alarm) | Workflows | Queues consumer |
|---|---|---|---|
| Wall clock | Alarm handler: **15 min**. Request/RPC: unlimited while the caller is connected. | Per step: **unlimited**. Instance: no cap. | **15 min** per invocation. |
| CPU | 30 s default, up to 5 min (`limits.cpu_ms`) | 30 s default per step, up to 5 min | 30 s default, up to 5 min |
| Retries | Alarms are **at-least-once**: retried on throw, exponential backoff from 2 s, **up to 6 retries** | Per step, default **5 retries**, 10 s exponential, 10 min timeout. Configurable. `NonRetryableError` stops them. | Whole batch, default **3 retries**. Messages past the limit are dropped or go to a DLQ. |
| Idempotency help | Named object (`idFromName`) gives one instance per key, and its SQLite storage is strongly consistent | `create({ id })` with a caller-chosen id **throws `instance.already_exists`** on a duplicate within retention (7 days default) | None built in |
| Live progress to a client | **Yes.** The object can hold the client's stream (the Worker proxies it) and write steps as they happen. | No streaming API documented. Progress needs a store to poll. | No. Progress needs a store to poll. |
| Status read | Our own (SQLite or Postgres) | `instance.status()` | Our own |
| Pricing | 1M requests/mo included, then $0.15/M. Duration: 400k GB-s/mo included, then $12.50/M GB-s. Billed while active, **including while awaiting I/O**, at 128 MB. | 10M requests and 30M CPU-ms included. 500k steps/mo included, then $0.80/100k. Storage 1 GB-mo. | 1M operations/mo included (about 3 per message), then $0.40/M |
| New infra for us | First DO class, a `migrations` entry | First Workflow class, a `workflows` binding | First queue, producer and consumer bindings |

What these mean for this turn:

- **The turn is one opaque unit.** `runDjTurn` writes as it goes (the
  listener's message, queue versions, the rename, the pill claim) and keeps
  in-memory trackers across a conflict retry. Cutting it into idempotent
  Workflow steps would mean rewriting `loop.ts` (3,900 lines) around
  replayable boundaries. On all three platforms, a platform retry therefore
  re-runs **the whole turn**, and we need our own guard against a second
  result (see "Retries").
- **Neon:** the serverless driver's rule is that a `Pool` is "connected, used
  and closed within a single request handler". An alarm invocation, a
  Workflow step and a queue invocation each count as one handler. The
  per-request pool in `buildDb` (max 2) moves into whichever runs the turn,
  and is ended in a `finally` as `withRequestPool` does today. Hyperdrive is
  not needed and is not proposed (the docs do not cover it from DOs or
  Workflows, and today's direct Neon pool already works).
- **Deploys restart running code.** A deploy mid-turn interrupts whatever
  runs it, on all three, and the platform retries it (alarm retry, step
  retry, message redelivery). We deploy often, so this is the **common**
  retry case, not a rare one. To confirm in the spike (below): exactly what
  a DO alarm sees when a deploy lands during it.
- **Cost does not decide.** All three are effectively free at our volume
  (see "Costs"). The model calls cost a hundred times more than any of them.

## The options

### (A) A Durable Object per session runs the turn on its alarm (recommended)

The Worker authenticates and validates as today, writes the persist-first
rows, then calls the session's object (`TURN_RUNNER.idFromName(sessionId)`):
`start(turn)`. The object stores the turn's input in its SQLite storage,
sets an alarm for now, and returns. The alarm handler opens a Neon pool,
runs `runDjTurn` with an `onStep` that fans out to every watcher, writes
the result, and closes the pool.

A client that wants to watch gets a stream **from the object**. The Worker
calls `stub.fetch('/watch?turn=…')` and returns that response as its own,
so the bytes are exactly today's SSE events. When the client leaves, the
Worker's subrequest is cancelled and the object drops that watcher. The
turn does not notice.

For:

- **The live path stays a stream, with the same bytes.** It needs no poll
  and adds no second channel. Old and new clients see what they see today.
- **Coming back works.** A relaunched app or a reloaded tab can attach to
  the same object and get the current step, then the rest
  (`GET /sessions/:id/turn/stream`). This is the cross-launch state that
  the 2026-11-13 Mixes reopen clause names.
- **One object per session serialises turns** on that session, matching the
  stop-a-turn claim. Two devices cannot race two turns into one mix.
- **Strongly consistent storage beside the runner** for the turn's input
  and attempt count, so a retried alarm knows what it was doing.
- **The alarm's 15-minute wall clock** is about 6 times the worst turn seen.

Against:

- **New infrastructure.** It is the project's first Durable Object: a class
  export, a `migrations` entry, and a binding. The tests have to fake the
  object's surface (see "Tests").
- **Alarm retries are automatic and capped at 6.** We must catch everything
  ourselves and decide re-run or fail (below). Otherwise a turn that throws
  for a real reason would run 7 times.
- **Duration is billed while waiting on the model**, about 5 GB-s per 40 s
  turn. Free up to about 78,000 turns a month (see "Costs").
- **The object runs where it was first created**, near the first caller.
  Today's turn also runs near the caller, so this is no worse. A
  `locationHint` near the Neon region could cut the turn's dozens of DB
  round trips (an open question, not part of this change).

### (B) A Workflow runs the turn; steps are stamped in Postgres and polled

The Worker creates an instance with `id = turnId` (a duplicate throws, which
gives free dedupe of a double post) and answers. The workflow's single
`step.do('turn')` runs `runDjTurn` with a 10-minute timeout and
`retries: { limit: 1 }`. Steps go to a `dj_turns` row, and a watching client
polls it.

For: dedupe on create comes built in, `status()` comes free, the dashboard
shows each instance, and nothing is billed while the turn waits on the
model.

Against: **no live stream.** Every watching client moves from the stream to
a 1.5 to 2 s poll: about 25 Worker requests, auth lookups and Neon reads
per turn, with short steps missed. The turn-steps spec rejected exactly
this as option (b). Keeping today's stream would need a DO anyway, and then
the Workflow adds nothing. Its real strength, durable multi-step replay,
goes unused while the turn is one step.

### (C) A Queue consumer runs the turn; steps polled as in (B)

It has the same polling cost as (B), with less built in: no dedupe, the
`max_batch_timeout` adds latency unless batches are size 1, and a failure
retries the batch. It suits fan-out work (the catalogue seeding, the cron
enrichment), not one listener waiting on one turn.

### Not proposed: keep the turn on the request and extend it

No API extends `waitUntil` past 30 s, and iOS background time ends at about
30 s too. The quick fix gets what is gettable.

## Recommendation: (A)

The deciding fact is the live path. Steps already stream down the open
request, and an object that holds both the turn and its watchers keeps
that path byte for byte. (B) and (C) would trade it for a poll the turn-steps
spec already rejected. All three need our own retry guard, all three cost
about nothing, and (A) is the only one that also answers "what is this
session doing right now" for a client that comes back.

If the founder would rather not run a Durable Object, (B) is the fallback.
It costs the stream and adds a poll, but is otherwise sound.

## Design (A)

### Turn records: a `dj_turns` table

The brief asked for turn state on the session row. Per-turn facts are put
in their own table instead, because two things need one row per turn: the
retry guard and the push. These are the client's idempotency key, the
attempt count, the writes a rollback must undo, and whether the listener
was told. The session row keeps its stop-a-turn claim (`active_turn_id`,
`active_turn_at`, `turn_stop_requested`) unchanged, and gains one pointer.

```
dj_turns
  id               uuid pk            -- the turn id; the client's Idempotency-Key when sent
  session_id       uuid fk dj_sessions on delete cascade
  user_id          text fk user on delete cascade
  kind             text  'create' | 'message' | 'remake'
  status           text  'queued' | 'running' | 'done' | 'failed' | 'stopped'
  step             text null          -- latest TurnStep name only, never its names
  step_at          timestamptz null
  heartbeat_at     timestamptz null   -- bumped every 15 s while running
  attempt          int not null default 0
  error_kind       text null          -- DjError kind or 'internal' / 'lost'; a code, never text
  writes           jsonb null         -- TurnWrites + startingVersion + claim title/notPersonal, for rollback
  watched_result   bool not null default false  -- a live watcher was written the result
  seen_at          timestamptz null   -- a client acknowledged the result on screen
  notified_at      timestamptz null   -- push sent (or skipped: see notify_outcome)
  notify_outcome   text null          -- 'sent' | 'seen' | 'no_device' | 'off' | 'failed'
  created_at, started_at, finished_at timestamptz
  index (session_id, created_at desc), index (status, heartbeat_at) where status in ('queued','running')

dj_sessions
  + current_turn_id uuid null fk dj_turns on delete set null
```

**What lives where.** The listener's words are not in `dj_turns`. The
user's message row is written by the Worker before the turn starts (see
"Start"). The object's SQLite holds only `{ turnId, sessionId, userId,
kind, userMessageSeq, options }` until the turn ends, then deletes it.
`options` holds the energy arc, the surface and the remake flag. `step`
holds the step's name (`picking`), never its artists or title.

**Status rules:**

- `queued`: the row is written and the object is asked to start.
  `running`: the alarm claimed it (`attempt += 1`, `started_at`,
  `heartbeat_at`).
- `done`, `failed` and `stopped` are terminal and set exactly once, by a
  conditional `UPDATE … WHERE status = 'running' AND attempt = $n`.
- **Stale rule:** a turn is lost when it is `queued` or `running` and its
  `heartbeat_at` (or `created_at` for queued) is older than **90 s**. Readers
  treat a lost turn as failed. The hourly maintenance cron, and any read
  that sees one, marks it `failed` with `error_kind = 'lost'` and notifies
  (below). The stop-a-turn claim's 5-minute `STALE_TURN_MS` stays as it is.
  The claim and the turn row are separate guards with separate jobs.

### Start (Worker side)

`POST /sessions` and `POST /sessions/:id/messages` keep every refusal
before the turn, in the same order, with the same status codes (validation,
consent, `anonymous_cap`, 404, the playlist-seed refusals, `dj_paused`).
Album sessions stay on today's in-request JSON path, as they are not
stoppable or streamed either.

Then, with `DURABLE_TURNS` on:

1. **Idempotency.** A new client sends `Idempotency-Key: <uuid v4>`. If a
   `dj_turns` row with that id exists for this user, the request **attaches**
   to it (step 5) instead of starting a turn. A create retried after a drop
   therefore opens the same mix, never a second one. A key that belongs to
   another user, or is not a UUID, is a 400. Old builds send no key, and the
   server mints one.
2. **Persist first.** Create inserts the session row as today. Both routes
   insert the listener's message (moved out of `runClaimedTurn`, which takes
   its `seq` as input). They also insert the `dj_turns` row (`queued`) and
   set `current_turn_id`, all in one transaction.
3. **Start.** `await stub.start(turn)`. The object writes the turn to its
   storage and calls `setAlarm(Date.now())`. If the object already holds an
   unfinished turn, it answers `busy`, and the route answers today's 409
   conflict body. This matches what two concurrent turns on one session hit
   today.
4. **Answer:**
   - **Stream** (`Accept: text/event-stream`): the Worker returns
     `stub.fetch('/watch?turn=<id>')`. The object writes `session` (create),
     then a new `turn` event, then steps, then `result` or `error`, exactly
     as `streamTurn` does today. `streamTurn`'s framing and keepalive move
     into the object, and the same tests carry over.
   - **JSON** (old builds, plain requests): the Worker reads the same watch
     stream itself until `result` or `error`, and answers that body and
     status with `c.json`. A JSON client that drops no longer loses its
     turn.
5. **Attach** (`GET /sessions/:id/turn/stream`, new): it answers the watch
   stream for `current_turn_id`. If the turn is still running, the object
   first writes a `step` with the latest step it saw, so the caption
   resumes, then carries on live. If the turn is already finished, it
   answers `204` and the client re-reads the session. Turns are owned by
   the session's user only.

**The new `turn` event** comes right after `session` (or first, on a message
turn):

```
event: turn
data: {"turnId":"…","push":true}
```

`push` is true when this device has a live push registration and
`TURN_PUSH` is on (see "Who notifies"). Both parsers already skip event
names they do not know: `readTurnStream` in `turn_stream.dart` switches on
the four known names, and `web/src/api/sse.ts` uses an if/else chain. So
old builds ignore it.

### Run (object side)

`TurnRunner` is a thin class over a plain `runTurnJob(env, job, io)`
function, so the logic is tested in Node like everything else.

```
alarm():
  job = storage.get('job'); if none: return
  db, pool = buildDb(env)
  try:
    row = claim dj_turns (status queued|running, attempt < MAX_ATTEMPTS)  -- attempt += 1
    if not claimed: storage.delete('job'); return      -- already terminal: a duplicate alarm
    if row.attempt > 1: rollbackTurn(row.writes) first  -- a previous attempt died mid-turn
    heartbeat every 15 s (one UPDATE; also the stream keepalive)
    reply = runDjTurn(db, buildTurnDeps(env, db), …, { onStep: fanOut+stamp, recordWrites: persist })
    finish dj_turns (done|failed|stopped, error_kind) WHERE attempt = row.attempt
    write result/error to watchers; close them
    notify(turn)                                         -- below
    storage.delete('job')
  catch (anything):
    -- never let the alarm throw for a turn error: that would be a platform retry
    finish as failed('internal'), write error to watchers, notify, delete job
  finally:
    pool.end()
```

- **`buildTurnDeps(env, db)`** is extracted from `buildRequestApp`
  (`buildDjDeps`, `buildFillDeps`, `buildMusicKit`), so the request path and
  the object wire the DJ identically. The fill's subrequest budget is per
  invocation in both places.
- **The surface** (`ios`/`web`) is taken from the start request's
  User-Agent, as today, and travels in the job.
- **Stop-a-turn is unchanged.** The turn still claims the session, and its
  guard still polls `turn_stop_requested`. `POST /sessions/:id/turn/stop`
  still flips the flag and waits. A stopped turn finishes as `stopped` and
  is never notified. A stopped first turn still deletes the session, and
  `dj_turns` goes with it by cascade.
- **Deleting a mix** mid-turn keeps its bounded stop first. The object finds
  its session gone at the finish and just deletes the job.

### Retries without a second mix

There are three ways a turn can be tried twice.

1. **The client retries the POST.** The `Idempotency-Key` attaches to the
   existing turn (Start, step 1). An old build that retries a create
   (there is no such retry in the code today) would still make a second
   mix, as it would today.
2. **The platform re-runs the alarm** after a deploy, an eviction or a
   crash. The attempt is claimed by a conditional UPDATE, so a duplicate
   alarm for a finished turn does nothing. An attempt that died mid-turn
   left its writes recorded in `dj_turns.writes`. Today these are kept in
   memory (`TurnWrites`: message seqs, rename, pill claim, plus the
   starting queue version and claim title). The change persists them as
   they happen. The next attempt first undoes them with the existing
   `rollbackTurn`, keeping the listener's message, then runs the turn
   clean. **At most one automatic re-run** (`MAX_ATTEMPTS = 2`). A second
   death marks it failed (`lost`) and notifies.
3. **Our own code throws.** It is caught in the alarm and never rethrown, so
   the platform does not retry it. A `DjError` is an answer (the same 409,
   502 or 400 body as today), and it is not retried.

A dead attempt's writes could stand where its rollback fails (Neon
unreachable). Then the turn is marked `failed` rather than re-run on top of
them, and the listener gets the failure notice with their message intact.

### Who notifies (with the quick fix's local notification)

There are two notifiers, and the listener should get one notification per
turn: the client's local one (the quick fix) and the server's push (this
spec).

**Rule: whoever saw the turn end tells the listener. When the server is
not sure the client saw it, the server pushes.**

- **Client (quick fix, revised).** At `result` or `error`, if the app is in
  the background, it posts the local notification, **unless the stream's
  `turn` event said `push: true`**. If the app is in the foreground with
  that mix on screen, it posts nothing and acknowledges:
  `POST /sessions/:id/turn/:turnId/seen` (fire and forget, also sent when a
  backgrounded app reopens onto a finished turn). Against an old server
  there is no `turn` event, so the quick fix behaves exactly as built.
- **Server.** At the finish:
  - `stopped` → nothing.
  - No live watcher was written the result (`watched_result = false`) →
    push now.
  - A watcher was written the result → wait **8 s** for `seen` (a second
    alarm, not a sleep). If none arrived → push. This covers the
    "written into a socket that iOS had already suspended" case, where
    neither side would otherwise notify.
  - No push registration for the user, or `TURN_PUSH` off →
    `notify_outcome = 'no_device' | 'off'`. Nothing else happens. The mix is
    there on reopen.
- **On the device.** `apns-collapse-id = turnId`, and `thread-id =
  sessionId`. If a push for the mix already on screen arrives while the app
  is in the foreground, the presentation handler hides it.

So for a listener with push: if they watched it land, there is no
notification. If they backgrounded and the turn landed within the quick
fix's 30 s, the stream said `push: true`, the client stays quiet, there is
no `seen`, and the server pushes after 8 s. If they were gone longer, the
server pushes. Without push (permission denied, or an old build) the quick
fix's local notification covers the first 30 s, and after that the mix is
simply there on reopen, as today.

### APNs from Workers

- **Provider token (.p8).** An ES256 JWT, `kid` = key id, `iss` = team id,
  `iat` = now, signed with `jose` (already a dependency, and already how the
  MusicKit token is signed). Apple: refresh **no more than once every 20
  minutes and no less than once every 60**. Too many refreshes give
  `429 TooManyProviderTokenUpdates`. Isolates and objects are many, so a
  per-isolate token would refresh far too often. **The signed token is
  shared through Postgres:** an `apns_provider_tokens` row (`key_id` pk,
  `token`, `issued_at`). A sender reuses it while it is under 40 minutes
  old. Otherwise it signs a new one and stores it with
  `UPDATE … WHERE issued_at = $old`; the loser of that race re-reads and
  uses the winner's. The token is a signed credential, not the key. The
  `.p8` stays a secret.
- **Request.** `POST https://api.push.apple.com/3/device/<token>`
  (`api.sandbox.push.apple.com` for development builds, per registration),
  with headers `authorization: bearer <jwt>`, `apns-topic: <bundle id>`,
  `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: now + 1
  day`, and `apns-collapse-id: <turnId>`.
- **Responses.** On `410 Unregistered`/`ExpiredToken` or `400
  BadDeviceToken`/`DeviceTokenNotForTopic`, mark the device `disabled_at`
  and do not retry. On `403 ExpiredProviderToken`, re-sign once and retry
  once. On `429 TooManyRequests` or a 5xx, give up for this turn
  (`notify_outcome = 'failed'`). A ready mix is not worth a retry queue. The
  log records the status and reason code only.
- **HTTP/2.** Apple requires HTTP/2. The Workers fetch docs do not say
  which protocol outbound fetch uses to an origin. A Workers APNs client
  exists (`@fivesheepco/cloudflare-apns2`, "native Cloudflare Workers
  APIs"), which suggests it works, but nothing official confirms it.
  **This is gate 0 (spike):** one sandbox push from a deployed Worker
  before anything else is built. If it fails, the fallback is FCM's HTTP v1
  API, which accepts HTTP/1.1 and forwards to APNs, with the same table
  (`provider = 'fcm'`). It adds a Firebase project and its SDK on iOS. The
  founder decides then.

**Payload** (under 4 KB, which Apple caps):

```json
{
  "aps": { "alert": { "title": "Your mix is ready", "body": "<mix title>" },
           "sound": "default", "thread-id": "<sessionId>" },
  "sessionId": "<uuid>", "turnId": "<uuid>", "kind": "ready"
}
```

- A failed or lost turn sends title "The DJ couldn't finish that one" and
  body "Tap to try again", with `"kind": "failed"`.
- The body is the mix's title (the listener named it, or the DJ named it
  from their songs), cleaned with `sanitizeTitleText(·, 40)`. There are
  never lyrics, songs, the listener's prompt or the DJ's reply. Whether
  even the title should show on a lock screen is an open decision (1); the
  alternative is fixed copy only.
- Nothing about the payload is logged beyond `{ event: 'turn_push',
  outcome, status, reason }`.

### Device registration

```
push_devices
  id           uuid pk
  user_id      text fk user on delete cascade
  provider     text  'apns' | 'fcm' | 'webpush'
  platform     text  'ios' | 'android' | 'web'
  token        text                 -- APNs hex token / FCM token / web-push endpoint
  environment  text  'production' | 'sandbox'
  app_version  text null
  created_at, last_seen_at timestamptz, disabled_at timestamptz null
  unique (provider, token)
```

- `PUT /push/devices` with `{ provider, platform, token, environment,
  appVersion }` gives a 204. It upserts on `(provider, token)` and moves the
  row to the caller (a phone passed to a new account follows its owner). It
  clears `disabled_at` and bumps `last_seen_at`. It is sent on every launch
  with permission, since Apple can rotate tokens. Validation: APNs tokens
  are 64 to 200 hex characters.
- `DELETE /push/devices/:token` gives a 204, and is sent at sign-out
  **before** the bearer is dropped. Account deletion cascades.
- **Anonymous listeners** (the first-run flow makes a mix before sign-in)
  can register. The existing `onLinkAccount` hook in `create-auth.ts`, which
  already moves the anonymous user's data, also moves `push_devices`.
- The device row stores no name, no model, and nothing else about the phone.

### iOS client

- **Native, so a new binary.** This needs the Push Notifications capability
  (`aps-environment` entitlement), `registerForRemoteNotifications`, and the
  token callback in `AppDelegate`. **Shorebird cannot patch it**: it ships in
  the next TestFlight/App Store build. The provisioning profile needs push
  enabled on the App ID. The Apple account must be active: the backlog
  records a lapsed App Store Connect access error on 2026-11-20.
- **No Firebase.** A small method channel (`mixtape/push`) does three
  things: `requestAuthorization` → `register` → the token back to Dart, a tap
  → `{ sessionId, turnId }` to Dart, and foreground presentation. Any new
  Swift file needs pbxproj target membership.
  `flutter_local_notifications` already sets itself as the
  `UNUserNotificationCenter` delegate (for the Spotify reminder and the
  quick fix). The channel **must chain to it rather than replace it**, or
  one of the two loses taps. This is the biggest iOS implementation risk,
  and gets its own test on device.
- **Asking for permission, at the moment of value.** Never at launch. The
  first time a mix turn is out for more than about 8 s, a quiet line under
  the working caption offers "Get a ping when it's ready". Tapping it shows
  the system prompt. If the quick fix has already asked for notification
  permission (the same permission covers local and remote), registration
  just happens with no new prompt. A declined prompt is never offered
  again. You → Settings gets a "Mix ready notifications" switch, which
  unregisters (`DELETE`) without touching the OS setting. The exact copy
  and placement go through a mockup first, per house rules (decision 3).
- **Tapping the notification** opens that mix: cold start or warm, through
  the same route the Mixes list uses. A failed-turn notification opens the
  mix with the composer holding the listener's words for a retry.
- **Coming back to a running turn.** A relaunch reads `GET /sessions`, and a
  row whose `turn.status` is `queued`/`running` shows "The DJ is on it…"
  (today this lives only in memory, in `mixActivityProvider`). Opening that
  mix calls `GET /sessions/:id/turn/stream` and resumes the caption. On a
  `204`, or once it ends, it re-reads the session. The 25 s late read in
  `dj_providers.dart` stays for old servers.
- **Idempotency.** Every turn POST sends a fresh `Idempotency-Key`, kept
  with the pending turn. A drop before the stream opened retries the same
  key once, so it attaches rather than duplicates.

### Web client

- It sends `Idempotency-Key` too. On load, a mix whose `turn` is running
  attaches to its stream, so a reload mid-turn resumes the caption instead
  of losing it. The Mixes list shows the same running state.
- There is no web push in this change. The schema allows `webpush` later,
  and a closed tab simply finds the mix there.

### Session reads

`GET /sessions` rows and `GET /sessions/:id` gain an optional `turn: {
id, status, step }` for the session's current turn while it is `queued` or
`running`. The field is omitted otherwise, so old clients ignore it. A lost
turn reads as omitted and gets marked failed on the way.

## Rollout

0. **Gate 0, spikes (half a day, throwaway branch):**
   - One APNs sandbox push from a deployed Worker, which proves HTTP/2.
   - A DO alarm running a 60 s fake turn while a deploy lands, to see what
     the alarm gets (retry, error, or silent loss).
   - The watch-stream proxy from Worker to DO cancelling cleanly on a client
     drop.

   Results go into this spec before the plan.
1. **Server, dark.** Migrations: `dj_turns`, `push_devices`,
   `apns_provider_tokens`, and `dj_sessions.current_turn_id`. Add the
   `TurnRunner` class, its binding and migration, and the routes. Both flags
   are off. Deploy from a clean worktree of committed HEAD, after
   re-checking recent deployments (another session's deploy may be newer). Production is
   unchanged.
2. **`DURABLE_TURNS=on`.** Every mix turn now runs in the object; clients
   see nothing new but the `turn` event. Smoke it with the founder's go (one
   model turn): stream, JSON, a drop mid-turn followed by attach, a stop,
   and a deploy mid-turn. Watch turn logs for `attempt > 1` and `lost` for a
   week. **Rollback:** flip it off. In-flight object turns still finish,
   since the class stays deployed.
3. **Web**, on push: idempotency key, attach on load, list state.
4. **iOS build** (TestFlight): push capability, registration, permission
   line, tap routing, the revised quick-fix rule, attach on relaunch. Then
   `TURN_PUSH=on`, after the device pass: kill the app mid-turn, get the
   push, tap it, land on the mix. Background for 10 s, then foreground: no
   notification. Background past 30 s: exactly one notification.
5. Docs: a `decisions.md` entry when it lands; the turn-steps spec's "Not
   proposed" section gets a pointer here.

**Wrangler additions:**

```jsonc
"durable_objects": { "bindings": [{ "name": "TURN_RUNNER", "class_name": "TurnRunner" }] },
"migrations": [{ "tag": "v1", "new_sqlite_classes": ["TurnRunner"] }],
"vars": { "DURABLE_TURNS": "off", "TURN_PUSH": "off" }
// secrets: APNS_KEY_ID, APNS_PRIVATE_KEY (.p8). Team = APPLE_TEAM_ID, topic = APPLE_BUNDLE_ID.
```

The DO class is exported from `src/index.ts`. `TURN_PUSH=on` without both
APNs secrets throws at wiring, so every request fails until it is fixed (the
`buildShares` pattern). `DURABLE_TURNS=on` without the binding throws the
same way. The founder creates the APNs key (a new key with APNs enabled is
cleaner than adding APNs to the Sign in with Apple key) and sets the
secrets.

## Tests (TDD, red first)

- **Server, unit (Node + pglite, as today):**
  - `runTurnJob` over a fake LLM and an in-memory "object" (storage map,
    watcher list, fake alarm clock):
    - success writes `done`.
    - A `DjError` writes `failed` with the same body as the route.
    - An exception is caught and never rethrown.
    - A duplicate alarm after finish is a no-op.
    - Attempt 2 rolls back attempt 1's recorded writes, then runs.
    - Attempt 3 is refused as `lost`.
    - A stop mid-turn gives `stopped` and no notify.
  - The stale rule at exactly 90 s, and the cron sweep marking lost turns.
  - `TurnWrites` persisted as each write lands (message, rename, pill).
- **Server, routes:**
  - Every pre-turn refusal keeps its status with the flag on.
  - The stream bytes for a fake turn equal today's `streamTurn` bytes, plus
    the `turn` event.
  - The JSON path equals today's body.
  - `Idempotency-Key` replay attaches, and a foreign key gets a 400.
  - A busy session gets a 409.
  - Attach mid-turn sends the latest step first, and attach after the end
    gets a 204.
  - With the flag off, every existing test stands untouched.
- **Notify:**
  - The no-watcher case pushes, and a watcher with `seen` within 8 s
    doesn't.
  - A watcher without `seen` pushes once.
  - A stopped turn sends nothing.
  - A 410 disables the device.
  - The provider token is reused under 40 minutes and refreshed by one
    winner in a race.
  - The payload snapshot contains no prompt or reply text.
- **Devices:** upsert moves ownership, delete, validation, account deletion
  cascade, and anonymous link moving rows.
- **iOS:**
  - The `turn` event parsed, and an unknown event ignored (already true).
  - The quick-fix rule: background plus `push: true` posts nothing, and an
    old server posts locally.
  - `seen` sent for an on-screen result.
  - The idempotency key reused on a drop retry.
  - Relaunch attach resumes the caption.
  - Tap routing to the mix.
  - The permission line shown once and never again after a decline.
- **Web:** attach on load, idempotency key, list running state.
- **Optional:** one `@cloudflare/vitest-pool-workers` test of the real
  object class (open decision 5).

## Costs

At 40 s average, a turn holds the object for about 40 × 0.128 = **5.1
GB-s**. A 160 s turn is 20.5 GB-s.

- The 400,000 GB-s included each month cover about **78,000 average turns**.
  Beyond that it is $12.50 per million GB-s, about **$0.00006 a turn**.
- Requests are about 3 per turn (start, watch, alarm), against 1M included.
- SQLite writes in the object are about 3 rows per turn.
- Neon adds about 8 to 12 small writes per turn (status, steps, a heartbeat
  every 15 s) on a compute that is awake for the turn anyway.
- APNs is free.

The model calls cost several cents a turn, which is three orders of
magnitude more. Workflows or Queues would come out at the same "free" at
our volume.

## Rejected

- **Workflows (B) and Queues (C)** as the runner: they lose the live stream
  (see above). Revisit (B) if the turn is ever split into replayable steps.
- **KV for turn state:** 30 to 60 s stale (turn-steps spec).
- **Unlimited automatic re-runs:** a turn that dies twice is more likely
  broken than unlucky, and each run costs a model turn.
- **A per-isolate APNs token:** many isolates would trip
  `TooManyProviderTokenUpdates`.
- **Firebase Messaging on iOS:** it adds an SDK and a vendor for something a
  method channel and a fetch do. It returns only as the HTTP/2 fallback.
- **The server always pushing, with the client always suppressing in the
  foreground:** a listener who backgrounded within 30 s would get both
  notifications from the quick fix. The `push` flag on the stream and the
  `seen` ack avoid that.

## Open decisions for the founder

1. **Lock-screen text.** Should the push body be the mix's title ("Your mix
   is ready" / "Lagos Nights") or fixed copy only? Recommended: the title.
   The listener named it or saw it named, and fixed copy reads generic.
2. **Failed turns.** Push "The DJ couldn't finish that one" too, or only
   successes? Recommended: push failures. Silence is the bug being fixed.
3. **Permission ask.** Is the inline "Get a ping when it's ready" line,
   offered once on the first turn out past about 8 s, the right moment?
   Needs a mockup either way.
4. **One automatic re-run** after a turn dies mid-way (a deploy, an
   eviction), at the cost of a second model turn? Or fail at once and let
   the listener retry? Recommended: one re-run.
5. **Test harness.** Add `@cloudflare/vitest-pool-workers` for one test of
   the real Durable Object class, or keep all tests in Node over the thin
   class? Recommended: keep Node, and add the pool only if the spike shows
   behaviour our fakes miss.
6. **Durable Object vs Workflow.** Accept the project's first Durable Object
   (A)? Or take (B), which gives up the stream for polling?
7. **Where the object runs.** Leave it where the first request lands, or pin
   it with a `locationHint` near Neon's region (possibly faster turns,
   measured separately)?
8. **Web push.** Out of scope now. Should it be on the backlog?
