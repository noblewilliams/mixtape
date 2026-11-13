# The DJ's working line follows the turn's real steps: plan

**Status:** approved 2026-11-13 (founder: streamed turn, the step line on
the Making screens, names in the caption).
- Spec: `../specs/2026-11-13-dj-turn-steps-design.md`.
- Decision: `../../decisions.md`, 2026-11-13 "The DJ's working line follows
  the turn's real steps".

**Cadence:** house style. Each task goes to a fresh implementer agent (Opus)
with red-first tests. Then a reviewer pass and one fix round, then one
commit per task, with files staged by explicit path.

**Order:** S1 → S2 on the server. The clients need only the wire contract
in the spec, so C1 → C2 (iOS) and W1 → W2 (web) can run beside the server
track against a fake. Each client task's real-server check waits for S2.
At most two agents in flight. Mobile first: S1 runs beside C1 (its files are
clean), then S2 beside W1, then W2, and C2 once the iOS tree is committed.

## Before starting

- **Another session's iOS work.** On 2026-11-13 the iOS working tree holds
  the device-smoke changes, uncommitted: `lyric_turn.dart`,
  `dj_providers.dart`, `mix_activity_provider.dart`, `chat_screen.dart` and
  their tests. C2 builds on them, so it starts only once that work is
  committed. C1 touches only `client/lib/data/dj/` and a new parser, which
  are clean, so it can run now. Never stage another session's hunks.
  - `docs/decisions.md` and `docs/backlog.md` carry its uncommitted entries
    too, so this plan's entries in those two files stay uncommitted for
    whoever commits that work.
- **The server and web trees were clean** on 2026-11-13. Re-check
  `git status` before S1 and W1.
- **No migration** in this plan.
- **Formatting.** Format only the files a task touched, never a folder.

## Tasks

**S1. Steps from the loop** (`server/src/dj/loop.ts`, tests).
- Add the `TurnStep` type and an optional `step` reporter on `DjDeps`.
  `runDjTurn` takes it from `DjTurnOptions.onStep` and wraps it so that it
  never throws.
- Emit at the points in the spec's server-steps table. `picking` and the
  genre `checking` come from the per-turn deps wrapper beside `timedDeps`.
- Names (spec, "Names"): `artists`, `genres`, `playlist`, `title` and
  `count` on the listed steps, each cleaned with `sanitizeTitleText(_, 40)`.
- Tests: a recording reporter over the fake LLM gives the step order for a
  personal generate, a catalogue blend, a proposed mix, an edit with a
  swap, a rename-only turn and a remember-only turn, with the names each
  carries (and none where the brief named none). A throwing reporter leaves
  the turn's result unchanged. The existing loop tests pass untouched.

**S2. Streamed turn on the routes** (`server/src/routes/sessions.ts`, a
`turn-stream.ts` sibling, `server/src/index.ts`, tests).
- Move the create and message success and error bodies into shared
  builders, so the JSON output is unchanged and the existing route tests
  stay green.
- Add `streamTurn`: a hand-rolled `TransformStream` with SSE framing, a
  turn promise that does not depend on the writer and goes to
  `c.executionCtx.waitUntil`, a 15 s keepalive, and `result` or `error`
  from the shared builders.
- Negotiate on `Accept: text/event-stream`, for mix turns only, after every
  pre-turn refusal. Create sends `session` first.
- `index.ts`: wrap the `ExecutionContext` so that `pool.end()` waits on the
  recorded `waitUntil` promises.
- Tests (spec, Tests section):
  - No header gives JSON.
  - Refusals keep their status.
  - `session` comes first on create.
  - `result` equals the JSON body.
  - A `DjError` gives `error` with the same status and body.
  - An album session answers JSON.
  - The keepalive is sent on a fake clock.
  - The pool closes only after recorded work, and at once without any.

**C1. iOS stream client** (`client/lib/data/dj/`, a new
`turn_stream.dart` parser, tests).
- Add the SSE parser.
- `createSessionWithProgress`, `sendMessageWithProgress` and
  `sendRemakeWithProgress` (an extension on `DjApi`) take `onProgress` and
  send the Accept header for mixes. A JSON answer falls back to today's parse.
  `error` maps to the existing five exit types. On a stream, a 45 s idle
  timeout replaces the 120 s total one.
- Tests: chunk splits at every byte, CRLF, comment lines, an early end as a
  `NetworkException`, the JSON fallback, the idle timeout.

**C2. iOS working line** (`lyric_turn.dart`, `dj_providers.dart`,
`mix_activity_provider.dart`, `chat_screen.dart`, the debug preview, tests).
- Store the step on `ChatState` and on the working entry.
- `DjWorkingPhrases` gets the step table with its named lines and the
  spec's rules: a timed walk until a stream opens, listening held until the
  first step, a 1.5 s dwell, a 12 s in-step clock, the 30 s line, the
  44-character fallback to the nameless line, one line with an ellipsis.
- `MIXTAPE_PREVIEW=mixes` gets a fake stream that walks the steps.
- Widget tests for each rule, plus resuming the step on a reopened
  conversation.
- Add the step line under the Making screen's headline.

**W1. Web stream client** (`web/src/api/client.ts`, a new `sse.ts`, the fake
API, tests).
- Same contract as C1: `onStep`, the Accept header for mixes, the JSON
  fallback, `error` thrown as `ApiError(status, body)`.
- Parser tests as in C1.

**W2. Web working line** (`Conversation.tsx`, a new `djWorkingLines.ts`,
styles, tests).
- Port the table (named lines included) and rules.
- Show the line under the `dj-thinking` cassette, and keep the
  `aria-label` steady.
- Add a `?ui-preview` state that walks the steps.
- Add the step line under the Making screen's headline, as in C2.

**G. Ship** (founder gates).
1. Deploy the Worker from a clean worktree of committed HEAD.
2. Run a production `curl -N` smoke with a throwaway anonymous user. It
   costs one model turn, needs the founder's go, and the user is deleted
   afterwards.
3. Check the same request without the header still answers JSON.
4. Push for Netlify, and check the web line in a private window.
5. Ship the next TestFlight build, then the device pass from the spec's
   Rollout section.
