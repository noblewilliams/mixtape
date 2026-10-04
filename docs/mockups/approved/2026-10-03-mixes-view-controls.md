# Mixes views and theme switch approval — 2026-10-03

Approved explicitly by the founder ("approved, closet A and theme switch A, go ahead").
Board: [Mixes views and theme switch](../2026-10-03-mixes-view-controls.html). Web only.

## Locked direction

- **Tabs:** one shared Tabs component with Library's Playlists / Sources metrics
  (13 px, 25 px gap, 48 px tall, 2 px slate underline on the current tab, hairline
  under the row). Library and Mixes both use it. Mixes labels are **Active** and
  **Archived**. The page title stays **Mixes** on both tabs; the count line reads
  "7 mixes · recently updated", "1 mix · recently updated", "2 archived mixes ·
  recently updated", "0 archived mixes" (no suffix at zero), or "Loading mixes…".
- **View switch:** three icon buttons, List, Grid and Closet, in one hairline-outlined
  group at the trailing edge of the tab row. The selected view uses the sidebar's
  quiet current-row fill, not solid plum. Each button has a tooltip and the
  accessible name "List view" / "Grid view" / "Closet view" with pressed state.
  The choice persists as before.
- **List:** rows start at the page gutter with no inner indent, hairlines span the
  content width, the first row sits directly under the toolbar, row padding is
  10 px. The 80 px cassette, the single open button and the separate three-dot
  menu are unchanged.
- **Grid (new):** unboxed cassettes on the page, handwritten name on the label,
  name and "N songs · age" underneath, three-dot menu at the trailing edge of the
  name. Columns are `auto-fill, minmax(168px, 1fr)`; two columns at narrow width.
  Same actions as a list row (rename, tape settings, archive, restore); no swipe.
- **Empty, archived-empty and could-not-load states:** centred horizontally and
  vertically in the space under the toolbar, in every view. Art, wording and the
  single action are unchanged.
- **Loading:** title, tabs and view switch stay; skeletons follow the selected
  view (cassette rows, cassette tiles, or three blank spines on a shelf).
- **Closet (option A, shelves on the page):** no wall. The wooden shelves run the
  full content width on the app's own background, flush with the gutters; each
  shelf casts a soft shadow onto the page. Tapes start at the left, row capacity
  comes from the measured width with no ten-tape cap, and only the shelves that
  are needed are drawn. Tape, shelf, plant and bird art, hover lift, and the
  bird-at-the-edge rule are unchanged.
- **Theme switch (option A, reel sun):** a single 44 px icon button under Settings,
  centred on the nav icon column; top right on narrow screens. Light shows the sun
  drawn as a reel hub (disc, spindle hole, eight teeth); dark shows a crescent with
  two stars. Going dark, the teeth spin and wind in, the hub fills, a shadow slides
  across, the stars pop; going light reverses it and the teeth spring out. The page
  theme changes as a circle opening from the switch (View Transitions). It remains
  a `switch` named "Dark mode"; the tooltip names the action.

## Accessibility and platform behavior

Light and dark, desktop and 390 px, larger text, loading, empty, archived empty,
refresh failed, could not load, one mix, a long name and 34 mixes are covered.
Reduced motion: the theme and the icon change instantly, tapes and tiles do not
lift. Browsers without View Transitions, or a hidden tab, change theme instantly
while the icon still animates. Icon-only controls keep 44 px tall effective
targets; the three view buttons are about 34 px wide (40 px at narrow width), as
drawn on the board. In the grid each menu button is named "Mix actions for
{mix name}".
State is never colour-only: tabs carry the underline and current state, the view
switch carries pressed state, the theme switch changes shape.

## Rejected alternatives / superseded decisions

- Closet B (the wall fills the page) lost: a heavy slab on the light theme.
- Theme switch B (flip the tape, side A / side B) lost: a second cassette on a
  screen already full of them, and unreadable at 50 px.
- Supersedes the "List view / Closet view" text switch and the pill theme switch
  from the 2 October navigation approval, and the centred rack wall (width cap,
  sage wall, sunlight streaks) from the 27 September rack approval. Tape materials
  from that approval stand.
- Reopens "square tape tiles" rejected on 25 September, as an unboxed grid. The
  list remains the default view.

## Unresolved

Returning to "match my system" after choosing a theme is not designed. Native is
unchanged.

## Owners

`web/src/components/`: new `Tabs.tsx` and `ViewSwitch.tsx`, `Home.tsx`,
`YourMusicView.tsx`, `SessionControls.tsx`, `UiStates.tsx`, `TapeRack.tsx`,
`tape-rack.css`, `ThemeToggle.tsx`, `Sidebar.tsx`, `navigation-layout.css`,
`web-controls.css`, `your-music.css`; `web/src/theme.ts`, `theme.css`,
`ui-polish.css`, `styles.css`, `domain.ts` (`CollectionView` gains `grid`);
preview harnesses `UiPolishPreview.tsx` and `web/qa/tape-rack.tsx`.

## Implementation notes — 2026-10-03

Implemented locally and checked against the board in the browser (list, grid,
closet, centred empty state, light and dark, phone width, Library tabs). Small
departures from the board, all reported to the founder: the menu button keeps the
existing "•••" glyph; in the grid the mix name is plain text and rename lives in
the menu; a phone-width shelf holds four tapes rather than the board's three
because the smaller plant and bird leave room; the product has no larger-text
setting, so the board's scaled sizes are not a feature. The circular page reveal
could not be captured mid-animation in the agent's preview and needs a founder
eye in a real browser, Safari included.
