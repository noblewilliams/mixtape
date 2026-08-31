# Mixtape server

Install dependencies and run the Worker locally:

```txt
npm install
npm run dev
```

`createAuth` fails fast unless `.dev.vars` contains the database, Better Auth,
Apple, and Google client configurations:

```txt
DATABASE_URL=
BETTER_AUTH_SECRET=
BETTER_AUTH_URL=http://localhost:8787
APPLE_BUNDLE_ID=
APPLE_WEB_CLIENT_ID=
APPLE_TEAM_ID=
APPLE_KEY_ID=
APPLE_PRIVATE_KEY=
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MUSICKIT_KEY_ID=
MUSICKIT_PRIVATE_KEY=
WEB_ORIGINS=http://localhost:4176
```

`APPLE_BUNDLE_ID` remains the native iOS token audience.
`APPLE_WEB_CLIENT_ID` is the separate Apple Services ID used by the browser
redirect flow. Production auth is proxied through the first-party web origin,
so Apple and Google register `https://<web-origin>/api/auth/callback/apple` and
`https://<web-origin>/api/auth/callback/google`. Apple does not accept localhost
or non-HTTPS callback URLs, so its complete browser flow is tested on the
deployed HTTPS origin. Google may additionally register
`http://localhost:8787/api/auth/callback/google` for local development.

`MUSICKIT_KEY_ID` and `MUSICKIT_PRIVATE_KEY` are a separate Apple Music key
pair. Keep them separate from the Sign in with Apple key so either credential
can be rotated or revoked without breaking the other flow. When both values are
present, the authenticated `GET /musickit/token` route issues a one-hour
developer token for the request's exact allowed web origin. A partial MusicKit
configuration fails at startup; omitting both values disables the route.

Store private keys as Worker secrets rather than checked-in vars:

```txt
npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
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
