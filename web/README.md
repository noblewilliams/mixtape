# mixtape web

React, Vite, and TypeScript implementation of the approved tape-and-glass identity. The production entry point uses Better Auth for Apple and Google sign-in and reads sessions, messages, and tape queues from the Hono API.

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

- Implemented: Better Auth browser session gate with Apple + Google, remembered last-used provider, explicit account linking, credentialed `/sessions` integration, MusicKit JS playback and playlist creation, responsive conversation shell, server-backed session creation/chat, queue, tape list, single-shelf Closet, and animated cassette loading states.
- Next: the `/me/memories` UI.
- Platform constraint: web does not provide the native iOS per-song play counts used during library ingest.
- Product rule: never display or persist lyric text.
