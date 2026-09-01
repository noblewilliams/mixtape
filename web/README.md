# mixtape web

React, Vite, and TypeScript implementation of the approved tape-and-glass identity. The production entry point uses Better Auth for Apple and Google sign-in, reads sessions and mixes from the Hono API, and uses MusicKit on the Web for Apple Music authorization and playback.

## Run it

```bash
npm install
cp .env.example .env.local
npm run dev
```

## Checks

```bash
npm test
npm run build
```

## Environment

`VITE_API_URL` is the Hono API origin. It defaults to `http://localhost:8787` for local development.

Production Better Auth requests use the deployed web origin at `/api/auth/*`, which Netlify proxies
to the Hono Worker using `public/_redirects`. This keeps authentication cookies first-party. Regular
application requests continue directly to `VITE_API_URL` with Better Auth's in-memory bearer session
token so long DJ operations are not constrained by Netlify's external proxy timeout.

Apple's real browser callback must be tested on the deployed HTTPS origin; Apple does not accept localhost return URLs. Google may use the local Worker callback during development, while production uses the same first-party auth proxy as Apple.

## Current boundary

- Implemented foundations: Better Auth browser session gate with Apple + Google, remembered last-used provider, explicit account linking, credentialed session/memory/playlist APIs, MusicKit playback and playlist creation, paged MusicKit library/playlist/recent reads, deletion-safe staged upload, responsive conversation shell, server-backed session creation/chat, and the artwork-led mix rail.
- Next approval/implementation: the dedicated `Your music` flow in `docs/mockups/2026-09-01-web-sync-playlist-states.html`, including real progress, playlist browse/detail, memories, and rename/archive controls.
- Platform constraint: MusicKit on the Web does not expose native iOS per-song play counts. Mixtape preserves that as unknown and uses bounded recent order, playlist membership, and in-app behavior instead.
- Product rule: never display or persist lyric text.
