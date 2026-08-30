# mixtape web

React, Vite, and TypeScript implementation of the approved tape-and-glass identity. This first milestone is intentionally UI-complete and integration-light: it uses typed local fixtures that mirror the existing Hono session, message, and queue contracts.

## Run it

```bash
npm install
npm run dev
```

## Checks

```bash
npm test
npm run build
```

## Current boundary

- Implemented: responsive conversation shell, session rail, queue, tape list, single-shelf Closet, new-tape and save-playlist dialogs, local playback state, DJ response state, and animated cassette preparation state.
- Next: Better Auth session wiring, the existing `/sessions` and `/me/memories` API routes, MusicKit JS playback, and real Apple Music playlist creation.
- Platform constraint: web does not provide the native iOS per-song play counts used during library ingest.
- Product rule: never display or persist lyric text.
