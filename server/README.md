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
WEB_ORIGINS=http://localhost:4176
```

`APPLE_BUNDLE_ID` remains the native iOS token audience.
`APPLE_WEB_CLIENT_ID` is the separate Apple Services ID used by the browser
redirect flow. The Apple Service must register the production callback as
`https://<api-origin>/api/auth/callback/apple`. Apple does not accept localhost
or non-HTTPS callback URLs, so the complete browser flow is tested on the
deployed HTTPS origin.

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
