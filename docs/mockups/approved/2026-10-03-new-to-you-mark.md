# New to you mark

Approved by the founder 2026-10-03. Board:
`../2026-10-03-new-to-you-mark.html` (revision 1). Spec:
`../../superpowers/specs/2026-10-03-outside-library-picks-design.md`, Part C.
Plan Gate 1: `../../superpowers/plans/2026-10-03-outside-library-picks.md`.

## Winning variant

**Variant A.** The words "New to you" at the end of the artist line, on web
and iOS. The create-playlist wording was approved as drawn.

## Rejected

**Variant B**, a small "NEW" after the title. It shortens the title, and it
would be the only label beside a row title in the app.

## Locked behaviour

- The mark is words only: no box, pill, border, dot, icon or sparkle. It is
  not a control. Row height, targets and motion are unchanged.
- It is always visible; it does not wait for hover or a tap.
- The artist text gives way first. The mark is never shortened.
- **Web** (queue panel row): the artist line reads
  `{artist} · {duration} · New to you`. "New to you" is `--plum` at weight
  700, in the line's existing 11px. The separating dots keep the line's
  muted colour. Works beside the "Open in Spotify" link and in the narrow
  panel (760px and below).
- **iOS** (arrangement `TrackRow`): `{artist} · New to you`, the words in
  the status-word style (12.5 / w600) in `plum`. At text scale 1.5 and above
  the mark takes its own line under the artist, without the dot.
- **Not-personal mixes show no mark.** The "Not personal yet" banner already
  says the picks are not the listener's own. The server sends `newToYou`
  false for those sessions.
- **Create playlist**, only when the mix holds at least one new song:
  - Web, under the name field, in the dialog's 12px text, tied to the dialog
    as its description: "3 songs here are new to you. Creating the playlist
    adds them to your Apple Music library." Singular: "1 song here is new to
    you. Creating the playlist adds it to your Apple Music library."
  - iOS, a second helper line in the existing alert, 12pt: "3 songs here are
    new to you. Saving adds them to your Apple Music library." Singular:
    "1 song here is new to you. Saving adds it to your Apple Music library."
  - A mix of only the listener's own songs shows today's dialog unchanged.
- **Accessibility.** Web row label ends ", new to you"
  (`{title} by {artist}, track {n}, new to you`); the reason stays the
  description. iOS reads the row as one item ending "new to you", with no
  extra VoiceOver stop. The mark never relies on colour.

## As built (2026-10-03)

Web was checked in the browser preview (`?ui-preview`, states `conversation`
and `playlist`) in light and dark. iOS is covered by widget tests only; it has
not been looked at in a simulator. One accepted difference: on iOS, a new song
that also has no Apple Music match is read by VoiceOver as "..., New to you,
Not in Apple Music, skipped on play", so the label does not end with the
mark. New songs are catalogue matches, so this should not occur in practice.

## Covered by this approval

Web queue panel and iOS arrangement screen; light and dark; the narrow web
panel; iOS large text; the web and iOS create-playlist dialogs.

## Left open on purpose

No count of new songs in the mix header or meta line. The iOS alert keeps
its two existing titles ("Save as playlist" on the arrangement screen,
"Create playlist" from the conversation). Spotify-only listeners receive no
new songs yet; the mark beside the Open link is drawn for when they do.

## Expected owners

Web: `web/src/components/QueuePanel.tsx`, `web/src/components/Overlays.tsx`
(`SaveDialog`), `web/src/styles.css`, `web/src/api/mappers.ts`,
`web/src/domain.ts`. iOS: `client/lib/presentation/widgets/track_row.dart`,
`client/lib/presentation/widgets/foundation/status_word.dart`,
`client/lib/presentation/widgets/mix_handoff.dart` (`MixSaveDialog`),
`client/lib/data/dj/dj_models.dart`.
