# P1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sign in with Apple end-to-end, read the user's Apple Music library (with real play counts) through a native bridge, and ingest it into the taste graph in Neon.

**Architecture:** Hono worker exposes Better Auth (native Apple idToken flow + bearer sessions) and an authenticated `/ingest/library` route writing to Neon via Drizzle. Flutter app signs in natively, then pages the library out of a Swift `MusicKitBridge` (MediaPlayer framework) and syncs it in chunks. Tests run the real schema against in-memory PGlite; auth is injected so routes are testable without Apple.

**Tech Stack:** Hono 4, Better Auth 1.7 (bearer plugin), Drizzle + Neon serverless driver, PGlite + Vitest for server tests, Flutter + Riverpod + sign_in_with_apple + flutter_secure_storage, Swift MediaPlayer.

**Working directory:** `~/Documents/work/mixtape` — all paths below are relative to repo root. Work directly on `main` (fresh solo repo, pre-1.0).

---

## Founder setup (manual, before or during execution)

- [ ] **Neon**: create project `mixtape`, copy the pooled connection string → `server/.dev.vars` as `DATABASE_URL`.
- [ ] **Apple**: in the Apple Developer portal, ensure App ID `com.mixtape.mixtape` exists with **Sign in with Apple** capability. In Xcode (`client/ios/Runner.xcworkspace` or `.xcodeproj`): Signing & Capabilities → add **Sign in with Apple** to the Runner target, set your team.
- [ ] **`server/.dev.vars`** (git-ignored):
  ```
  DATABASE_URL=postgres://...neon.tech/neondb?sslmode=require
  BETTER_AUTH_SECRET=<openssl rand -hex 32>
  BETTER_AUTH_URL=http://localhost:8787
  APPLE_BUNDLE_ID=com.mixtape.mixtape
  ```
  (No Apple client secret needed for the native idToken flow; that's web-flow-only.)

---

### Task 1: Server test infrastructure (Vitest + PGlite + Drizzle migrations)

**Files:**
- Modify: `server/package.json` (deps + scripts)
- Create: `server/drizzle.config.ts`
- Create: `server/src/db/schema.ts`
- Create: `server/test/helpers/db.ts`
- Test: `server/test/db.test.ts`

- [ ] **Step 1: Install dependencies**

```bash
cd server
npm install zod @hono/zod-validator
npm install -D vitest @electric-sql/pglite
```

- [ ] **Step 2: Add scripts to `server/package.json`** (merge into existing `scripts`)

```json
"scripts": {
  "dev": "wrangler dev",
  "deploy": "wrangler deploy --minify",
  "cf-typegen": "wrangler types --env-interface CloudflareBindings",
  "test": "vitest run",
  "db:generate": "drizzle-kit generate",
  "db:migrate": "drizzle-kit migrate"
}
```

- [ ] **Step 3: Create `server/drizzle.config.ts`**

```ts
import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: { url: process.env.DATABASE_URL ?? '' },
})
```

- [ ] **Step 4: Create `server/src/db/schema.ts`** (app tables only for now; auth tables join in Task 2)

```ts
import { pgTable, uuid, text, integer, timestamp, boolean, uniqueIndex } from 'drizzle-orm/pg-core'

export const tracks = pgTable(
  'tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    appleId: text('apple_id').notNull(),
    isrc: text('isrc'),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    genre: text('genre'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('tracks_apple_id_idx').on(t.appleId)],
)
```

- [ ] **Step 5: Generate the first migration**

Run: `cd server && npx drizzle-kit generate`
Expected: a new SQL file under `server/drizzle/` containing `CREATE TABLE "tracks"`.

- [ ] **Step 6: Create `server/test/helpers/db.ts`**

```ts
import { PGlite } from '@electric-sql/pglite'
import { drizzle } from 'drizzle-orm/pglite'
import { migrate } from 'drizzle-orm/pglite/migrator'
import * as schema from '../../src/db/schema'

export type TestDb = Awaited<ReturnType<typeof createTestDb>>

export async function createTestDb() {
  const client = new PGlite()
  const db = drizzle(client, { schema })
  await migrate(db, { migrationsFolder: './drizzle' })
  return db
}
```

- [ ] **Step 7: Write the failing test `server/test/db.test.ts`**

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb } from './helpers/db'
import { tracks } from '../src/db/schema'

describe('db schema', () => {
  it('round-trips a track', async () => {
    const db = await createTestDb()
    await db.insert(tracks).values({ appleId: '123', title: 'Song', artist: 'Artist' })
    const rows = await db.select().from(tracks)
    expect(rows).toHaveLength(1)
    expect(rows[0].appleId).toBe('123')
  })
})
```

- [ ] **Step 8: Run tests**

Run: `cd server && npm test`
Expected: PASS (1 test). If migrate fails, check the `drizzle/` folder exists from Step 5.

- [ ] **Step 9: Commit**

```bash
git add server && git commit -m "feat(server): db schema + pglite test infra"
```

---

### Task 2: Better Auth schema + full P1 schema

**Files:**
- Create: `server/src/auth/cli-config.ts`
- Create: `server/src/db/auth-schema.ts` (generated)
- Modify: `server/src/db/schema.ts`
- Test: `server/test/db.test.ts` (extend)

- [ ] **Step 1: Create `server/src/auth/cli-config.ts`** (used only by the Better Auth CLI to generate the drizzle schema)

```ts
import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'

export const auth = betterAuth({
  database: drizzleAdapter({} as never, { provider: 'pg' }),
  plugins: [bearer()],
})
```

- [ ] **Step 2: Generate the auth schema**

Run: `cd server && npx @better-auth/cli@latest generate --config src/auth/cli-config.ts --output src/db/auth-schema.ts -y`
Expected: `src/db/auth-schema.ts` exporting drizzle tables `user`, `session`, `account`, `verification`. If the CLI flags differ in the installed version, run `npx @better-auth/cli@latest generate --help` and adapt; the output file location is what matters.

- [ ] **Step 3: Extend `server/src/db/schema.ts`** — re-export auth tables, add `userTracks`

Append/replace so the file reads:

```ts
import { pgTable, uuid, text, integer, timestamp, boolean, uniqueIndex } from 'drizzle-orm/pg-core'
import { user } from './auth-schema'

export * from './auth-schema'

export const tracks = pgTable(
  'tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    appleId: text('apple_id').notNull(),
    isrc: text('isrc'),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    genre: text('genre'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('tracks_apple_id_idx').on(t.appleId)],
)

export const userTracks = pgTable(
  'user_tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    playCount: integer('play_count').notNull().default(0),
    lastPlayedAt: timestamp('last_played_at', { withTimezone: true }),
    dateAdded: timestamp('date_added', { withTimezone: true }),
    inLibrary: boolean('in_library').notNull().default(true),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [uniqueIndex('user_tracks_user_track_idx').on(t.userId, t.trackId)],
)
```

- [ ] **Step 4: Generate migration**

Run: `cd server && npx drizzle-kit generate`
Expected: new SQL file creating `user`, `session`, `account`, `verification`, `user_tracks`.

- [ ] **Step 5: Extend `server/test/db.test.ts`** with a failing FK test

```ts
import { user, userTracks } from '../src/db/schema'

it('links a user to a track with play count', async () => {
  const db = await createTestDb()
  await db.insert(user).values({
    id: 'user-1',
    name: 'Test',
    email: 'test@example.com',
    emailVerified: false,
    createdAt: new Date(),
    updatedAt: new Date(),
  })
  const [track] = await db
    .insert(tracks)
    .values({ appleId: '123', title: 'Song', artist: 'Artist' })
    .returning()
  await db.insert(userTracks).values({ userId: 'user-1', trackId: track.id, playCount: 42 })
  const rows = await db.select().from(userTracks)
  expect(rows[0].playCount).toBe(42)
})
```

(If the generated `user` table's column names differ, match them — read `auth-schema.ts` and adjust the insert.)

- [ ] **Step 6: Run tests**

Run: `cd server && npm test`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add server && git commit -m "feat(server): auth schema + user_tracks"
```

---

### Task 3: Auth factory + app factory with Better Auth mounted

**Files:**
- Create: `server/src/auth/create-auth.ts`
- Create: `server/src/app.ts`
- Modify: `server/src/index.ts`
- Test: `server/test/auth.test.ts`

- [ ] **Step 1: Create `server/src/auth/create-auth.ts`**

```ts
import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'
import * as schema from '../db/schema'

export type AuthEnv = {
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
}

// db is any drizzle pg database (neon-http in prod, pglite in tests)
export function createAuth(db: unknown, env: AuthEnv) {
  return betterAuth({
    baseURL: env.BETTER_AUTH_URL,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db as never, { provider: 'pg', schema }),
    socialProviders: {
      apple: {
        clientId: env.APPLE_BUNDLE_ID,
        clientSecret: '', // web-flow only; native idToken flow doesn't use it
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      },
    },
    plugins: [bearer()],
  })
}

export type Auth = ReturnType<typeof createAuth>
```

- [ ] **Step 2: Create `server/src/app.ts`** (dependency-injected so tests control auth/db)

```ts
import { Hono } from 'hono'

// Minimal structural type so tests can stub auth
export type AuthLike = {
  handler: (req: Request) => Response | Promise<Response>
  api: {
    getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>
  }
}

export type AppVars = { user: { id: string } }

export function createApp({ auth }: { auth: AuthLike }) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))

  return app
}
```

- [ ] **Step 3: Rewrite `server/src/index.ts`** to wire real deps

```ts
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from './db/schema'
import { createAuth } from './auth/create-auth'
import { createApp } from './app'

type Bindings = {
  DATABASE_URL: string
  BETTER_AUTH_SECRET: string
  BETTER_AUTH_URL: string
  APPLE_BUNDLE_ID: string
}

export default {
  fetch(req: Request, env: Bindings, ctx: ExecutionContext) {
    const db = drizzle(neon(env.DATABASE_URL), { schema })
    const auth = createAuth(db, env)
    const app = createApp({ auth })
    return app.fetch(req, env, ctx)
  },
}
```

- [ ] **Step 4: Write failing test `server/test/auth.test.ts`** — real Better Auth over PGlite

```ts
import { describe, it, expect } from 'vitest'
import { createTestDb } from './helpers/db'
import { createAuth } from '../src/auth/create-auth'
import { createApp } from '../src/app'

const testEnv = {
  BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret',
  BETTER_AUTH_URL: 'http://localhost:8787',
  APPLE_BUNDLE_ID: 'com.mixtape.mixtape',
}

describe('auth mounting', () => {
  it('serves better-auth endpoints', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testEnv)
    const app = createApp({ auth })
    const res = await app.request('http://localhost:8787/api/auth/ok')
    expect(res.status).toBe(200)
  })

  it('health still works', async () => {
    const db = await createTestDb()
    const auth = createAuth(db, testEnv)
    const app = createApp({ auth })
    const res = await app.request('http://localhost:8787/health')
    expect(res.status).toBe(200)
  })
})
```

- [ ] **Step 5: Run tests**

Run: `cd server && npm test`
Expected: PASS. (If `/api/auth/ok` 404s in the installed version, use `/api/auth/error` or any documented Better Auth route that returns non-404 — the assertion is "Better Auth is mounted", adjust the path.)

- [ ] **Step 6: Verify the worker still boots**

Run: `cd server && (npx wrangler dev --port 8799 >/tmp/wr.log 2>&1 &) && sleep 8 && curl -s http://localhost:8799/health && pkill -f "wrangler dev --port 8799"`
Expected: `{"ok":true,"service":"mixtape-api"}` (requires `.dev.vars` from founder setup; if DATABASE_URL is unset the boot may still succeed since db is lazy — health does not touch it).

- [ ] **Step 7: Commit**

```bash
git add server && git commit -m "feat(server): better auth with apple + bearer"
```

---

### Task 4: Session middleware + /me

**Files:**
- Create: `server/src/middleware/require-session.ts`
- Modify: `server/src/app.ts`
- Test: `server/test/session.test.ts`

- [ ] **Step 1: Write failing test `server/test/session.test.ts`** using a stubbed auth

```ts
import { describe, it, expect } from 'vitest'
import { createApp, type AuthLike } from '../src/app'

function stubAuth(session: { user: { id: string } } | null): AuthLike {
  return {
    handler: () => new Response('ok'),
    api: { getSession: async () => session },
  }
}

describe('session middleware', () => {
  it('rejects /me without a session', async () => {
    const app = createApp({ auth: stubAuth(null) })
    const res = await app.request('http://x/me')
    expect(res.status).toBe(401)
  })

  it('returns the user with a session', async () => {
    const app = createApp({ auth: stubAuth({ user: { id: 'user-1' } }) })
    const res = await app.request('http://x/me', {
      headers: { Authorization: 'Bearer whatever' },
    })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ user: { id: 'user-1' } })
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server && npm test`
Expected: FAIL — `/me` 404.

- [ ] **Step 3: Create `server/src/middleware/require-session.ts`**

```ts
import { createMiddleware } from 'hono/factory'
import type { AuthLike, AppVars } from '../app'

export function requireSession(auth: AuthLike) {
  return createMiddleware<{ Variables: AppVars }>(async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers })
    if (!session) return c.json({ error: 'unauthorized' }, 401)
    c.set('user', session.user)
    await next()
  })
}
```

- [ ] **Step 4: Mount in `server/src/app.ts`** — add after the auth mount:

```ts
import { requireSession } from './middleware/require-session'
// inside createApp, after app.all('/api/auth/*', ...):
app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))
```

- [ ] **Step 5: Run tests**

Run: `cd server && npm test`
Expected: PASS (all files).

- [ ] **Step 6: Commit**

```bash
git add server && git commit -m "feat(server): session middleware + /me"
```

---

### Task 5: Ingest route (library → taste graph)

**Files:**
- Create: `server/src/routes/ingest.ts`
- Modify: `server/src/app.ts`
- Test: `server/test/ingest.test.ts`

- [ ] **Step 1: Write failing test `server/test/ingest.test.ts`**

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { createTestDb, type TestDb } from './helpers/db'
import { createApp, type AuthLike } from '../src/app'
import { tracks, userTracks, user } from '../src/db/schema'

const authed: AuthLike = {
  handler: () => new Response('ok'),
  api: { getSession: async () => ({ user: { id: 'user-1' } }) },
}

const song = (over: Record<string, unknown> = {}) => ({
  appleId: 'a1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  genre: 'Pop',
  playCount: 7,
  lastPlayedAt: 1724900000000,
  dateAdded: 1700000000000,
  ...over,
})

describe('POST /ingest/library', () => {
  let db: TestDb
  beforeEach(async () => {
    db = await createTestDb()
    await db.insert(user).values({
      id: 'user-1',
      name: 'Test',
      email: 't@example.com',
      emailVerified: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
  })

  const post = (body: unknown, auth: AuthLike = authed) =>
    createApp({ auth, db }).request('http://x/ingest/library', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })

  it('requires auth', async () => {
    const res = await post({ songs: [song()] }, { ...authed, api: { getSession: async () => null } })
    expect(res.status).toBe(401)
  })

  it('inserts tracks and user_tracks', async () => {
    const res = await post({ songs: [song(), song({ appleId: 'a2', title: 'Two' })] })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ingested: 2 })
    expect(await db.select().from(tracks)).toHaveLength(2)
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(2)
    expect(uts.find((u) => u.playCount === 7)).toBeTruthy()
  })

  it('upserts on re-sync (play count updates, no duplicates)', async () => {
    await post({ songs: [song()] })
    await post({ songs: [song({ playCount: 9 })] })
    expect(await db.select().from(tracks)).toHaveLength(1)
    const uts = await db.select().from(userTracks)
    expect(uts).toHaveLength(1)
    expect(uts[0].playCount).toBe(9)
  })

  it('rejects malformed payloads', async () => {
    const res = await post({ songs: [{ title: 'no appleId' }] })
    expect(res.status).toBe(400)
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server && npm test`
Expected: FAIL — createApp doesn't accept `db`, route 404.

- [ ] **Step 3: Create `server/src/routes/ingest.ts`**

```ts
import { Hono } from 'hono'
import { z } from 'zod'
import { zValidator } from '@hono/zod-validator'
import { sql } from 'drizzle-orm'
import { tracks, userTracks } from '../db/schema'
import type { AppVars } from '../app'
import type { Db } from '../db/types'

const songSchema = z.object({
  appleId: z.string().min(1),
  title: z.string().min(1),
  artist: z.string().min(1),
  album: z.string().nullable().optional(),
  genre: z.string().nullable().optional(),
  playCount: z.number().int().min(0),
  lastPlayedAt: z.number().int().nullable().optional(),
  dateAdded: z.number().int().nullable().optional(),
})

const bodySchema = z.object({ songs: z.array(songSchema).min(1).max(500) })

const toDate = (ms: number | null | undefined) => (ms == null ? null : new Date(ms))

export function ingestRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/library', zValidator('json', bodySchema), async (c) => {
    const { songs } = c.req.valid('json')
    const userId = c.get('user').id

    const trackRows = await db
      .insert(tracks)
      .values(
        songs.map((s) => ({
          appleId: s.appleId,
          title: s.title,
          artist: s.artist,
          album: s.album ?? null,
          genre: s.genre ?? null,
        })),
      )
      .onConflictDoUpdate({
        target: tracks.appleId,
        set: { title: sql`excluded.title`, artist: sql`excluded.artist` },
      })
      .returning({ id: tracks.id, appleId: tracks.appleId })

    const idByAppleId = new Map(trackRows.map((t) => [t.appleId, t.id]))

    await db
      .insert(userTracks)
      .values(
        songs.map((s) => ({
          userId,
          trackId: idByAppleId.get(s.appleId)!,
          playCount: s.playCount,
          lastPlayedAt: toDate(s.lastPlayedAt),
          dateAdded: toDate(s.dateAdded),
          inLibrary: true,
        })),
      )
      .onConflictDoUpdate({
        target: [userTracks.userId, userTracks.trackId],
        set: {
          playCount: sql`excluded.play_count`,
          lastPlayedAt: sql`excluded.last_played_at`,
          inLibrary: sql`excluded.in_library`,
          updatedAt: sql`now()`,
        },
      })

    return c.json({ ingested: songs.length })
  })

  return app
}
```

- [ ] **Step 4: Create `server/src/db/types.ts`**

```ts
import type { drizzle as neonDrizzle } from 'drizzle-orm/neon-http'
import type { drizzle as pgliteDrizzle } from 'drizzle-orm/pglite'
import type * as schema from './schema'

// Structural union: prod (neon-http) and tests (pglite) both satisfy this
export type Db =
  | ReturnType<typeof neonDrizzle<typeof schema>>
  | ReturnType<typeof pgliteDrizzle<typeof schema>>
```

(If the union type causes method-signature friction in `ingest.ts`, simplify to the pglite type only — it is structurally compatible for the query builder — or `export type Db = any` as a last resort with a `// TODO(types)` marker and a note in the PR. Do not spend more than a few minutes here; the tests are what guarantee correctness.)

- [ ] **Step 5: Wire into `server/src/app.ts`** — full file now reads:

```ts
import { Hono } from 'hono'
import { requireSession } from './middleware/require-session'
import { ingestRoutes } from './routes/ingest'
import type { Db } from './db/types'

export type AuthLike = {
  handler: (req: Request) => Response | Promise<Response>
  api: {
    getSession: (input: { headers: Headers }) => Promise<{ user: { id: string } } | null>
  }
}

export type AppVars = { user: { id: string } }

export function createApp({ auth, db }: { auth: AuthLike; db?: Db }) {
  const app = new Hono<{ Variables: AppVars }>()

  app.get('/health', (c) => c.json({ ok: true, service: 'mixtape-api' }))
  app.all('/api/auth/*', (c) => auth.handler(c.req.raw))
  app.get('/me', requireSession(auth), (c) => c.json({ user: c.get('user') }))

  if (db) {
    app.use('/ingest/*', requireSession(auth))
    app.route('/ingest', ingestRoutes(db))
  }

  return app
}
```

Also update `server/src/index.ts` to pass db: `const app = createApp({ auth, db })`.

- [ ] **Step 6: Run tests**

Run: `cd server && npm test`
Expected: PASS (all files, including earlier tasks — `createApp({ auth })` callers still compile because `db` is optional).

- [ ] **Step 7: Commit**

```bash
git add server && git commit -m "feat(server): library ingest route"
```

---

### Task 6: Flutter dependencies + API client

**Files:**
- Modify: `client/pubspec.yaml`
- Create: `client/lib/core/config.dart`
- Create: `client/lib/data/auth/token_store.dart`
- Create: `client/lib/data/api/api_client.dart`
- Test: `client/test/data/api_client_test.dart`

- [ ] **Step 1: Add dependencies**

Run in `client/`:
```bash
flutter pub add flutter_riverpod sign_in_with_apple flutter_secure_storage http
```

- [ ] **Step 2: Create `client/lib/core/config.dart`**

```dart
class AppConfig {
  // flutter run --dart-define=API_BASE_URL=https://mixtape-api.<account>.workers.dev
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8787',
  );
}
```

- [ ] **Step 3: Create `client/lib/data/auth/token_store.dart`**

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'auth_token';

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryTokenStore implements TokenStore {
  String? _token;
  @override
  Future<String?> read() async => _token;
  @override
  Future<void> write(String token) async => _token = token;
  @override
  Future<void> clear() async => _token = null;
}
```

- [ ] **Step 4: Write failing test `client/test/data/api_client_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';

void main() {
  test('attaches bearer token when present', () async {
    String? seenAuth;
    final inner = MockClient((req) async {
      seenAuth = req.headers['Authorization'];
      return http.Response('{}', 200);
    });
    final store = InMemoryTokenStore()..write('tok-123');
    final client = ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);

    await client.postJson('/ingest/library', {'songs': []});
    expect(seenAuth, 'Bearer tok-123');
  });

  test('omits header when signed out', () async {
    String? seenAuth = 'sentinel';
    final inner = MockClient((req) async {
      seenAuth = req.headers['Authorization'];
      return http.Response('{}', 200);
    });
    final client =
        ApiClient(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

    await client.postJson('/anything', {});
    expect(seenAuth, isNull);
  });
}
```

- [ ] **Step 5: Run to verify it fails**

Run: `cd client && flutter test test/data/api_client_test.dart`
Expected: FAIL — `api_client.dart` missing.

- [ ] **Step 6: Create `client/lib/data/api/api_client.dart`**

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../auth/token_store.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.tokenStore, http.Client? inner})
      : _inner = inner ?? http.Client();

  final String baseUrl;
  final TokenStore tokenStore;
  final http.Client _inner;

  Future<Map<String, String>> _headers() async {
    final token = await tokenStore.read();
    return {
      'content-type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> postJson(String path, Object body) async {
    final res = await _inner.post(
      Uri.parse('$baseUrl$path'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }

  Future<http.Response> getJson(String path) async {
    final res = await _inner.get(Uri.parse('$baseUrl$path'), headers: await _headers());
    if (res.statusCode >= 400) throw ApiException(res.statusCode, res.body);
    return res;
  }
}
```

- [ ] **Step 7: Run tests**

Run: `cd client && flutter test`
Expected: PASS (api tests + scaffold counter test still green).

- [ ] **Step 8: Commit**

```bash
git add client && git commit -m "feat(client): api client + token store"
```

---

### Task 7: Apple sign-in flow (client)

**Files:**
- Create: `client/lib/data/auth/apple_auth_gateway.dart`
- Create: `client/lib/data/auth/auth_repository.dart`
- Create: `client/lib/presentation/providers/auth_provider.dart`
- Test: `client/test/data/auth_repository_test.dart`

- [ ] **Step 1: Create `client/lib/data/auth/apple_auth_gateway.dart`** (seam over the plugin)

```dart
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Thin seam over sign_in_with_apple so tests can fake the native dialog.
abstract class AppleAuthGateway {
  Future<String> getIdentityToken();
}

class RealAppleAuthGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
    );
    final token = credential.identityToken;
    if (token == null) throw StateError('Apple returned no identity token');
    return token;
  }
}
```

- [ ] **Step 2: Write failing test `client/test/data/auth_repository_test.dart`**

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/token_store.dart';

class FakeGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => 'apple-id-token';
}

void main() {
  test('signs in: posts idToken, stores bearer token from header', () async {
    late Map<String, dynamic> sentBody;
    final inner = MockClient((req) async {
      expect(req.url.path, '/api/auth/sign-in/social');
      sentBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{"user":{}}', 200, headers: {'set-auth-token': 'bearer-abc'});
    });
    final store = InMemoryTokenStore();
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: store,
      gateway: FakeGateway(),
      inner: inner,
    );

    await repo.signInWithApple();

    expect(sentBody['provider'], 'apple');
    expect(sentBody['idToken'], {'token': 'apple-id-token'});
    expect(await store.read(), 'bearer-abc');
  });

  test('signOut clears the token', () async {
    final store = InMemoryTokenStore()..write('t');
    final repo = AuthRepository(
      baseUrl: 'http://x',
      tokenStore: store,
      gateway: FakeGateway(),
      inner: MockClient((_) async => http.Response('{}', 200)),
    );
    await repo.signOut();
    expect(await store.read(), isNull);
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd client && flutter test test/data/auth_repository_test.dart`
Expected: FAIL — `auth_repository.dart` missing.

- [ ] **Step 4: Create `client/lib/data/auth/auth_repository.dart`**

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'apple_auth_gateway.dart';
import 'token_store.dart';

class AuthRepository {
  AuthRepository({
    required this.baseUrl,
    required this.tokenStore,
    required this.gateway,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  final String baseUrl;
  final TokenStore tokenStore;
  final AppleAuthGateway gateway;
  final http.Client _inner;

  Future<void> signInWithApple() async {
    final idToken = await gateway.getIdentityToken();
    final res = await _inner.post(
      Uri.parse('$baseUrl/api/auth/sign-in/social'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'provider': 'apple',
        'idToken': {'token': idToken},
      }),
    );
    if (res.statusCode >= 400) {
      throw StateError('Sign-in failed (${res.statusCode}): ${res.body}');
    }
    final token = res.headers['set-auth-token'];
    if (token == null) throw StateError('No set-auth-token header in response');
    await tokenStore.write(token);
  }

  Future<bool> isSignedIn() async => await tokenStore.read() != null;

  Future<void> signOut() => tokenStore.clear();
}
```

- [ ] **Step 5: Run tests**

Run: `cd client && flutter test`
Expected: PASS.

- [ ] **Step 6: Create `client/lib/presentation/providers/auth_provider.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../core/config.dart';
import '../../data/api/api_client.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/token_store.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    baseUrl: AppConfig.apiBaseUrl,
    tokenStore: ref.watch(tokenStoreProvider),
    gateway: RealAppleAuthGateway(),
  );
});

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(baseUrl: AppConfig.apiBaseUrl, tokenStore: ref.watch(tokenStoreProvider));
});

enum AuthStatus { unknown, signedOut, signedIn }

class AuthNotifier extends Notifier<AuthStatus> {
  @override
  AuthStatus build() {
    _restore();
    return AuthStatus.unknown;
  }

  Future<void> _restore() async {
    final signedIn = await ref.read(authRepositoryProvider).isSignedIn();
    state = signedIn ? AuthStatus.signedIn : AuthStatus.signedOut;
  }

  Future<void> signIn() async {
    await ref.read(authRepositoryProvider).signInWithApple();
    state = AuthStatus.signedIn;
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    state = AuthStatus.signedOut;
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthStatus>(AuthNotifier.new);
```

(Riverpod 3 note: if `Notifier` import paths differ in the resolved version, match whatever `flutter_riverpod` resolved to — goalympics conventions apply.)

- [ ] **Step 7: Analyze + test**

Run: `cd client && flutter analyze && flutter test`
Expected: no analyzer errors, tests PASS.

- [ ] **Step 8: Commit**

```bash
git add client && git commit -m "feat(client): apple sign-in flow"
```

---

### Task 8: Swift MusicKitBridge + Dart seam

**Files:**
- Create: `client/ios/Runner/MusicKitBridge.swift`
- Modify: `client/ios/Runner/AppDelegate.swift`
- Modify: `client/ios/Runner/Info.plist`
- Modify: `client/ios/Runner.xcodeproj/project.pbxproj` (target membership — via script)
- Create: `client/lib/data/musickit/musickit_bridge.dart`
- Test: `client/test/data/musickit_bridge_test.dart`

- [ ] **Step 1: Create `client/ios/Runner/MusicKitBridge.swift`**

```swift
import Flutter
import MediaPlayer

/// Bridges the on-device music library (MediaPlayer) to Dart.
/// P1 scope: authorization + paged library read with play counts.
class MusicKitBridge: NSObject {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/musickit", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestAuthorization":
        requestAuthorization(result: result)
      case "fetchLibrarySongs":
        let args = call.arguments as? [String: Any] ?? [:]
        let offset = args["offset"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 200
        fetchLibrarySongs(offset: offset, limit: limit, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func requestAuthorization(result: @escaping FlutterResult) {
    MPMediaLibrary.requestAuthorization { status in
      DispatchQueue.main.async { result(status == .authorized) }
    }
  }

  private static func fetchLibrarySongs(offset: Int, limit: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let all = MPMediaQuery.songs().items ?? []
      // Only songs with an Apple Music catalog identity; local-only rips have "0"/empty.
      let catalog = all.filter { !$0.playbackStoreID.isEmpty && $0.playbackStoreID != "0" }
      let page = catalog.dropFirst(offset).prefix(limit)
      let songs: [[String: Any?]] = page.map { item in
        [
          "appleId": item.playbackStoreID,
          "title": item.title ?? "Unknown",
          "artist": item.artist ?? "Unknown",
          "album": item.albumTitle,
          "genre": item.genre,
          "playCount": item.playCount,
          "lastPlayedAt": item.lastPlayedDate.map { Int($0.timeIntervalSince1970 * 1000) },
          "dateAdded": Int(item.dateAdded.timeIntervalSince1970 * 1000),
        ]
      }
      DispatchQueue.main.async {
        result(["songs": songs, "total": catalog.count])
      }
    }
  }
}
```

- [ ] **Step 2: Register in `client/ios/Runner/AppDelegate.swift`** — inside `application(_:didFinishLaunchingWithOptions:)`, before the `GeneratedPluginRegistrant` line's `return`:

```swift
let controller = window?.rootViewController as! FlutterViewController
MusicKitBridge.register(with: controller.binaryMessenger)
```

- [ ] **Step 3: Add target membership (goalympics lesson: new Swift files need pbxproj entry)**

```bash
cd client/ios && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("Runner.xcodeproj")
target = project.targets.find { |t| t.name == "Runner" }
group = project.main_group["Runner"]
abort("already added") if group.files.any? { |f| f.path == "MusicKitBridge.swift" }
file = group.new_file("MusicKitBridge.swift")
target.add_file_references([file])
project.save
puts "added"
'
```

Expected: `added`. If the `xcodeproj` gem is unavailable, open `Runner.xcodeproj` in Xcode and drag `MusicKitBridge.swift` into the Runner group with Runner target membership checked.

- [ ] **Step 4: Add usage description to `client/ios/Runner/Info.plist`** (inside the top-level `<dict>`)

```xml
<key>NSAppleMusicUsageDescription</key>
<string>mixtape reads your music library and play counts to learn your taste and build queues for you.</string>
```

- [ ] **Step 5: Verify the iOS build compiles**

Run: `cd client && flutter build ios --no-codesign 2>&1 | tail -3`
Expected: `✓ Built ...` — if it fails on target membership, redo Step 3 manually in Xcode.

- [ ] **Step 6: Write failing Dart test `client/test/data/musickit_bridge_test.dart`**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixtape/musickit');

  test('fetchLibrarySongs decodes the platform payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fetchLibrarySongs');
      expect(call.arguments, {'offset': 0, 'limit': 2});
      return {
        'songs': [
          {
            'appleId': '111',
            'title': 'One',
            'artist': 'A',
            'album': null,
            'genre': 'Pop',
            'playCount': 3,
            'lastPlayedAt': 1724900000000,
            'dateAdded': 1700000000000,
          },
        ],
        'total': 1,
      };
    });

    final bridge = MusicKitBridge();
    final page = await bridge.fetchLibrarySongs(offset: 0, limit: 2);
    expect(page.total, 1);
    expect(page.songs.single.appleId, '111');
    expect(page.songs.single.playCount, 3);
  });

  test('requestAuthorization returns the platform bool', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    expect(await MusicKitBridge().requestAuthorization(), isTrue);
  });
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `cd client && flutter test test/data/musickit_bridge_test.dart`
Expected: FAIL — `musickit_bridge.dart` missing.

- [ ] **Step 8: Create `client/lib/data/musickit/musickit_bridge.dart`**

```dart
import 'package:flutter/services.dart';

class LibrarySong {
  const LibrarySong({
    required this.appleId,
    required this.title,
    required this.artist,
    required this.playCount,
    this.album,
    this.genre,
    this.lastPlayedAt,
    this.dateAdded,
  });

  final String appleId;
  final String title;
  final String artist;
  final int playCount;
  final String? album;
  final String? genre;
  final int? lastPlayedAt; // epoch ms
  final int? dateAdded; // epoch ms

  factory LibrarySong.fromMap(Map<dynamic, dynamic> m) => LibrarySong(
        appleId: m['appleId'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        playCount: m['playCount'] as int,
        album: m['album'] as String?,
        genre: m['genre'] as String?,
        lastPlayedAt: m['lastPlayedAt'] as int?,
        dateAdded: m['dateAdded'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'appleId': appleId,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'playCount': playCount,
        'lastPlayedAt': lastPlayedAt,
        'dateAdded': dateAdded,
      };
}

class LibraryPage {
  const LibraryPage({required this.songs, required this.total});
  final List<LibrarySong> songs;
  final int total;
}

class MusicKitBridge {
  static const _channel = MethodChannel('mixtape/musickit');

  Future<bool> requestAuthorization() async =>
      await _channel.invokeMethod<bool>('requestAuthorization') ?? false;

  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'fetchLibrarySongs',
      {'offset': offset, 'limit': limit},
    );
    final songs = (raw!['songs'] as List)
        .map((s) => LibrarySong.fromMap(s as Map<dynamic, dynamic>))
        .toList();
    return LibraryPage(songs: songs, total: raw['total'] as int);
  }
}
```

- [ ] **Step 9: Run tests**

Run: `cd client && flutter test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add client && git commit -m "feat(client): musickit bridge for library reads"
```

---

### Task 9: Library sync service

**Files:**
- Create: `client/lib/data/library/library_sync_service.dart`
- Test: `client/test/data/library_sync_service_test.dart`

- [ ] **Step 1: Write failing test `client/test/data/library_sync_service_test.dart`**

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';

class FakeBridge implements MusicKitBridge {
  FakeBridge(this.all);
  final List<LibrarySong> all;

  @override
  Future<bool> requestAuthorization() async => true;

  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) async {
    return LibraryPage(songs: all.skip(offset).take(limit).toList(), total: all.length);
  }
}

LibrarySong song(int i) =>
    LibrarySong(appleId: '$i', title: 'T$i', artist: 'A', playCount: i);

void main() {
  test('pages the bridge and posts chunks until done', () async {
    final postedCounts = <int>[];
    final inner = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      postedCounts.add((body['songs'] as List).length);
      return http.Response('{"ingested": 0}', 200);
    });
    final api = ApiClient(
        baseUrl: 'http://x', tokenStore: InMemoryTokenStore()..write('t'), inner: inner);
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(450, song)),
      api: api,
      chunkSize: 200,
    );

    final progress = <double>[];
    final total = await service.sync(onProgress: progress.add);

    expect(total, 450);
    expect(postedCounts, [200, 200, 50]);
    expect(progress.last, 1.0);
  });

  test('throws when authorization is denied', () async {
    final denied = _DeniedBridge();
    final service = LibrarySyncService(
      bridge: denied,
      api: ApiClient(
          baseUrl: 'http://x',
          tokenStore: InMemoryTokenStore(),
          inner: MockClient((_) async => http.Response('{}', 200))),
    );
    expect(service.sync, throwsA(isA<LibraryAccessDenied>()));
  });
}

class _DeniedBridge implements MusicKitBridge {
  @override
  Future<bool> requestAuthorization() async => false;
  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) =>
      throw UnimplementedError();
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd client && flutter test test/data/library_sync_service_test.dart`
Expected: FAIL — service missing.

- [ ] **Step 3: Create `client/lib/data/library/library_sync_service.dart`**

```dart
import '../api/api_client.dart';
import '../musickit/musickit_bridge.dart';

class LibraryAccessDenied implements Exception {}

class LibrarySyncService {
  LibrarySyncService({required this.bridge, required this.api, this.chunkSize = 200});

  final MusicKitBridge bridge;
  final ApiClient api;
  final int chunkSize;

  /// Syncs the whole library. Returns the number of songs synced.
  Future<int> sync({void Function(double progress)? onProgress}) async {
    final authorized = await bridge.requestAuthorization();
    if (!authorized) throw LibraryAccessDenied();

    var offset = 0;
    var total = 0;
    while (true) {
      final page = await bridge.fetchLibrarySongs(offset: offset, limit: chunkSize);
      total = page.total;
      if (page.songs.isEmpty) break;
      await api.postJson('/ingest/library', {
        'songs': page.songs.map((s) => s.toJson()).toList(),
      });
      offset += page.songs.length;
      onProgress?.call(total == 0 ? 1.0 : (offset / total).clamp(0.0, 1.0));
      if (offset >= total) break;
    }
    if (total == 0) onProgress?.call(1.0);
    return total;
  }
}
```

- [ ] **Step 4: Run tests**

Run: `cd client && flutter test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client && git commit -m "feat(client): library sync service"
```

---

### Task 10: Screens + app wiring

**Files:**
- Create: `client/lib/presentation/screens/sign_in_screen.dart`
- Create: `client/lib/presentation/screens/home_screen.dart`
- Create: `client/lib/presentation/providers/library_sync_provider.dart`
- Modify: `client/lib/main.dart` (replace scaffold counter app)
- Delete: `client/test/widget_test.dart` (counter test)
- Test: `client/test/screens/root_gate_test.dart`

- [ ] **Step 1: Create `client/lib/presentation/providers/library_sync_provider.dart`**

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/library/library_sync_service.dart';
import '../../data/musickit/musickit_bridge.dart';
import 'auth_provider.dart';

final musicKitBridgeProvider = Provider<MusicKitBridge>((ref) => MusicKitBridge());

final librarySyncServiceProvider = Provider<LibrarySyncService>((ref) {
  return LibrarySyncService(
    bridge: ref.watch(musicKitBridgeProvider),
    api: ref.watch(apiClientProvider),
  );
});

sealed class SyncState {
  const SyncState();
}

class SyncIdle extends SyncState {
  const SyncIdle();
}

class SyncRunning extends SyncState {
  const SyncRunning(this.progress);
  final double progress;
}

class SyncDone extends SyncState {
  const SyncDone(this.total);
  final int total;
}

class SyncFailed extends SyncState {
  const SyncFailed(this.message);
  final String message;
}

class LibrarySyncNotifier extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncIdle();

  Future<void> sync() async {
    state = const SyncRunning(0);
    try {
      final total = await ref
          .read(librarySyncServiceProvider)
          .sync(onProgress: (p) => state = SyncRunning(p));
      state = SyncDone(total);
    } on LibraryAccessDenied {
      state = const SyncFailed('Music library access was denied. Enable it in Settings.');
    } catch (e) {
      state = SyncFailed('Sync failed: $e');
    }
  }
}

final librarySyncProvider =
    NotifierProvider<LibrarySyncNotifier, SyncState>(LibrarySyncNotifier.new);
```

- [ ] **Step 2: Create `client/lib/presentation/screens/sign_in_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('mixtape', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('your personal DJ'),
            const SizedBox(height: 48),
            FilledButton.icon(
              key: const Key('apple-sign-in'),
              onPressed: () async {
                try {
                  await ref.read(authProvider.notifier).signIn();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
                  }
                }
              },
              icon: const Icon(Icons.apple),
              label: const Text('Sign in with Apple'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Create `client/lib/presentation/screens/home_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/library_sync_provider.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('mixtape'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (sync) {
            SyncIdle() => FilledButton(
                key: const Key('sync-library'),
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Sync my library'),
              ),
            SyncRunning(:final progress) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(value: progress == 0 ? null : progress),
                  const SizedBox(height: 16),
                  Text('Syncing… ${(progress * 100).round()}%'),
                ],
              ),
            SyncDone(:final total) => Text('Synced $total songs. The DJ is listening.'),
            SyncFailed(:final message) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                    child: const Text('Try again'),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Replace `client/lib/main.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/screens/home_screen.dart';
import 'presentation/screens/sign_in_screen.dart';

void main() {
  runApp(const ProviderScope(child: MixtapeApp()));
}

class MixtapeApp extends ConsumerWidget {
  const MixtapeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      title: 'mixtape',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: switch (auth) {
        AuthStatus.unknown => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.signedOut => const SignInScreen(),
        AuthStatus.signedIn => const HomeScreen(),
      },
    );
  }
}
```

- [ ] **Step 5: Delete the counter test, write `client/test/screens/root_gate_test.dart`**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';

void main() {
  testWidgets('shows sign-in when signed out', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [tokenStoreProvider.overrideWithValue(InMemoryTokenStore())],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('shows home when a token exists', (tester) async {
    final store = InMemoryTokenStore()..write('tok');
    await tester.pumpWidget(ProviderScope(
      overrides: [tokenStoreProvider.overrideWithValue(store)],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
```

- [ ] **Step 6: Run everything**

Run: `cd client && flutter analyze && flutter test`
Expected: clean analyze, all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add -A client && git commit -m "feat(client): sign-in gate + home sync screen"
```

---

### Task 11: Apply migrations to Neon + deploy + device smoke (founder)

**Files:** none created — verification task.

- [ ] **Step 1: Apply migrations to Neon**

Run: `cd server && DATABASE_URL=$(grep '^DATABASE_URL=' .dev.vars | cut -d= -f2-) npx drizzle-kit migrate`
Expected: all migrations applied without error.

- [ ] **Step 2: Deploy the worker**

Run: `cd server && npx wrangler deploy && npx wrangler secret put DATABASE_URL && npx wrangler secret put BETTER_AUTH_SECRET && npx wrangler secret put BETTER_AUTH_URL && npx wrangler secret put APPLE_BUNDLE_ID`
(`BETTER_AUTH_URL` = the deployed workers.dev URL. Secrets prompt interactively — founder pastes values.)

- [ ] **Step 3 (founder, device): smoke test**

1. `cd client && flutter run --dart-define=API_BASE_URL=https://mixtape-api.<account>.workers.dev` on a real iPhone (play counts and Apple sign-in behave best on-device).
2. Sign in with Apple → expect landing on Home.
3. Tap **Sync my library** → allow media access → watch progress → "Synced N songs."
4. Verify in Neon (SQL editor): `SELECT count(*) FROM tracks;` and `SELECT play_count, last_played_at FROM user_tracks ORDER BY play_count DESC LIMIT 10;` — top rows should look like your actual most-played songs.

- [ ] **Step 4: Log completion**

Append to `docs/decisions.md` under a new dated heading if any decision changed during implementation; update the README status line to "P1 complete"; commit:

```bash
git add -A && git commit -m "chore: p1 complete"
```

---

## Out of scope for P1 (resist the urge)

- Enrichment waterfall, embeddings, curation engine (P2/P3)
- Recently-played / recommendations ingestion beyond the library (P2)
- Token refresh / 401 auto-sign-out polish, incremental (diff) sync — P2 alongside real usage
- `in_library` reconciliation (marking removed tracks false) — P2; until then `in_library` over-counts and must not be read as authoritative
- Single-CTE atomic ingest rewrite (atomicity + halved neon-http round trips) — tracked follow-up
- Auth lifecycle cluster (P2, with the 401 handling): clear stale keychain token on fresh install (keychain survives app uninstall on iOS — first-launch flag + tokenStore.clear()), in-memory token cache invalidated on write/clear (avoids a keychain round trip per request), server-side session revocation on sign-out (signOut currently only clears the keychain; the Neon session row lives until expiry — best-effort POST /api/auth/sign-out before clearing)
- Field-wise in-batch dedupe (P2 data-quality nit): dedupe() keeps the whole higher-playCount record, possibly discarding a newer lastPlayedAt from the losing duplicate, while the SQL upsert merges per-field via greatest()
- Any playback (P3)
