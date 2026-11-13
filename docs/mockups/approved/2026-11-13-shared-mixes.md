# Approved shared mixes

Approved November 13, 2026: the founder replied "Approve the board with your
defaults and spec fixes" to the [board](../2026-11-13-shared-mixes.html).
Spec: `docs/superpowers/specs/2026-11-13-shared-mixes-design.md` (updated the
same day with the fixes below).

## Open questions, settled as the board's defaults

1. **Glyphs** follow the transport rule: Share is next-track, Stop sharing is
   stop, Remove is eject. The iOS share glyph was not chosen.
2. **SharedMixScreen header** is Back only. No ⋯, since it would hold one
   item.
3. **Web page actions:** Play is the tape button, Get the app is a label
   button, and Make your own mix is a quiet text link.
4. **Tape-colour og image** is the cassette alone on the tape colour, with no
   text or wordmark.

## Spec fixes adopted

- On iOS, Share and Stop sharing live in the header ⋯ menus of the
  conversation and the tape. The strip has no menu.
- The iOS Mixes row reads "From Ada · Today". The web row reads
  "From Ada · 10 songs · today".
- When no platform is chosen, the Apple Music buttons show. The first tap
  opens "Where do you listen?".
- A revoked share offers Remove only when a save exists. Otherwise it shows
  Back only.
- Link preview: `og:title` is the mix title, and `og:description` is
  "Ada shared a mix · 10 songs".

## Copy locked

- "Stop sharing?" / "People with the link won't be able to open it."
- The name page from Share has no Skip, and the line "Whoever opens your
  link will see your first name."
- The web modal: "Where do you listen?", with "We'll remember it on this
  browser."
- "This mix isn't shared anymore."
- `Listen to my mix “<title>” on Mixtape`, `From <name>`,
  `Shared by <name>`, `Link copied`.

## Not drawn

The web sender's Share in tape actions and the "Link copied" toast. Build
them with the existing tape-actions popover and toast.
