# Mobile Exportify discovery fix — 2026-09-09

The founder reported no visible Spotify import path while testing locally.
The native guide/parser already existed, but Home's setup action was gated on
incomplete Spotify onboarding. Your music offered import for an empty source
list or an existing Spotify source only. Apple-only listeners had no add path.

Fix: Home actions always exposes Add Spotify music, opening the existing
Exportify guide without changing the preferred service. Your music also exposes
Add Spotify music when no Spotify source exists, including Apple-only accounts.
The empty state retains direct file selection alongside the guide. Return from
the guide refreshes source state. Service selection copy no longer claims that
Spotify requires an official data request first. No backend or schema change.

Red-first regressions reproduced both missing entry points. After the fix,
61 tests passed across source management, Home waiting, Home actions, request
steps and handed-in archives. The new tests assert the Exportify guide and
file-choice action are reachable while Apple remains the chosen service.

The change is in the shared local client checkout. No new binary was installed
and no TestFlight upload was performed. Reload/rebuild this checkout to see it.
The six-feature program remains approved and pending implementation; this
navigation fix addresses the founder's immediate local-testing blocker.
