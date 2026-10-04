# Compact Library filters — October 3, 2026

Playlist search and source filtering now share a 34px height, 6px vertical
padding, and 6px corner radius. Focus changes the existing border to the theme's
smoke colour without an outer ring. The native source select retains its keyboard
behavior and uses a theme-aware caret inset 12px from its right edge, with space
reserved for it at all viewport widths.

Validation: 11 focused playlist/style tests and the web production build passed.

Library entry follow-up: the navigation button always selects Playlists, including
when returning from Sources or a provider panel. Legacy `auto` section state maps
directly to Playlists, so source-summary loading cannot flash Sources or decide
the initial tab. Explicit Sources/provider navigation remains available; active
sync results can still be opened using View progress from Playlists.

Source-row polish: statuses use plain muted text with no inherited pill fill,
including dark mode. Source action buttons fit their labels, center the text,
and use 32px minimum height with balanced padding. This resolves the shared
status variant styles overriding the row's background reset and the Connect
button's unused minimum-width space. Eight source/style tests and build pass.
