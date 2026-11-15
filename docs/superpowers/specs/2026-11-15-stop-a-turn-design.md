# Stop a turn: design

2026-11-15. Founder ask: after sending, the composer must stay open (it
went read-only for the whole turn), and while the DJ works a stop key
replaces send so the listener can stop at any time. Chosen: a **real stop**
(the turn stops and leaves nothing behind), on **iOS and web**.

## Behaviour

- **The composer stays open while the DJ works.** The listener can tap in
  and type the next message. Submitting (Return / send) does nothing while a
  turn is out; the draft is kept. The mic is hidden while a turn is out.
- **Stop replaces send while a mix turn is out**, whether or not there is a
  draft. Tooltip / label: "Stop". It takes effect at once on screen:
  - the listener's pending bubble goes, the working line / cassette goes;
  - the stopped text goes back into the composer if the composer is empty
    (a draft typed meanwhile is kept, never overwritten);
  - the in-flight request is abandoned: its result or error is ignored.
- **The stop is real.** The app calls `POST /sessions/:id/turn/stop`. The
  server stops the turn at its next checkpoint (within about a second, even
  mid model call) and undoes what it wrote: the listener's message and any
  DJ reply are deleted, the mix goes back to the version it was at (via a
  restore, so the version number still only moves forward), a rename this
  turn made is taken back. A stopped **first turn** (Home → new mix) deletes
  the new session entirely.
- **Too late is honest.** If the turn already finished before the stop
  landed, the answer is `{ stopped: false }` and the app re-reads the
  session and shows what landed (for a first turn: opens the new mix).
- **A send right after a stop waits for the stop.** The stop answers only
  once the turn has been undone, so the next turn never races the rollback.
  The app shows the working state for the new turn in the meantime.
- **Album turns** have no stop in v1 (JSON only, short); their composer
  stays open but shows no stop key. Backlog item.

## Contract

`POST /sessions/:id/turn/stop` (authenticated, owner only; no AI-consent
gate: it makes no model call).

- `200 { "stopped": true }`: a turn was running and is now undone. For a
  first turn the session no longer exists.
- `200 { "stopped": false }`: no turn was running (it finished first, or
  never started). Re-read the session.
- `404 { "error": "not_found" }`: not the caller's session, or already
  deleted by an earlier stop.

It may take up to ~30 s in the worst case (it waits for the rollback), so
clients never block the UI on it.

The abandoned turn request itself, if anyone still reads it, ends with
`409 { "error": "turn_stopped" }` (JSON) or an `error` event with that
kind on the stream.

For a first turn the app needs the session id: it is the stream's first
event (`TurnSessionStarted`). A stop tapped before that event arrives waits
for it, then stops.

## Server mechanism

Three columns on `dj_sessions`: `active_turn_id uuid`, `active_turn_at
timestamptz`, `turn_stop_requested boolean`.

- A mix turn (`runDjTurn`) claims the session at its start (new id, stop
  cleared) and remembers the starting queue version and title.
- **Checkpoints:** before every model call, and polled about once a second
  during one, the turn reads the flag; set, it throws `TurnStopped`.
- **Finish:** a successful turn clears its claim with
  `UPDATE … SET active_turn_id = NULL WHERE id = ? AND active_turn_id = ?
  AND NOT turn_stop_requested`. No row means a stop got in first: roll back.
- **Stop:** `UPDATE … SET turn_stop_requested = true WHERE id = ? AND
  active_turn_id IS NOT NULL` (claims older than 5 minutes are treated as
  dead). No row → `{ stopped: false }`. Otherwise poll until the claim is
  cleared (or the session is gone), then `{ stopped: true }`. Postgres row
  locks order the two UPDATEs, so exactly one of "finished" and "stopped"
  wins.
- **Rollback:** delete this turn's messages (seq ≥ the listener's row),
  restore the starting queue version if the queue moved, put the title back,
  clear `music_chip_at` if this turn offered the pill, then clear the claim.
  A first turn deletes the session instead. Funnel rows stay (they record
  what happened).

## As built (2026-11-15)

- Clients treat a `404` from the stop as stopped (the session is gone).
- Stopped text goes back only for turns typed in the composer; a Remake or
  suggestion-pill turn puts nothing back. A stop also brings back the
  suggestion and history pills the send had cleared.
- Not stoppable yet: a turn sent before a chat was reopened (that screen
  does not hold the request), the iOS first-run welcome (its making screen
  covers the composer), and on web the New mix dialog, routine suggestions
  and kept-prompt re-sends (none stream). Only the Home composer's create
  and in-chat mix turns have Stop.
