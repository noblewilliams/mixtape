# Approved restart countdown

Approved November 24, 2026. The founder replied "approved r3" to
[revision 3](../2026-11-24-ota-restart-countdown-r3.html), and asked to keep
the existing haptics. Notes on the earlier rounds:

1. [Revision 1](../2026-11-24-ota-restart-countdown.html): prefer A, the
   popover from the note, over B, the centred modal. But the card was too
   large: "very minimal".
2. [Revision 2](../2026-11-24-ota-restart-countdown-r2.html): A2, the one-line
   capsule, beats A1, the compact popover. Use the composer's coloured bar "to
   feel like one design system".

This supersedes the 1.8 s "bars, then close" tap in
[2026-11-20-ota-update-states.md](2026-11-20-ota-update-states.md) (revised
2026-11-21). The note's ready state ("Update" / "(restart required)" / the
breathing green dot) and the next start ("Updated" with the check) are
unchanged.

## The capsule

- Tapping "Update" swaps the note for a glass capsule anchored at the note's
  right edge and centred on the title line: the level bars, "Restarting in 5"
  (13.5 pt semibold, tabular digits), a hairline divider, "Cancel" (smoke), and
  "Now" (plum, semibold). It is 38 pt tall, fully rounded, and grows out of
  the note's position.
- The countdown line is the composer's prism stripe: 2 pt, six stops, 85%
  opacity, along the bottom edge and inset clear of the rounded ends. Over the
  5 s it shortens from the right with the colours fixed in place, so violet
  goes first and pink last.
- The number counts 5 → 1, one second each, with a short slide-and-blur per
  step. At 0 the line reads "Restarting", the bars keep playing for a moment,
  and the app closes.
- When music is playing from mixtape, a small glass tag "Music will stop"
  hangs under the capsule's right end.
- Cancel puts the note back. Leaving the app during the countdown cancels it,
  and the quiet update takes over.
- Taps outside the capsule do nothing. Cancel is the only way out.

## Haptics (kept)

- The tap that opens the countdown plays the same lightest click
  (`selectionClick`) the dot-to-bars change has played since 2026-11-21.
- Cancel plays the app's dismiss feel. Now plays its call-to-action feel.
- Nothing plays per second.
- The next start keeps its one soft click as the check finishes.

## After the close

- Just before closing, the app schedules a local notification for one second
  later: "mixtape is up to date" / "Tap to jump back in." It is only sent when
  notifications are already allowed. The app never asks for permission for
  this.
- Quiet update: once a patch is waiting and the listener leaves the app, the
  app closes itself 3 s later in the background. It holds off while music is
  playing, a voice note is recording or transcribing, an import or library
  sync is running, or a mix send has not yet been handed to the server. No
  notification on this path.

## Accessibility

- VoiceOver: when the capsule opens, VoiceOver hears "Restarting mixtape in 5
  seconds to finish the update. Restart now, or Cancel." "Now" is read as
  "Restart now". It doesn't read each second.
  With VoiceOver on, the countdown doesn't run itself: the capsule waits for
  Now or Cancel.
- Largest text: the capsule grows to 48 pt. When it doesn't fit beside the
  title, it sits on its own line under the title, right-aligned.
- Reduced motion: it fades in instead of growing, the number swaps without a
  slide, the stripe steps down once a second, and the bars hold still.
- Cancel and Now each tap like 44 pt buttons.

## Rejected

- B, the centred modal: blocks the app and reads as an alert.
- Revision 1's popover: too large.
- A1, the compact popover: the founder preferred the capsule.

## Owned by

- `client/lib/presentation/providers/app_update_provider.dart` (countdown and
  quiet-apply timeline)
- `client/lib/presentation/widgets/update_status_note.dart` (the note and the
  capsule)
- `client/lib/data/updates/app_updater.dart` (the reopen notification)
