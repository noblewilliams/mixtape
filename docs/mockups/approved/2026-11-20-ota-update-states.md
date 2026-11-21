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

## Revised November 21, 2026: "Update (restart required)" and one morphing glyph

Revision 3 of a new [board](../2026-11-21-ota-restart-orb-r3.html), after
[revision 1](../2026-11-21-ota-restart-orb.html),
[revision 2](../2026-11-21-ota-restart-orb-r2.html) and a
[copy board](../2026-11-21-ota-restart-copy.html). On the device the founder
found the bare close on tap abrupt, and chose to keep closing but word it as a
restart. Then they asked for an editorial label, a flat dot, and the dot
itself becoming the loader. They chose SF and the italic small line ("Italic").

These states replace the ones in the table above:

| State | Line | Glyph |
|---|---|---|
| Patch ready | "Update" (13 pt semibold, text ink), with "(restart required)" (7 pt italic, smoke) under it | a flat 8 pt green dot that breathes (2.4 s, down to 82%) |
| After the tap | no words: they slide 10 pt left and blur out | the dot stretches into the middle bar and turns plum, and the side bars slide out of it; it closes after 1.8 s |
| The start that boots the patch | none for 1.4 s, then "Updated" (ok ink) blurs in from the right | the bars, then they gather into one point and the check draws out of it |

- The small line is positioned on its own, so it never pushes the title row.
- Words slide 10 pt with a 6 px blur over 280 ms. The dot-to-bars morph
  takes 320 ms, and the gather-and-draw takes 480 ms.
- VoiceOver:
  - On the note: "Update, restart required. Double-tap to restart mixtape."
  - After the tap: "Restarting mixtape. Open it again to finish." (Nothing
    on screen says it, so VoiceOver must.)
  - On the next start: "mixtape updated."
- Reduced motion: nothing breathes, bounces, slides or blurs. Shapes and
  words swap at once.
- Rejected:
  - Words after the tap ("Back in a blink…").
  - A 3D glowing orb (r1 and r2), because the loader is flat.
  - New York serif (E2), which kept the 17 September no-serif rule.
  - Tracked-capitals small line.
- Open: the founder would like something more editorial than SF. Revisit if a
  type direction lands.
- Everything is drawn in code, because a patch can't add icon-font glyphs.
