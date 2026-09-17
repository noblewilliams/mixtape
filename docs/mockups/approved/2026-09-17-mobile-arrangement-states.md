# Approved native arrangement states

Approved September 17, 2026: founder replied "approved" to
[arrangement states revision 1](../2026-09-17-mobile-arrangement-states.html).
Extends the [shell approval](2026-09-17-mobile-shell.md).

## Locked behaviour

- Pushed from the conversation's Open or arrangement cluster button; glass
  back cluster, small title, Version history and More clusters; tab bar
  hidden. Meta line (count, duration, version) and the mix actions sit under
  the title: Play now (app player), Create playlist (label chip), Send to
  Music (text). Actions are hidden when the list is empty and absent when no
  song has an Apple ID, with the reason written beside the remaining action.
- Rows: number, 48 pt square art, title, artist, drag grip. Tap reveals the
  DJ's note on a quiet band, or "no notes from the DJ".
- Reorder: long-press the grip lifts the row; origin slot dims; moves are
  written against the current version; no renumbering until confirmed.
  VoiceOver: Move up / Move down rotor actions.
- Remove: swipe left reveals Remove; full swipe removes; toast names the song
  with Undo that re-adds at the old position via a versioned operation. Undo
  is not yet implemented natively and requires an insert operation server-side.
- Play now hands to the app-owned Apple player: button becomes Playing with
  its meter; mini-player appears; edits, restores and saves never replace the
  active queue. Send to Music starts the system player and toasts the skipped
  count or "Couldn't play — " with Apple's reason.
- Create playlist: native alert, mix title as default name, "Your name"
  shown under the playlist and remembered; success and partial-failure copy as
  shipped. The mix is unchanged.
- Spotify listener: Open in Spotify per row; Send to a transfer tool shares
  the list and toasts the TuneMyMusic message; "Not personal yet" banner as a
  flush line when the mix predates the import.
- Unavailable song: muted row with "Not in Apple Music · skipped on play".
  Stale version: edit refused, list refreshed to the server's arrangement,
  toast says so.
- Empty ("Nothing on the tape yet") and could-not-load with Try again; a
  visible list survives a failed refresh with a toast.
- Reduced motion: no spring on lift or swipe. Reduced transparency: clusters,
  toast and reason band opaque.

## Owners

`client/lib/presentation/screens/queue_screen.dart`, the queue-ops API for
the insert operation, and the playback bridge for Play now.
