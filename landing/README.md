# Mixtape landing

Independent React/Vite marketing page. The authenticated client remains in `../web`; this package does not read a listener's library, contact the DJ API, or mutate playlists.

```sh
npm ci
npm run dev
npm test
npm run build
```

Local preview: `http://127.0.0.1:4174`. Static output: `dist/`.

## Destinations

Copy `.env.example` to `.env.local` when overriding the defaults:

- `VITE_APP_URL`: browser app destination, defaults to `/app/` on the current domain.
- `VITE_DOWNLOAD_URL`: real App Store or TestFlight link. Until configured, the download button opens a keyboard-accessible dialog explaining that the link is unavailable and offering browser access. Do not invent a store URL.

These values are public build-time configuration, not secrets. The root `netlify.toml` builds both packages with `node scripts/build-site.mjs`. The combined root `dist/` serves this page at `/`, the authenticated app at `/app/`, and preserves `/api/auth/*` as the same-origin auth proxy. Run `node scripts/verify-site.mjs` after building. For local landing-only development, override `VITE_APP_URL` with the local web app URL if needed.

## Behaviour

The page covers the hero, scroll-driven mix demonstration, four import/memory cards, FAQ and a full-width graphic footer. The demonstration uses real song metadata and artwork from Apple’s public catalog; no audio plays. All three demo states remain accessible through their step buttons.

GSAP owns hero/artwork parallax, scroll-driven demo state, prism colour travel and the closing scene. Motion for React owns demo scene transitions, song arrangement and FAQ expansion. CSS owns sticky layout, decorative rotation and hover effects. No two libraries write the same element's transform. The demo falls back to ordinary flow for reduced motion or when its height cannot fit the viewport.

Decorative equalizer loops pause offscreen. The page respects the device's reduced-motion setting and uses the device preference without visible motion controls. Library-sync recommendations explicitly favour the native app for Apple Music while preserving browser entry.

## Assets

Fonts and decorative images are locally hosted; demo song covers use Apple catalog URLs. The serif is Instrument Serif; body type is DM Sans, both under the licenses included in `public/fonts/`. The wordmark retains the app's existing system-font treatment. Tape geometry and the favicon derive from the existing app assets.

Hero: `public/images/prism-cassette.jpg`. The original image was created with the built-in image-generation tool and converted to JPEG for delivery. Its prompt is recorded in `art-direction.md`. The original is retained outside the project; the page uses only its local project asset.

## Validation — September 27, 2026

- Production TypeScript/Vite build passes.
- Three interaction tests pass: missing download destination, accessible demo steps, and respecting device reduced motion.
- Browser checks: 360, 390, 768, 1024 and 1440 pixel widths; no page overflow or overflowing controls. Desktop and phone compositions visually inspected.
- Verified sample controls, FAQ expansion, download dialog/Escape/focus restoration, and device reduced-motion behavior. Browser console has no errors or warnings during the checked flow.
- The mobile download destination remains outstanding. Provider release claims should be checked against the deployed app before publication; source code alone is not release evidence.

## Revision — September 28, 2026

Removed navigation and redundant copy/services section, added scroll steps, import cards, unified right-arrow CTA hover, and merged the footer into the prism scene. Favicon and all illustrated cassettes use the app’s transparent tape.svg. The regenerated hero corrects the physical label around both sides and below the reel window. Apple archive import stays marked as upcoming.

Follow-up: hero now fills the desktop viewport with a smaller cassette in a wider prism scene. The demo heading “From a feeling to a mix” sticks with the widget. Removed the marquee and visible motion controls; moved the footer tape into the former oversized wordmark position. Device reduced-motion support remains.

Latest refinement: the sticky heading/demo group is vertically centred from its measured height, with a shorter scroll runway. Messages match the app’s unboxed right-aligned listener and left-aligned DJ treatment. The footer uses one responsive row of 44px closet spines with 3px gaps, grounded at the page bottom; no wooden shelf.

Latest demo: keep one conversation across scroll steps. Type the listener message, show a brief thinking state, type the DJ reply, then reveal/update the mix. Fast scrolling queues the second exchange after the first; reduced motion shows content immediately. Final “Play mix” and “Create playlist” actions open the actual app because sample songs are illustrative. Footer closet now fills the full width, lifts on hover, and uses unique titles and varied case/label colours. Four focused tests cover entry points, reduced motion, retained conversation and timer sequencing/cleanup.

Demo smoothness: cover art and durations follow stable song identities through reordering. Typed messages reserve full text geometry and response height; conversation scroll runs once per exchange rather than per character. Smaller listener text, position-only song transitions, smooth step clicks and scroll threshold dead bands reduce jitter. The conversation does not intercept wheel scrolling.

Song metadata: Apple iTunes lookup IDs 455448132, 997914096, 455448137 and 828259377 (Nightcall, Space Song, A Real Hero, Midnight City). Cover images use catalog artwork URLs and stay keyed to song identity. The listener request now reads “I need a mix for a late drive home, a little dreamy and nostalgic.” Listener type is 10px/600.

## Same-domain release — September 28, 2026

Landing and app ship together to `https://miixtape.netlify.app`: `/` is the landing, `/app/` is the web app. Sign-in and account-link callbacks use the app build base. The release retains the previously published web app version apart from this routing adjustment. The download dialog remains until a real store or TestFlight URL is configured.
