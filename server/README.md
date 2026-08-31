# Mixtape server

Install dependencies and run the Worker locally:

```txt
npm install
npm run dev
```

`createAuth` fails fast unless `.dev.vars` contains the database, Better Auth,
and both Apple client configurations:

```txt
DATABASE_URL=
BETTER_AUTH_SECRET=
BETTER_AUTH_URL=http://localhost:8787
APPLE_BUNDLE_ID=
APPLE_WEB_CLIENT_ID=
APPLE_TEAM_ID=
APPLE_KEY_ID=
APPLE_PRIVATE_KEY=
MUSICKIT_KEY_ID=
MUSICKIT_PRIVATE_KEY=
WEB_ORIGINS=http://localhost:4176
```

`APPLE_BUNDLE_ID` remains the native iOS token audience.
`APPLE_WEB_CLIENT_ID` is the separate Apple Services ID used by the browser
redirect flow. The Apple Service must register the production callback as
`https://<api-origin>/api/auth/callback/apple`. Apple does not accept localhost
or non-HTTPS callback URLs, so the complete browser flow is tested on the
deployed HTTPS origin.

`MUSICKIT_KEY_ID` and `MUSICKIT_PRIVATE_KEY` are a separate Apple Music key
pair. Keep them separate from the Sign in with Apple key so either credential
can be rotated or revoked without breaking the other flow. When both values are
present, the authenticated `GET /musickit/token` route issues a one-hour
developer token for the request's exact allowed web origin. A partial MusicKit
configuration fails at startup; omitting both values disables the route.

Store private keys as Worker secrets rather than checked-in vars:

```txt
npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put MUSICKIT_PRIVATE_KEY
```

```txt
npm run deploy
```

[For generating/synchronizing types based on your Worker configuration run](https://developers.cloudflare.com/workers/wrangler/commands/#types):

```txt
npm run cf-typegen
```

Pass the `CloudflareBindings` as generics when instantiating `Hono`:

```ts
// src/index.ts
const app = new Hono<{ Bindings: CloudflareBindings }>()
```
