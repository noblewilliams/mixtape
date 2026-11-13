# The DJ's working line follows the turn's real steps

Date: 2026-11-13. Status: **approved 2026-11-13** (founder: "approve (a),
add the step line to Making screens, … also add names in the caption").
Names in the caption were added to the design on approval (see "Names").

## Why

The founder asked (2026-11-13) for the "The DJ is listening…" loader to say
what the DJ is actually doing: reading the ask, going through the library,
cooking something up, shuffling. The iOS change that shipped the same day
(decision 2026-11-13, `DjWorkingPhrases` in `lyric_turn.dart`) walks a fixed
list of phases on a clock. A mix turn reports nothing until it is done, so
the lines follow the usual order of work, not this turn's.

The clock is wrong in both directions. A follow-up that only renames the mix
answers in about 5 s but still shows "Digging through the crates…". A first
mix from the catalogue spends 13 to 67 s in one curation call (backlog,
2026-11-10), while the clock moves on to "Pressing the tape…" and then
"Still at the decks" long before anything is pressed. The web shows a single
static line ("The DJ is listening…", `Conversation.tsx`).

The loop already knows its steps. `attemptTurn` in `server/src/dj/loop.ts`
dispatches the tool calls (`find_playlists`, `set_playlist_inspiration`,
`generate_queue`, `edit_queue`, `remember_preference`, `rename_session`), and
inside `generate_queue` the work runs as the catalogue fill, the pool build,
curation and proposals, the Apple verification, the genre sound check and
the queue write. `timedDeps` already labels every model call by kind
(`chat`, `curate`, `propose`, `genre`, `title`) for the turn log.

## What has to hold

- Older app builds keep working, unchanged. TestFlight builds 1.0.2 (5) and
  (6) and the live web bundle post a turn and read one JSON body.
- New clients keep working against a server that has not been updated, or
  one rolled back.
- When no step has arrived, the timed lines stay as they are.
- The anonymous first-run flow works the same way (it creates its first mix
  through `POST /sessions` with a bearer token, like everyone else).
- Steps carry only names the listener already said or sees: the artists or
  genres their brief named, the playlist they chose, the mix's new title, a
  song count. Never lyrics, track lists, memory notes or search queries, and
  steps are never logged (the turn log stays "counts and codes only").
- Deploys go from a clean worktree of committed HEAD.

## Workers facts that decide this

Checked against the Cloudflare docs on 2026-11-13:

- An HTTP Worker has **no wall-clock limit while the client stays
  connected**, and may stream a response body for as long as that lasts.
- When the client disconnects or the response completes, work that was not
  passed to `ctx.waitUntil()` "may be canceled". `waitUntil` extends a
  request **by at most 30 seconds** after the response is sent or the client
  disconnects. It is "shared across all `waitUntil()` calls within the same
  request".
- Waiting on I/O (model calls, Neon, Apple) does not count toward CPU time
  (Workers Paid: 30 s default).
- **Workers KV is unusable for a progress marker.** A `get` is cached at the
  edge for at least 30 s (default 60 s), and a write "may take up to 60
  seconds or more" to be visible elsewhere. Same-location visibility "is not
  guaranteed".
- Cloudflare's compression list does not include `text/event-stream` or
  `application/x-ndjson`. `cache-control: no-transform` opts a response out
  regardless.

The 30-second cap is the important one. A turn takes 20 to 50 s, and 159 s
was seen on 2026-11-10. So on Workers a turn **cannot** become a background
job that answers `202` and keeps running: whichever option we pick, the
client holds the turn's request open until the turn is done, as it does
today.

## The options

### (a) Stream the turn's response

The client asks for a stream on the existing `POST /sessions` and
`POST /sessions/:id/messages` with `Accept: text/event-stream`. The server
sends the steps down the request that is already open, then the same JSON
body it sends today as the last event. Any request without that header gets
today's JSON exactly.

For:

- **No second channel.** The request has to stay open anyway (above), so
  the steps travel on it for free. There are no extra Worker requests, Neon
  connections or auth lookups.
- **Steps arrive as they happen.** A 1-second step (rename, the reply) is
  seen, not missed between polls.
- **No migration, nothing stored.** The step lives only in the request.
- **Long turns stop failing on iOS.** `DjApi` gives up after 120 s in all
  (`dj_api.dart`). A turn that took 130 to 160 s (seen 2026-11-10) fails on
  the device while the server finishes it. A stream that sends a keepalive
  every 15 s can use an idle timeout instead.
- **A disconnect costs less than today.** The streamed route has to hand
  the turn to `waitUntil` (its handler returns before the turn ends), so a
  client that drops gets up to 30 more seconds for the turn to land. Today's
  JSON path registers nothing.
- **The create stream can name the session first.** The server writes the
  session row before the turn runs, so its first event can carry the id.
  The iOS Mixes pending row guesses that id today (`PendingMix.adopt`).

Against:

- **The pool lifetime has to change.** `server/src/index.ts` closes the Neon
  pool in a `finally` as soon as `app.fetch` returns. A streamed response
  returns at once, so the pool would close under the running turn. The fix
  touches the path every request takes. It must only delay `pool.end()` for
  requests that registered work, and it needs its own test.
- **Errors after the status line go in-band.** Once the 200 and headers are
  out, a failed turn cannot answer 502. It sends an `error` event carrying
  today's status and body, and each client needs a second error path that
  ends in the same exceptions as today.
- **Two streaming parsers to write**, one in Dart and one in TypeScript.
  They are small, but chunk-boundary bugs are the classic failure, so the
  tests must split events across chunks.
- **Two response shapes per route** while old builds are alive. The route
  tests double for those two routes.
- **Only the client holding the request sees the steps.** A web reload,
  another device, or the app relaunched mid-turn sees no step. On iOS, a
  conversation reopened in the same app process can still show the step,
  because the turn's request outlives the screen (the 2026-11-13 Mixes
  work).

### (b) A per-session step marker that clients poll

The server writes `{step, at}` for the session at each step. While its POST
is out, the client polls `GET /sessions/:id/turn` (or a `turn` field on
`GET /sessions/:id`) every 1.5 to 2 s.

For:

- **The POST contract does not change at all.** There is no parser and no
  in-band error, and the polls are plain JSON GETs.
- **Anyone can read the marker:** a web reload, another device, the Mixes
  list after a relaunch. That is (b)'s real advantage. It is also the
  server-side state that the 2026-11-13 reopen clause names for the Mixes
  dot across launches.

Against:

- **The storage has to be Postgres** (a migration: `turn_step`,
  `turn_step_at`, `turn_started_at` on `dj_sessions`, or a `dj_turns`
  table). KV's edge cache returns a step 30 to 60 s old, and a Durable
  Object would be the project's first, new infrastructure for a caption.
- **Every poll is a Worker request** that opens a Neon pool, runs Better
  Auth's session lookup and one SELECT. That is about 20 to 30 per 40-second
  turn, with an UPDATE per step on the turn's side. It is affordable at
  today's scale (Workers Paid, a compute that is awake during the turn
  anyway), but it is all overhead for a caption.
- **The create path has no id to poll.** `POST /sessions` returns the
  session id only when the turn is done. The client would have to send its
  own turn id and the server accept it, which is a new request field with
  its own validation.
- **Steps are late and short ones are lost.** A step arrives up to one poll
  interval late, and rename, the memory note and the reply (1 to 2 s each)
  are often never seen.
- **Markers go stale.** A turn killed mid-way (a disconnect plus the 30 s
  cap, an isolate evicted) leaves its marker behind, so readers need a
  staleness rule.
- **It fixes nothing about disconnects or the 120 s iOS cap.** The POST is
  still held open exactly as today, so (b) adds a channel beside it.

### Not proposed: run the turn off the request

A Durable Object, a Queue consumer or a Workflow would run the turn
whatever the client does. The mix would land even if the app is killed, and
steps could reach every device. That is the real fix for durability, but it
means the project's first Durable Object or Queue, wrangler migrations, and
a DB connection owned by the object rather than the request. Neither (a)
nor (b) changes durability beyond (a)'s 30 s of grace. **Reopens if:** turn
logs or listener reports show mixes lost to a closed app.

## Recommendation: (a), the streamed turn

The request is already held open for the whole turn, so streaming the steps
down it is cheaper, faster and more truthful than a second, polling channel.
It adds no migration and no stored state, and it fixes the 120 s iOS cap on
the side. Its costs are the pool-lifetime change, an in-band error path and
two small parsers, all testable. (b)'s one real advantage, steps visible
across devices and reloads, is a different feature: server-side turn state,
the same thing the Mixes dot across launches needs. It can be added later
as a step stamped on the session row without changing this contract.

## Design

### Wire contract

**Asking for a stream.** A client sends `Accept: text/event-stream` on
`POST /sessions` or `POST /sessions/:id/messages`. Without that header,
nothing changes: same status codes, same JSON. Old builds send
`accept: application/json` (web) or no Accept header at all (Dart's
`http`), so they always get JSON.

**Mix turns only.** Album sessions (`kind: 'album'` on create, an album
session on a message) answer JSON even when asked for a stream. Their lines
stay on the clock (`DjWorkingPhrases.album`). Album steps are a later,
separate change.

**Refusals before the turn keep their status.** These are answered with
today's status and JSON body even on a stream request: validation 400, the
AI consent 403, `anonymous_cap` 403, 404, the playlist-seed refusals, and
`album_picks_off` and `wrong_session_kind`. The stream starts only once the
turn is about to run, after the persist-first session row on create.

**The stream.** `200`, with `content-type: text/event-stream` and
`cache-control: no-cache, no-transform`. The events use SSE framing (an
`event:` line, one `data:` line of JSON, then a blank line). Both clients
parse it by hand from the fetch body. `EventSource` cannot POST or send a
bearer token, so it is not used. SSE rather than NDJSON for its
conventions: comment lines as keepalives, and intermediaries that treat the
type as a stream.

| Event | Data | When |
|---|---|---|
| `session` | `{ "session": <sessionListColumns row> }` | Create only, first, as soon as the row exists. Clients may ignore it in this change. |
| `step` | `{ "step": <TurnStep>, "scope"?: "library" \| "catalogue", "artists"?: string[], "genres"?: string[], "playlist"?: string, "title"?: string, "count"?: number }` | Each time the DJ starts a new kind of work (table below). The name fields are optional and described under "Names". |
| `result` | Today's success body, byte for byte | Last, on success, including a recovered failure (decision 4 of 2026-11-09). |
| `error` | `{ "status": <today's status>, "body": <today's error body> }` | Last, on failure: 409 conflict, 502 curation or LLM, 400, or 500 `{ "error": "internal" }` for anything unforeseen. |
| `: keepalive` (comment) | none | Every 15 s while nothing else was sent. |

The stream ends after `result` or `error`. Every event, the last one
included, ends with a blank line (`\n\n`): a client counts an event only
once its blank line arrives.

**A dropped stream.** Before the stream opened, a drop is a network failure,
as today. Once it opened, the server has the turn and is likely still
running it (up to 30 s more under `waitUntil`). The client keeps the
listener's line, reads the session at once and adopts a new DJ reply if one
landed. If none had, it shows the failure as a server-side one and reads
once more about 25 s later, adopting the reply then and dropping the
failure line. A create whose stream named the mix before dropping opens
that mix with the failure, instead of reporting offline, so a retry does
not make a second mix. A stream that ends without
either is a dropped connection, and the client treats it as a network
failure, as a timeout is treated today.

`TurnStep` is a closed list on the server and an open one on the clients:
**a client ignores a step it does not know** and keeps its current line, so
the server can add steps without breaking a build.

### Server steps

| Step | Sent when | Where in `loop.ts` |
|---|---|---|
| `listening` | Not sent. Clients start on it. | |
| `playlists` | `find_playlists` or `set_playlist_inspiration` runs | tool dispatch in `attemptTurn` |
| `digging`, scope `catalogue` | the Apple catalogue fill starts, or a catalogue pool is built | before `fillCatalogue` and `fillArtistCatalogue`, and before `buildPool` when the pool mode is not personal (`generateFromBrief`, `executeOnlyArtistQueue`) |
| `digging`, scope `library` | a pool is built from the listener's own music | before `buildPool` when the pool mode is personal (same two functions) |
| `picking` | a `curate` or `propose` model call starts | the per-turn deps wrapper (`timedDeps` already sorts calls by kind) |
| `checking` | Apple verification of proposals, or the genre sound check | `verifyRound`, the `genre` model call |
| `editing` | `edit_queue` runs | tool dispatch |
| `pressing` | a queue write lands (`replaceQueue`, `applyOps`) | after each write in the generate, proposed, artist-only and edit paths |
| `labelling` | `rename_session` runs | tool dispatch |
| `noting` | `remember_preference` runs | tool dispatch |
| `writing` | a conversation round after a tool round starts | `attemptTurn`, round > 0 |

### Names

Each name field is sent only on the steps listed, and only when the value
exists. The server cleans every name with `sanitizeTitleText(name, 40)`
(control characters out, whitespace collapsed, at most 40 characters) and
drops one that cleans to nothing.

| Field | On step | Value |
|---|---|---|
| `artists` | `digging`, `picking` | The brief's `onlyArtist`, or else its first three `namedArtists`, as the DJ spelled them. |
| `genres` | `checking` (the genre sound check only, not Apple verification) | The brief's first two `genres`. |
| `playlist` | `playlists` (`set_playlist_inspiration` only, once it resolved) | The chosen playlist's name. |
| `title` | `labelling` | The mix's new title, after `rename_session` saved it. |
| `count` | `pressing` | How many songs the queue now holds. |

`find_playlists` sends no name: its query is the DJ's search text, not the
listener's. An edit sends no song names: naming a swapped song would need a
read for a caption.

The clients render names as plain text (a Flutter `Text`, a React text
node), so nothing in a name can be markup. A line with names that comes out
longer than 44 characters falls back to that step's nameless line, and the
caption is one line with an ellipsis as the last guard. VoiceOver keeps its
one steady announcement, without names.

**The reporter rides on `DjDeps`** as an optional `step` function. The deps
are already threaded through every executor, and `runDjTurn` already wraps
them per turn (`timedDeps`), so no new parameter has to travel down the
call chain. `runDjTurn` takes it from `DjTurnOptions.onStep`. When absent
(the JSON path, the tests that do not ask for it), every call is a no-op.

**A step never breaks a turn.** The reporter swallows its own errors, and a
write to a closed stream is dropped. Steps can repeat or go backwards: a
conflict retry re-runs the attempt, and a replacement round goes back to
`picking`. Clients show the latest.

### Server plumbing

- **`streamTurn(c, run)`** in `routes/sessions.ts` (or a sibling module).
  It opens a `TransformStream`, returns the `Response` at once, and starts
  `run(onStep)` as a promise that is **independent of the writer**: a write
  that fails because the client left never rejects the turn. That promise
  goes to `c.executionCtx.waitUntil`. On success it writes `result`, built
  by the same body function the JSON path uses. On a `DjError` it writes
  `error` with `djErrorStatus` and `djErrorBody`. Anything else writes 500
  and is logged. A 15 s keepalive timer is cleared when it finishes. A
  hand-rolled stream is preferred over Hono's `streamSSE`, so that abort
  behaviour is ours and visible.
- **Shared body builders.** The create and message handlers' success and
  error bodies move into functions both paths call, so `result` and `error`
  cannot drift from the JSON contract.
- **Pool lifetime (`index.ts`).** `app.fetch` gets a wrapped
  `ExecutionContext` whose `waitUntil` records each promise and forwards it
  to the real one. The `finally` becomes
  `ctx.waitUntil(Promise.allSettled(recorded).then(() => pool.end()))`.
  Requests that record nothing close the pool as they do today.
- **Turn log.** No new fields. `timing` already says where the time went.

### iOS client

- **`DjApi`** gains `createSessionWithProgress`, `sendMessageWithProgress`
  and `sendRemakeWithProgress` (an extension, with a
  `DjTurnProgressSender` interface for fakes, because many test fakes
  `implements DjApi`), each taking an optional `onProgress` that receives
  `TurnStreamOpened`, `TurnSessionStarted` and `TurnStep`
  (`data/dj/turn_stream.dart`). With a callback they send
  `Accept: text/event-stream` through `http.Client.send`; without one, or
  for an album create, the request is today's. A fake without the
  interface falls back to the plain methods and reports no progress.
  - If the answer is JSON (an old server, a refusal before the turn, an
    album), it is parsed exactly as today.
  - `result` goes through today's parse. `error` maps through today's
    status and body handling to the same five exit types.
  - On a stream, the 120 s total timeout becomes a 45 s idle timeout, reset
    by any line including keepalives.
- **State.** The latest step and the time it arrived ride on `ChatState`
  and on `mixActivityProvider`'s working entry beside `startedAt`. A
  conversation reopened in the same process picks up the current step,
  as it picks up `startedAt` today.
- **`DjWorkingPhrases`** gains a step table (copy below):
  - Before the response headers arrive, and whenever the server answered
    JSON, the timed walk runs exactly as today (its first phase is
    "listening" for 4 s, longer than a stream takes to open).
  - Once a stream has opened, the clock stops. "The DJ is listening…"
    holds until the first step, then each step shows its line.
  - Within a step, later lines take over on a short clock (12 s each), and
    a step past 30 s shows "Still at the decks. Worth the wait…".
  - Each line holds at least 1.5 s. A step that arrives sooner waits, and
    one superseded while waiting is skipped, so a 50 ms `noting` never
    flashes.
  - VoiceOver keeps hearing one steady announcement (unchanged).
- **Mixes rows** keep "The DJ is on it…". There is no per-step text in the
  list.

### Web client

- **`createSession` and `sendMessage`** (`web/src/api/client.ts`) take an
  optional `onProgress` (same events as iOS), send
  `accept: text/event-stream` for mix turns, read
  `response.body`, and fall back to JSON on a JSON content type. `error`
  becomes the same `ApiError(status, body)` it throws today.
- **The working line.** The web has had one static line. It gains the same
  table (a `djWorkingLines.ts` port with the same timed fallback, step
  rules and dwell) under the existing `dj-thinking` cassette in
  `Conversation.tsx`. The `aria-label` stays steady.
- The API is called cross-origin and straight at the Worker
  (`VITE_API_URL`), with no Netlify proxy in between, so nothing buffers
  the stream.

### Copy

Each turn picks one line per step with its seed, as the timed phases do
today. The timed fallback list is unchanged.

Artists read as "Tems", "Tems and Asake", or "Tems, Asake and more" for
three. Genres read the same way, with at most two. Names in quotes use
curly quotes.

| Step, with a name | Line(s), one picked |
|---|---|
| `digging` `library` + artists | Flipping through your {artists} records… / Pulling your {artists} records… |
| `digging` `catalogue` + artists | Digging for {artists}… / Crate-digging for {artists}… |
| `picking` + artists | Pulling records that sit with {artists}… / Finding company for {artists}… |
| `checking` + genres | Running the {genres} sound check… |
| `playlists` + playlist | Pulling “{playlist}” off the shelf… |
| `labelling` + title | Labelling it “{title}”… |
| `pressing` + count | Pressing {count} songs to tape… (1: Pressing one song to tape…) |

Without names, or when the line would run past 44 characters:

| Step | First line(s), one picked | If the step runs past 12 s |
|---|---|---|
| (start) `listening` | The DJ is listening… | |
| `playlists` | Looking through your playlists… / Pulling that playlist off the shelf… | |
| `digging` `library` | Flipping through your records… / Thumbing through your stacks… | Still flipping… |
| `digging` `catalogue` | Digging through the crates… / Crate-digging for you… | Deeper in the crates… |
| `picking` | Pulling records that fit… / Cueing up contenders… | Sequencing the tracklist… / Lining up the transitions… |
| `checking` | Checking the pressings… / Giving it a sound check… | |
| `editing` | Reworking the tracklist… / Swapping records… | |
| `pressing` | Pressing the tape… / Spooling it up… | |
| `labelling` | Labelling the cassette… | |
| `noting` | Jotting that on the sleeve… | |
| `writing` | Writing the liner notes… | |
| any step past 30 s | Still at the decks. Worth the wait… | |

A step with two later lines shows them in order, 12 s each (picking:
"Sequencing…" at 12 s, "Lining up…" at 24 s, then the 30 s line). The 30 s
line also covers listening, counted from when the stream opened. A
`pressing` count below 1 and a `digging` step with no known scope take the
nameless and catalogue lines.

### First-run Making screens

The first mix is the longest wait (24 to 40 s on the catalogue path).
`making_screen.dart` and `Making.tsx` show one fixed line, "The DJ is
listening. This takes about a minute." **Decided (founder, 2026-11-13):**
keep that headline and add the step line under it, from the same table. It
starts on "The DJ is listening…" and follows the same rules, including the
timed fallback. The fixed line becomes "This takes about a minute.", so the
screen does not say "The DJ is listening" twice. The stream and the parser are already there, so it is one
widget on each platform.

## Rollout

1. **Server first.** It is backward compatible, since no client asks for a
   stream yet. Deploy from a clean worktree of committed HEAD.
   - Smoke with `curl -N -H 'Accept: text/event-stream'` against
     production, using a throwaway anonymous user, then delete it. This
     costs one model turn and needs the founder's go.
   - Check that the same request without the header still answers JSON.
2. **Web.** It publishes on push. A new bundle against a rolled-back
   server falls back to JSON.
3. **iOS** in the next TestFlight build. Device pass: a follow-up rename
   shows the labelling line, a first mix walks digging, picking, pressing
   and writing, and backgrounding mid-turn behaves as today.

**Rollback.** Roll the Worker back alone and the new clients fall back to
the timed lines. Roll back a client alone and the server keeps answering
JSON to it.

## Tests

- **Server, loop:** a recording reporter over the fake LLM gives the step
  order for a personal generate, a catalogue blend, a proposed mix, an edit
  with a swap, a rename-only turn and a remember-only turn. A reporter that
  throws does not fail the turn.
- **Server, routes:**
  - No header gives today's JSON (the existing tests stand).
  - With the header, the pre-turn refusals keep their status codes.
  - Create sends `session` first.
  - `result` equals the JSON body for the same turn.
  - A `DjError` gives `error` with the same status and body.
  - An album session answers JSON.
  - The keepalive is sent on a fake clock.
- **Server, `index.ts`:** a recorded promise delays `pool.end()`, and a
  request that records nothing closes the pool at once.
- **iOS and web parsers:**
  - Events split across chunks at every byte.
  - CRLF and LF line endings.
  - Comment lines.
  - A stream that ends early is a network failure.
  - A JSON answer falls back to today's parse.
- **iOS and web lines:**
  - The timed walk with no stream.
  - Listening holds once a stream opens.
  - Step mapping, and an unknown step ignored.
  - The 1.5 s dwell and skipping a superseded step.
  - The in-step clock and the 30 s line.
  - A reopened conversation (iOS) resumes the step.

## Rejected

- **Polling a step marker (b).** See above. Revisit as server-side turn
  state if steps or the Mixes dot are wanted across devices.
- **KV for the marker.** Its edge cache is 30 to 60 s stale.
- **Song names on edits, memory text, search queries.** Too long for one
  line, a read for a caption, or the DJ's words rather than the listener's
  (see "Names").
- **Streaming the DJ's reply text token by token.** The reply is about 2 s
  of a 40 s turn, and it arrives with the mix it describes.
- **NDJSON framing.** It would work equally well. SSE was picked for its
  keepalive and intermediary conventions.

## Founder answers (2026-11-13)

1. (a), the streamed turn: approved.
2. The step line on the first-run Making screens: yes.
3. Names in the caption: yes (see "Names"). The copy table stands as
   written; lines can be tuned after the device pass.
