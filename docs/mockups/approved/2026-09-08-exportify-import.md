# Exportify import approval

- Approved 2026-09-08: `../2026-09-08-exportify-import-states.html`.
- Founder approved all 17 states with two corrections: compact secondary
  actions (especially Cancel); no decorative left border on any section or
  container anywhere in the app. This applies to existing product surfaces too.
- Cancel is a content-width text action, without a filled or outlined box.
  In the progress card it sits beside the current file/status heading, without
  a separate action row that adds height to the panel.
  Preserve a 44px effective touch target without stretching the visual control.
  Action rows wrap, rather than forcing every button to fill the row.
- Status uses text and existing neutral surfaces, never a coloured left rail.
- Locked: quick Exportify ZIP/CSV import, reviewed collection roles and targets,
  additive likes by default, explicit replacement confirmation, preservation
  of other collections/history, optional Go deeper, and existing interview gate.
- Covers desktop/mobile web and native iOS, light/dark, large text, reduced
  motion, progress, success, partial success, failure, and stale review.
- Native keeps Material 3 controls; web keeps the Your music/Sources shell.
- Supersedes the old request-first Spotify onboarding in the 2026-09-04 web
  import approval. Existing official history parsing and interview behavior stay.
- Source owners: web/src/import, web/src/components/SpotifyMusicView.tsx,
  web/src/components/ImportPanel.tsx, client/lib/import,
  client/lib/presentation/screens, server/src/listening, server/src/playlists.
- Real Exportify ZIP acceptance and production rollout remain separate checks.
- Corrections verified in the rendered desktop and 320px mobile reading state
  and dark recovery state. Existing affected screens pass 34 web and 23 Flutter
  tests. The new Exportify parser and collection refresh protocol are still
  implementation work; this record is visual approval, not import acceptance.
