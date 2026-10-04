# Mixtape icons

Approved September 25, 2026 in `docs/mockups/approved/2026-09-25-ui-polish.md`.

- `app-icon.svg`: full-bleed right-reel crop, viewBox `108 22 78 78`.
- `favicon.svg`: simplified complete cassette for browser tabs and web shortcuts.

Both derive from `web/public/tape.svg`; that full illustration remains unchanged.
Do not add rounded corners to exported iOS images: the system applies its mask.

Regenerate the existing iOS asset catalog and web outputs using
`node scripts/generate-brand-icons.cjs` with the `sharp` package available.
`SHARP_MODULE_PATH` may point to an installed absolute `sharp` module directory.
The generator checks every PNG's exact dimensions and absence of an alpha channel.

Only the iOS native runner exists in this checkout. Android icon packaging should
reuse the source artwork if an Android runner is added later.
