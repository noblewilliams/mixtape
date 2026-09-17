# Approved — web controls, revision 2

Founder approved on 2026-09-08: “approved”, after requesting the revision.
Board: [web controls](../2026-09-08-web-controls-states.html).

Locked: Forget is a focus-trapped modal with backdrop/Escape dismissal; action
popovers are absolute, minimal text actions with outside/Escape dismissal;
mix names edit inline; left swipe archives using song-removal thresholds and
undo; archived mixes remain restorable. A compact playlist picker floats above
the composer, which carries a small text attachment and detach action. Keep
source-exclusion controls inside the picker. Personal curation stays separate.

Covers desktop/mobile, light/dark, short screens, large text, reduced motion,
loading, error, uncertain-result, conflict and successful states shown. Reuse
existing shell/tokens, keep 44px targets, and preserve keyboard alternatives.
The first board's inline forgetting panel, rename dialog and full-width
inspiration section are superseded. Production writes are a separate gate.

Implementation owners: web API/client, App, Sidebar, Home, Conversation,
AccountDialog, YourMusicView/PlaylistBrowser, focused web-control components,
styles and regression tests. No redesign of concurrent import/native work.
