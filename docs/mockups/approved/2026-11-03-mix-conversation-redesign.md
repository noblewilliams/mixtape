# Approved mix conversation redesign

Approved November 3, 2026: the founder replied "Approve, build it" to
[revision 3](../2026-11-03-mix-conversation-redesign.html). Revision 1 drew
the five surfaces. Revision 2 added smaller chat type, a cassette loader,
split Play and app-wide popover menus. Revision 3 made your own lines heavier,
dropped the "Play here" subtitle, drew the shapes as curves, kept the compact
Mix | Album toggle and made the header buttons small glass circles.

Supersedes parts of the
[conversation states](2026-09-17-mobile-conversation-states.md) and
[arrangement states](2026-09-17-mobile-arrangement-states.md) approvals: the
bubble turns, the in-transcript tape card, the grey Version chip, the
attachment row and the three-action row. It also reverses smoke round three,
note 8 (menus as bottom action sheets), as recorded in `docs/decisions.md`.

## Winning variants and rejected alternatives

- Split Play (B) won over a single Play with "Play in Apple Music" in More (A).
  The founder preferred to keep where-to-play one tap away.
- An anchored popover won over bottom action sheets for every action menu.
- Older turns fade as they scroll away. A fixed "latest exchange is bright"
  rule was the fallback; the founder accepted the default without comment.

## Locked behaviour

- **Transcript.** No bubbles.
  - DJ lines are about 17 pt, weight 650, in text ink, on the left.
  - Your lines are about 15 pt semibold (650), smoke, right-aligned, at most
    84% of the width.
  - Turns outside the lower part of the viewport fade to about 34% opacity
    and return to full as they scroll in.
  - The top of the transcript fades out under the header.
  - The fade is never applied to semantics.
- **Version markers.** One line: a 34 pt cassette in the mix's tape colour,
  "Version n" and the song count, with a chevron for earlier versions. It
  opens history at that version. The current version's marker reads
  "current" and has no chevron. The transcript has no "The tape" card.
- **Working.** A 56 pt cassette in the tape colour, hubs turning, followed by
  "The DJ is listening…". It sits where the next DJ line will appear.
  - Reduced motion: the hubs stand still.
  - The status region still announces "The DJ is working".
- **Failed turn.** One line in error ink under the message it answers, with
  a Resend link (44 pt target).
- **Bottom panel**, top to bottom:
  1. When a mix exists, the tape strip: a 48 pt cassette in the tape colour,
     the title, "Version n · N songs", and split Play. Tapping anywhere else
     on the strip opens the tape.
  2. A 44 pt round + button beside the composer. The + menu holds "Start
     from a playlist". Before the first mix it also holds "Shape the energy".
     Attached-playlist chips keep showing above the composer, with their
     locked states.
  3. The composer.
  - There is no attachment row and no three-action row.
- **Split Play.**
  - The main part plays at the remembered destination. The default is the
    app's own player.
  - When the destination is Apple Music, the main part reads "Play in Music".
  - The arrow (its own 44 pt target, named "Choose where to play") opens a
    popover with "Play here" and "Play in Apple Music". The current default
    carries a tick. Picking one plays there and becomes the default.
  - "Playing" with the prism meter shows when the app player is on this mix.
  - Spotify listeners keep today's rules, and the transfer-tool handoff takes
    the arrow's place.
- **Headers.** Back on the left, the title, one More button on the right.
  - The conversation loses its queue button.
  - The tape screen loses its history button; Version history is in More.
  - The More menu holds Version history, Tape settings, Rename, and
    Archive/Restore.
- **Tape screen.**
  - A 150 pt cassette in the tape colour, tilted -4°, then the title
    (wrapping to two lines) and "N songs · M min · version n".
  - The navigation bar title appears only after the header scrolls away.
  - A sticky bottom bar holds split Play and Create playlist.
  - "Tap a song for its note" sits under the last song.
- **Tape colour.** Every cassette for a mix (strip, markers, tape header,
  versions, Mixes rows) uses the chosen tape colour, falling back to the
  seeded colour only when none is saved.
- **Tape settings.**
  - An opaque bottom sheet with a Name field.
  - Eight family swatches (44 pt targets, named "Reds"… "Neutrals"; the
    selected one has a ring).
  - A 3×2 grid of the family's cassettes with colour names. The selected one
    lifts, tilts and turns its hubs once.
  - Picking a colour saves immediately. Done only closes the sheet.
  - The sheet opens on the family of the colour currently shown.
- **Versions.**
  - Large title "Versions", with **Now** and **Earlier** sections. There is
    no Current badge and no footnote.
  - Rows: a 64 pt tilted cassette, "Version n", "Today, 15:40 · N songs ·
    M min", and the user message that produced the version (clamped to two
    lines, taken from the transcript). Restored versions say "Restored from
    version n" instead.
  - Tapping Now opens the tape. Tapping an earlier version opens a preview:
    cassette header, "Made from" quote, songs, and a sticky "Use this
    version" bar. The preview has no "Back to versions" link.
- **Menus.** One presentation, everywhere:
  - An anchored popover on the sheet surface, with 44 pt rows and optional
    subtitles.
  - A tick for the selected entry; destructive entries in red, last, behind
    a separator.
  - Tapping outside dismisses it, so there is no Cancel row.
  - Long-press menus lift the row they belong to.
  - Reduced transparency makes the menu opaque.
- **Shape.** A popover with a drawn curve per shape (flat, rise, fall, arc)
  and the shipped subtitles. Picking a shape applies it at once. "Clear
  shape" appears only when a shape is set. Too long a brief shows as a toast.
  The chip shows the chosen curve. The compact Mix | Album toggle stays as it
  ships.
- **Header buttons, app-wide.** Each one is its own glass circle: 34 pt
  visible, a 17 pt glyph and a 44 pt target, with 4 pt between neighbours.
  - Native Liquid Glass on iOS 26 and later, frosted elsewhere, opaque with
    reduced transparency.
- **Sheets that stay sheets:** Keep this mix, AI consent, library sync,
  import, the playlist pickers, routine setup, and Now Playing's queue.

## Owners

- `client/lib/presentation/widgets/foundation/{glass_cluster,mixtape_menu}.dart`
- `client/lib/presentation/widgets/energy_journey.dart`
- `client/lib/presentation/screens/{chat_screen,queue_screen,mix_history_screen}.dart`
- `client/lib/presentation/widgets/{mix_handoff,conversation_turn,tape_settings_dialog,queue_card,playlist_inspiration}.dart`

Web is not covered.
