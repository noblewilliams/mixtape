# Web navigation cleanup approval — 2026-10-02

Approved explicitly by the founder after revisions to `docs/mockups/2026-10-02-web-navigation-cleanup.html`.

- Sidebar: Home, Library, Mixes; Settings and animated SVG light/dark switch at the bottom. One icon/label alignment and a visible active state. Narrow screens put destinations together above the content.
- Home: behavior-based recommendation when available, recent mixes, and a simple bottom composer. No heading/helper above the composer; 14px input with changing idle placeholder, voice and send. Transcripts are editable and never sent automatically. Loading/error stays within its section; no recommendation means no empty recommendation block.
- Library: full width, compact square playlist grid (selected over thumbnail rows), inline source status beside its title. Matching source rows with provider marks and compact actions.
- Mixes: Active/Archived tabs and List/Closet switch share one toolbar. Existing approved cassette art and rack remain.
- Settings: listening learning, recommendation preferences, remembered preferences, account and signout.
- Light/dark, narrow viewport, loading/empty/error/success/unavailable states and larger text covered by the board. Theme choice persists; reduced motion disables morphing and placeholder cycling.

Owners: Sidebar, HomeDashboard, HomeComposer, Home, AppSettings, ThemeToggle, YourMusicView, PlaylistBrowser, RoutineSuggestions, App, theme and layout styles under `web/src/`.

This supersedes the earlier web navigation placement, not the approved cassette/rack or dialog designs. Native navigation is unchanged. Existing session timestamps only identify recent updates, so the implementation labels the section “Recent mixes”; true listening history ordering remains a separate backend capability. Browser microphone and remote transcription still need live acceptance. The local backend's pending tape-color migration is independent of this UI approval.

## Founder refinement — 2026-10-03

Recent mixes use a single full-width column. In Home and Mixes list view, artwork, title and row space are one native button that opens the mix. Remove the separate visible Open button; rename moves into the independent three-dot actions menu. Keyboard access and archive/restore remain available. This supersedes the board's two-column recent layout and inline title-to-rename behavior.

## Refresh refinement — 2026-10-03

Founder explicitly chose “Keep last-loaded content visible” during refresh. Preserve the existing page and content, with a floating top-centred “Refreshing…” badge; no full-screen session-check replacement for a previously loaded workspace. Saved content stays read-only until authentication confirms it. The badge uses the existing theme tokens, accessible status text and a static reduced-motion indicator. This supersedes the intermediate full-screen session-check state.
