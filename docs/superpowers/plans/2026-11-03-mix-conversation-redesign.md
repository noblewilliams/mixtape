# Mix conversation redesign — plan

**Status:** the founder approved board revision 3 on 2026-11-03
(`../../mockups/2026-11-03-mix-conversation-redesign.html`; locked record:
`../../mockups/approved/2026-11-03-mix-conversation-redesign.md`). The
decision is in `../../decisions.md` → 2026-11-03 mix conversation redesign.

Work happens on branch `mix-redesign` in the worktree
`/Users/admin/Documents/work/mixtape-mix-redesign`. Client only: no server
changes. Each task follows the house cadence: red-first widget tests, then
the implementation, a reviewer pass and one fix round.

## Shared contract (both tracks rely on it)

- **Menus:** `showMixtapeMenu<T>(context, {actions, title?, message?})` in
  `widgets/foundation/mixtape_menu.dart`.
  - The popover anchors to the render box of `context`. Callers therefore
    pass the *control's* context, using a `Builder` where needed.
  - If `context` has no usable box, it centres under the top of the screen.
  - `cancelLabel` is removed, and there is no Cancel row: tapping the
    barrier returns null.
  - `MixtapeMenuAction` gains `Widget? leading` (drawn before the label) and
    `IconData? icon` (trailing glyph).
  - `isSelected` draws a trailing tick. `isDestructive` draws red.
  - New `bool separatorBefore` draws the 6 pt group gap.
  - `mixtapeMenuCancelKey` is deleted; tests dismiss by tapping the barrier.
  - Rows keep `action.key`.
- **Shape menu:** `energy_journey.dart` exports
  `Future<void> showEnergyShapeMenu(BuildContext anchor, {required TextEditingController controller, EnergyArc? selected, required ValueChanged<EnergyArc?> onChanged})`.
  It applies the choice straight away, with the same brief and toast rules
  the sheet had. `EnergyShapeGlyph(arc, size)` draws the curve.
  `EnergyControl` uses both.
- **Header buttons:** `GlassButton` paints its own 34 pt glass circle, with a
  17 pt glyph and a 44 pt target. `GlassCluster` becomes a plain `Row`
  with a 4 pt gap: same API, no capsule. The glass is `LiquidGlassSurface`
  (native iOS 26+, frosted fallback) with a circular radius.

## Track A — foundation (files A owns)

`widgets/foundation/{mixtape_menu,glass_cluster,liquid_glass_surface,frosted_surface}.dart`,
`widgets/energy_journey.dart`, `widgets/home_panel.dart` (only if the shape
chip needs it), `ios/Runner/*` (only if the native glass view needs a circle
mode), and every *other* `showMixtapeMenu` call site:

- `screens/memory_screen.dart`
- `screens/playback_screen.dart`
- `screens/playlist_detail_screen.dart`
- `screens/playlist_edit_screen.dart`
- `widgets/collection_review_form.dart`
- `widgets/mix_home_row.dart` (long-press lifts the row)
- `widgets/playlist_inspiration.dart` (the chip menu only)
- `widgets/routine_suggestions.dart`

Track A also owns their tests.

A1. Popover menu plus the migration of A's call sites.
A2. Glass header buttons.
A3. Shape popover with curves, and the chip glyph.

## Track B — mix surfaces (files B owns)

- `screens/chat_screen.dart`
- `screens/queue_screen.dart`
- `screens/mix_history_screen.dart`
- `widgets/{mix_handoff,conversation_turn,queue_card,tape_settings_dialog,open_tape_settings,mix_prompt_input,mix_energy_summary}.dart`
- New widgets as needed (for example `widgets/tape_strip.dart`,
  `widgets/version_marker.dart`)
- Their tests

B1. Lyric transcript, version markers, the cassette working state and the
    failed line.
B2. Bottom panel: the tape strip, the + menu and the composer. The
    attachment row and the action row go; Shape goes into the + menu before
    the first mix, using `showEnergyShapeMenu` anchored to the + button.
B3. Split Play in `mix_handoff.dart`: the remembered destination (stored the
    same way as other device preferences), "Play in Music", the arrow
    popover and the Spotify rules. Header: Back, title and More, with Version
    history moved into More.
B4. Tape screen: cassette header, a title that appears on scroll, the
    sticky bar, and the hint moved under the songs. Every mix cassette uses
    the chosen tape colour.
B5. Tape settings sheet: name field, families and a cassette grid. The
    sheet is opaque.
B6. Versions: Now/Earlier sections, readable times, the made-from line
    taken from the transcript, and the preview with a sticky "Use this
    version".

## Done when

- `flutter analyze` is clean and `flutter test` is green.
- On the iOS simulator, the screens match the board in light and dark, and
  at the largest text size.
