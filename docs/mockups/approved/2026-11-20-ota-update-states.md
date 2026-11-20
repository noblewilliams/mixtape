# Approved over-the-air update note

Approved November 20, 2026. The founder replied "Approve bars" to revision 2
of the [board](../2026-11-20-ota-update-states.html), after two rounds of
notes:

1. The updating state shouldn't take over the whole screen. It should be a
   tiny note on the same row as "Home", and also visible on You.
2. Say "Update available", not just "Update", and use a loader other than
   tape, because there is already too much tape on screen.

This supersedes the full-screen updating screen and the "A new version of
mixtape is ready · Restart" toast from the first build of decision
2026-11-20 (neither shipped).

## Winning variant: A, three level bars

| State | Line | Glyph | When |
|---|---|---|---|
| Nothing | none | none | almost always |
| Update available | "Update available", 12 pt/600 plum | a still 7 pt record dot | a patch is downloaded |
| Updating | "Updating" | three level bars, one 900 ms ease-in-out loop, offset a third each | 1.8 s after the tap, then the app closes; 1.4 s on the start that boots the patch |
| Updated | "Updated", in okay green | check | 2.5 s, then a 320 ms ease-out fade |

- It sits at the right edge of the Home and You large-title rows, centred on
  the title's height, in a 14 pt glyph box with a 6 pt gap. It is 26 pt
  drawn, 44 pt tall to touch. There is no capsule, glow, prism or tape.
- The glyph is pinned to the right, so only the word's width changes between
  states. The title never moves.
- The word changes with a 280 ms fade-through (out, then in).
- Only "Update available" is tappable. Taps on it start the 1.8 s close.
- The launch covers nothing. The app is usable at once on the start after an
  update.
- If the listener starts on another tab, the note plays on Home or You if they
  get there within those 4 s. Otherwise it is skipped.

## Accessibility

- Accessible name when an update is available: "Update available. Double-tap
  to restart mixtape and finish the update."
- After the tap, VoiceOver hears: "Updating. mixtape will close. Open it
  again to finish."
- Announced once on the next start: "mixtape updated."
- Word, glyph and colour all change, so the state never relies on colour.
- 200% text: the line grows and the glyph box grows to 20 pt. Where it no
  longer fits beside the title (320 pt), it drops to its own line under the
  title, right-aligned. It never wraps or truncates.
- Reduced motion: the bars hold still at their resting heights, and the fade
  becomes an instant hide.
- Dark mode: plum ink becomes the light text colour, and green becomes the
  dark-mode okay green.

## Rejected

- **B, a thin filling ring:** it reads as a generic system spinner, and the
  house rules ban spinners.
- **C, the reel (revision 1):** the founder said there is already too much
  tape on screen.
- **The full-screen updating screen and the toast (first build):** the founder
  wanted something much smaller.

## A departure from the house rules

The house rule says loading is "the cassette with its hubs turning". This
note is the one exception, at the founder's request. Everywhere else keeps the
reel.

## Unresolved

- Signed-out listeners in first run have no title row. For them the patch
  runs from the next start with no note.

## Owned by

- `client/lib/presentation/widgets/update_status_note.dart` (new)
- `client/lib/presentation/providers/app_update_provider.dart`
- `client/lib/presentation/screens/home/home_screen.dart` and the You tab,
  through `LargeTitleScaffold`
- `client/ios/Runner/ShellDock.swift` (the hidden mini-player's tap fix, no
  visual)
