# Approved native shell — revision 3

Approved September 17, 2026: founder replied "approved" to
[native shell revision 3](../2026-09-17-mobile-shell-r3.html) with three
amendments, applied to the board the same day.

## Winning direction

Four native tabs: Home, Mixes, Library, You. Flush lists on a visibly
gradient background, native controls, SF-only type, the cassette's prism as
the one decorative motif, and Apple Music's title and playback behaviour.

Rejected alternatives and why:

- Revision 1 (Home hub with a You sheet, or a tab bar as option B,
  handwritten marker titles): founder chose tabs and a new visual direction.
- Revision 2 (boxy cards, serif display type, sectioned Home): too boxy and
  too busy; containers made lists feel heavy; serifs rejected outright.

## Locked behaviour

- Home: large title, empty open space with one hint line, and a bottom panel
  with a drag handle holding the composer (stripe, mic, send) and at most three
  idea pills of equal weight. Pills fill the field and never send. No sparkle
  icon anywhere. Home stays empty while a mix plays.
- Mixes: native segmented control for Active/Archived; flush rows with a
  60 pt square cassette tile, title, meta, chevron; swipe left archives with
  Undo; long-press offers Rename and Version history. Every row is a
  conversation.
- Library: glass button cluster at the title; Sources and Playlists as flush
  lists with bold section words; status is a coloured word inside the subtitle.
- You: native inset-grouped lists; identity block with a square prism avatar;
  What the DJ knows; toggles for "Learn from my listening" and "Suggest mixes
  from my routines"; Account; Sign out; Together drawn as a planned ghost.
  Clear learned listening lives under What the DJ knows.
- Titles: SF heavy large title with Apple Music's top margin; on scroll it
  becomes a small centred title over a progressive blur with no bottom edge.
- Dock: floating mini-player (52 pt, 38 pt art) above a floating tab bar
  (56 pt, 22 pt glyphs, 10 pt labels, 22 pt margins). The tab bar minimises to
  the active tab on scroll and the mini-player widens. No mini-player when
  nothing plays; the layout never shifts when it appears.
- Conversation and arrangement: pushed from Mixes or from Home's send; glass
  back and action clusters; tab bar hidden inside a mix; Back returns to Mixes
  with the tab bar. Mix actions use the revision 1 tape button (40 pt) and
  label chip (36 pt). The More menu holds Rename and Version history.
- Now Playing: Apple Music layout; prism scrubber fill; the mix is one muted
  line with a 22 pt cassette; bottom actions Shape, Up next, Send to Music.
- Background: warm white falling to lilac grey with a violet glow from the
  bottom and pink/blue corner tints (light); black to deep violet (dark). Now
  Playing swaps the glow for the artwork's dominant colours.
- Prism: composer stripe and focus ring, playback progress, the You avatar, and
  the send key. One instance per screen. Never behind text.
- Square motif: artwork and cassette tiles at 3 pt radius, the avatar, the
  send key. Everything else uses system rounded shapes.
- Accessibility: 44 pt targets on every control; 200% text wraps titles and
  pills while the dock keeps its size; reduced motion stops hubs and
  cross-fades the title; reduced transparency makes glass, panel and blur
  opaque while keeping the gradient.

## Platform differences

- iOS 26+: genuine Liquid Glass through a real UIKit tab bar and mini-player
  hosted in the iOS runner and bridged to Flutter. This is the engineering
  choice, not a Flutter replica.
- Earlier iOS and Android: frosted fallback with the same geometry, blur and
  radius, a hairline edge and no refraction; minimise-on-scroll replicated in
  Flutter with the same timing.

## Unresolved implementation details

- Platform-view seam for the hosted tab bar and mini-player, including how
  Flutter routes hide and show the native chrome inside a mix.
- Voice input arrives before launch; the mic is drawn and reserved, with the
  listening state to be designed on the Home board.
- Exact artwork-colour extraction for Now Playing.

## Owners

`client/lib/main.dart` (shell, theme), a new native tab host under
`client/ios/Runner/`, `client/lib/presentation/screens/{home_screen,
chat_screen,queue_screen,playback_screen,music_sources_screen,
playlist_browser_screen,memory_screen,account_screen}.dart`, shared widgets
under `client/lib/presentation/widgets/`.

## Supersedes

- The approved September 8 Home revision 2 (compact global menu, Active/Archived
  text tabs, wordmark title): replaced by the tab shell and Home panel.
- The "native Material 3 shell" language in the September 8 parity and
  September 9 next-features approvals: the approved interactions stand; the
  shell and visual system are now this record.

Earlier records are not rewritten. Individual screen boards follow in the
order listed in revision 1 of the shape board.

## Implementation departures

- 2026-09-17, task 1.1: light `smoke` #6F686F → #696269 and light `muted`
  #8A838B → #857E86 so secondary text keeps 4.5:1 and meta text 3:1 against
  the bottom of the light gradient (#E6E0EA). The board's values fell to 4.17:1
  and 2.84:1 there. Dark values unchanged.
- 2026-09-18, task 6.1 (Now Playing): the volume row is omitted because the
  app player exposes no volume control (backlog); the meta line is artist only
  because tracks carry no album; Shape opens the energy assessment sheet, not
  the brief dialog, and is disabled when the version has no arc; the sheet
  forces dark tokens in both system themes for light text on artwork colours.
- 2026-09-18, sign-in: at the founder's request the screen now mirrors the web
  auth gate (`web/src/components/AuthGate.tsx`) rather than the board's plain
  wordmark-and-tape-buttons layout. It carries the product name in the web's
  handwritten marker (system Noteworthy, italic, tilted -2°), a cassette whose
  hubs turn continuously (stopped by reduced motion) tilted 4° on a soft drop
  shadow, the web's copy — "Your music, mixed for right now." and its blurb —
  and full-width pill provider buttons on the web's colours: Apple white-on-
  #111114 in the light theme and inverted to black-on-white in the dark one
  (Sign in with Apple HIG), Google on its own light and #131314 dark specs. The
  "Last used" note becomes the web's pencil note in the same marker at 13 pt.
  The reserved status line, the Google-unavailable reason and the Apple Music
  foot note are unchanged. SF remains the typeface everywhere else.
