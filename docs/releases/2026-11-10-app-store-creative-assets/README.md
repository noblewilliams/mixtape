# App Store creative assets (header + search results)

Companion to `../2026-11-07-app-store-screenshots/`. Apple added these placements to App Store Connect on 2026-10-05 (iOS/iPadOS 27 storefront).

| File | Placement | Size | Notes |
|---|---|---|---|
| `header.png` | Product page header | 3840 × 1646 (21:9, exact) | PNG, RGB, no alpha |
| `search-results.png` | Search results | 3840 × 2560 (3:2, the max) | PNG, RGB, no alpha |

**Story:** your words (ivory paper tape) go into the DJ (the cassette) and come out as a mix (prism rainbow tape). The header tells it as pure illustration. The search asset says it in plain words ("Say the moment. Get the mix.") next to the real composer and mix card, following Apple's "state the obvious" guidance for that placement.

**Safe areas:** Apple doesn't publish pixel numbers; these come from measurements of Apple's templates (AppScreens, Blake Crosley). Header: 1646 × 661 centred. Search: 2168 × 1030 centred. Everything you need to read sits inside them. The ribbons outside them are decoration for wider crops (iPad).

**Content rules checked:** no prices, URLs, other platforms' names or logos, awards, or copyright symbols; suitable for 4+.

## Re-render

The PNGs are gitignored like the screenshots (large, kept locally only); the sources in `src/` are the record.

```bash
bash docs/releases/2026-11-10-app-store-creative-assets/src/render.sh          # finals
bash docs/releases/2026-11-10-app-store-creative-assets/src/render.sh '#debug' # with safe area outlined
```

This uses Playwright's cached `chrome-headless-shell` and the `sharp` module in `server/node_modules`. It stops if the page throws a script error, flattens alpha, and checks the exact output size. Fonts are macOS system faces (SF Pro, Noteworthy), so render on a Mac.

## Uploading

Header and search assets have to be approved before App Store Connect lets you pick them under "Browse approved assets". Either submit them in Asset Library as standalone assets (they're reviewed against the latest app version), or attach them to the next version submission.
