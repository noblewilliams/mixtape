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

For local Google sign-in, register the exact callback `${BETTER_AUTH_URL}/api/auth/callback/google` under the web OAuth client’s **Authorized redirect URIs**. The current local setup uses `http://localhost:8799/api/auth/callback/google`, with the frontend at `http://localhost:4176`. The frontend origin must also appear in the local Worker’s `WEB_ORIGINS`. A `redirect_uri_mismatch` error means the callback sent to Google is not registered for that client; changing the frontend port alone does not fix it.

Browser favicons use the original cassette with a transparent outer canvas. The icon export script preserves alpha for the 16px/32px browser PNGs; native and touch icons retain their opaque canvas.

## Current boundary

- Implemented foundations: Better Auth browser session gate with Apple + Google, remembered last-used provider, explicit account linking, credentialed session/memory/playlist APIs, MusicKit playback and playlist creation, paged MusicKit library/playlist/recent reads, deletion-safe staged upload, responsive conversation shell, server-backed session creation/chat, and the artwork-led mix rail.
- Next approval/implementation: the dedicated `Your music` flow in `docs/mockups/2026-09-01-web-sync-playlist-states.html`, including real progress, playlist browse/detail, memories, and rename/archive controls.
- Platform constraint: MusicKit on the Web does not expose native iOS per-song play counts. Mixtape preserves that as unknown and uses bounded recent order, playlist membership, and in-app behavior instead.
- Product rule: never display or persist lyric text.
