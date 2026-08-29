# P3a — DJ Engine + API Implementation Plan

> **For agentic workers:** execute task-by-task with a fresh implementer per task and reviews between tasks (established repo cadence). Steps use checkbox syntax. TDD: red first, always.

**Goal:** Everything server-side for the DJ conversation: session/queue data model, the retrieval+scoring engine, the Sonnet 5 agent loop with queue tools, and the authed session API — leaving P3b a pure client build.

**Architecture:** Sessions own one canonical queue. `POST /sessions/:id/messages` runs a bounded Sonnet 5 tool-use loop (`generate_queue`, `edit_queue`) whose tools execute against the engine (pgvector similarity + feature scoring over the taste graph) and the queue store. Manual `queue-ops` hit the same store without the LLM. Every external surface sits behind an injected seam (LlmClient, Embedder — same DI pattern as EnrichDeps) so tests run on PGlite + fakes.

**Tech Stack:** existing Hono/Drizzle/Neon/PGlite stack, `@anthropic-ai/sdk` (Workers-compatible), model `claude-sonnet-5`, Workers AI bge-m3 for intent embeddings (existing Embedder seam), pgvector HNSW.

**Working directory:** `~/Documents/work/mixtape` — paths relative to repo root. Branch `main`.

**Founder setup (before Task 9):** put the Anthropic key on the worker yourself — `cd server && npx wrangler secret put ANTHROPIC_API_KEY` (paste when prompted); add it to `server/.dev.vars` too.

**Facts already established (don't re-derive):** track_meanings.embedding is vector(1024) bge-m3; Db type = PgDatabase<PgQueryResultHKT, typeof schema>; raw db.execute returns `{rows}` snake_case (normalize like runner.ts); PGlite + @electric-sql/pglite-pgvector supports HNSW; auth pattern = requireSession → c.get('user'); test helper createTestDb() inside it() only.

---

### Task 1: Schema — dj_sessions, dj_messages, queue_tracks + HNSW index

**Files:** modify `server/src/db/schema.ts`; create migration 0005 (generated + hand-add index); extend `server/test/db.test.ts`.

- [ ] **Step 1: failing tests** (append to db.test.ts):

```ts
import { djSessions, djMessages, queueTracks } from '../src/db/schema'

it('round-trips a dj session with messages and queue tracks', async () => {
  const db = await createTestDb()
  await db.insert(user).values({ id: 'u1', name: 'T', email: 'dj@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  const [s] = await db.insert(djSessions).values({ userId: 'u1', title: 'rainy drive' }).returning()
  expect(s.status).toBe('active')
  expect(s.queueVersion).toBe(0)
  await db.insert(djMessages).values({ sessionId: s.id, role: 'user', content: 'rainy night drive' })
  const [track] = await db.insert(tracks).values({ appleId: 'q1', title: 'T', artist: 'A' }).returning()
  await db.insert(queueTracks).values({ sessionId: s.id, position: 0, trackId: track.id, reason: 'moody', addedBy: 'dj' })
  const rows = await db.select().from(queueTracks)
  expect(rows[0].state).toBe('active')
})

it('cascades session deletion to messages and queue', async () => {
  const db = await createTestDb()
  await db.insert(user).values({ id: 'u2', name: 'T', email: 'dj2@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  const [s] = await db.insert(djSessions).values({ userId: 'u2', title: 't' }).returning()
  await db.insert(djMessages).values({ sessionId: s.id, role: 'dj', content: 'hi' })
  await db.delete(djSessions).where(eq(djSessions.id, s.id))
  expect(await db.select().from(djMessages)).toHaveLength(0)
})
```

- [ ] **Step 2: red**, then extend schema.ts:

```ts
export const djSessions = pgTable('dj_sessions', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: text('user_id').notNull().references(() => user.id, { onDelete: 'cascade' }),
  title: text('title').notNull(),
  status: text('status', { enum: ['active', 'archived'] }).notNull().default('active'),
  queueVersion: integer('queue_version').notNull().default(0),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => [index('dj_sessions_user_idx').on(t.userId, t.createdAt)])

export const djMessages = pgTable('dj_messages', {
  id: uuid('id').primaryKey().defaultRandom(),
  sessionId: uuid('session_id').notNull().references(() => djSessions.id, { onDelete: 'cascade' }),
  role: text('role', { enum: ['user', 'dj'] }).notNull(),
  content: text('content').notNull(),
  queueVersion: integer('queue_version'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [index('dj_messages_session_idx').on(t.sessionId, t.createdAt)])

export const queueTracks = pgTable('queue_tracks', {
  id: uuid('id').primaryKey().defaultRandom(),
  sessionId: uuid('session_id').notNull().references(() => djSessions.id, { onDelete: 'cascade' }),
  position: integer('position').notNull(),
  trackId: uuid('track_id').notNull().references(() => tracks.id, { onDelete: 'cascade' }),
  reason: text('reason'),
  state: text('state', { enum: ['active', 'removed'] }).notNull().default('active'),
  addedBy: text('added_by', { enum: ['dj', 'user'] }).notNull(),
  removedBy: text('removed_by', { enum: ['dj', 'user'] }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => [index('queue_tracks_session_idx').on(t.sessionId, t.state, t.position)])
```

- [ ] **Step 3:** `npx drizzle-kit generate` → 0005; hand-append to the SQL (statement-breakpoint separated): `CREATE INDEX track_meanings_embedding_hnsw_idx ON track_meanings USING hnsw (embedding vector_cosine_ops);` (safe: index build on 4.6k rows is seconds; hand-added because drizzle's HNSW support is version-dependent — if the installed drizzle-kit supports `.using('hnsw'...)` in-schema, prefer that and report).
- [ ] **Step 4:** `npm test` green (PGlite must build the HNSW index — if pglite-pgvector lacks HNSW, report BLOCKED with evidence; ivfflat fallback is acceptable with a comment) + typecheck.
- [ ] **Step 5: Commit** `feat(server): dj session + queue schema`.

---

### Task 2: LLM client seam

**Files:** create `server/src/dj/llm.ts`; test `server/test/dj/llm.test.ts`. `cd server && npm install @anthropic-ai/sdk`.

- [ ] **Step 1: failing test** — the seam is typed, the REAL impl is a thin adapter (verified live in Task 10):

```ts
import { describe, it, expect } from 'vitest'
import { anthropicLlm, type LlmTurn } from '../../src/dj/llm'

it('adapts anthropic responses into LlmTurn', async () => {
  const fakeCreate = async (req: unknown) => ({
    content: [
      { type: 'text', text: 'here you go' },
      { type: 'tool_use', id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } },
    ],
    stop_reason: 'tool_use',
  })
  const llm = anthropicLlm({ messages: { create: fakeCreate } } as never)
  const turn: LlmTurn = await llm({ system: 's', messages: [], tools: [] })
  expect(turn.text).toBe('here you go')
  expect(turn.toolCalls).toEqual([{ id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } }])
})
```

- [ ] **Step 2: red**, then create `server/src/dj/llm.ts` — **amended shape** (post-review; thinking-aware + replayable + bounded client, no `as never` in tests):

```ts
import Anthropic from '@anthropic-ai/sdk'

export type LlmToolDef = {
  name: string
  description: string
  input_schema: { type: 'object'; properties: Record<string, unknown>; required?: string[] }
}

// Assistant content blocks. `thinking` is opaque — Sonnet 5 runs adaptive thinking by
// default and thinking blocks must be replayed back to the API verbatim (never
// reconstructed) when continuing on the same model, so we don't parse its shape here.
export type LlmAssistantBlock =
  | { type: 'text'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: unknown }
  | { type: 'thinking'; [k: string]: unknown }

export type LlmMessage =
  | { role: 'user' | 'assistant'; content: string }
  | { role: 'user'; content: Array<{ type: 'tool_result'; tool_use_id: string; content: string }> }
  | { role: 'assistant'; content: LlmAssistantBlock[] }

export type LlmRequest = {
  system: string
  messages: LlmMessage[]
  tools: LlmToolDef[]
  maxTokens?: number
  effort?: 'low' | 'medium' | 'high'
}
export type LlmToolCall = { id: string; name: string; input: unknown }
export type LlmTurn = {
  text: string
  toolCalls: LlmToolCall[]
  raw: LlmAssistantBlock[] // full assistant content, for verbatim replay (includes thinking blocks)
  stopReason: string | null // 'max_tokens' must be detectable (curation truncation)
  usage: { inputTokens: number; outputTokens: number } | null
}
export type LlmClient = (req: LlmRequest) => Promise<LlmTurn>

export const DJ_MODEL = 'claude-sonnet-5'
const DEFAULT_MAX_TOKENS = 16000

// Thrown by anthropicLlm on any SDK failure. Callers (the agent loop) classify on
// this type alone and never import the SDK — deliberately excludes the SDK's own
// error message, which can echo request content (system prompt, user text, tool input).
export class LlmError extends Error {
  constructor(
    readonly detail: string,
    readonly status?: number,
  ) {
    super(`anthropic: ${detail}`)
    this.name = 'LlmError'
  }
}

// Structural surface of the real SDK client — a fake `{ messages: { create } }` in
// tests satisfies this directly, no `as never` needed in either direction.
type AnthropicClient = {
  messages: {
    create(body: Anthropic.MessageCreateParamsNonStreaming): Promise<{
      content: Anthropic.ContentBlock[]
      stop_reason: string | null
      usage: { input_tokens: number; output_tokens: number }
    }>
  }
}

export function anthropicLlm(client: AnthropicClient): LlmClient {
  return async (req) => {
    let res: Awaited<ReturnType<AnthropicClient['messages']['create']>>
    try {
      res = await client.messages.create({
        model: DJ_MODEL,
        max_tokens: req.maxTokens ?? DEFAULT_MAX_TOKENS,
        system: req.system,
        messages: req.messages as Anthropic.MessageParam[],
        tools: req.tools,
        ...(req.effort ? { output_config: { effort: req.effort } } : {}),
      })
    } catch (e) {
      throw new LlmError(
        e instanceof Anthropic.APIError ? `HTTP ${e.status ?? 'unknown'}` : e instanceof Error ? e.name : typeof e,
        e instanceof Anthropic.APIError ? e.status : undefined,
      )
    }
    const raw = res.content as LlmAssistantBlock[]
    const text = raw
      .filter((b): b is { type: 'text'; text: string } => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
    const toolCalls = raw
      .filter((b): b is { type: 'tool_use'; id: string; name: string; input: unknown } => b.type === 'tool_use')
      .map((b) => ({ id: b.id, name: b.name, input: b.input }))
    return {
      text,
      toolCalls,
      raw,
      stopReason: res.stop_reason,
      usage: res.usage ? { inputTokens: res.usage.input_tokens, outputTokens: res.usage.output_tokens } : null,
    }
  }
}

export function buildAnthropic(apiKey: string): Anthropic {
  // Chat turns run inside a Worker request — fail fast instead of the SDK default
  // (10 min timeout × up to 3 attempts), which would tie up the whole request.
  return new Anthropic({ apiKey, timeout: 60_000, maxRetries: 1 })
}
```

(Installed SDK `@anthropic-ai/sdk` 0.122.0. The real client types (`Anthropic.MessageParam`, `Anthropic.ContentBlock`, `Anthropic.MessageCreateParamsNonStreaming`) resolved cleanly against the seam's own types with a single `as` cast each — no `as never` and no `any` needed anywhere, including in the tests, once `AnthropicClient` was narrowed to a structural `{ messages: { create } }` shape. SDK error base class is `Anthropic.APIError` — it carries `status`, `error` (raw JSON body — may echo request content, never surfaced), and `requestID`; `LlmError` deliberately drops everything but `status`.)
- [ ] **Step 3:** tests + typecheck green. **Commit** `feat(server): llm client seam`. **Amendment commit** `fix(server): replayable llm turns + bounded client`.

---

### Task 3: Intent + queue-op contracts

**Files:** create `server/src/dj/contracts.ts`; test `server/test/dj/contracts.test.ts`.

- [ ] **Step 1: failing tests** for the zod schemas: valid intent parses (themes required non-empty; tempoMin/Max optional ints 40–260; energyArc enum ['rise','fall','arc','steady'] optional; eraFrom/eraTo optional 1900–2100; allowExplicit boolean default true; familiarity enum ['comfort','mix','adventurous'] default 'mix'; targetCount int 3–60 default 15); each edit op parses (remove{position}, move{from,to}, swap{position, intent?}, extend{count 1–20, intent?}); invalid op name rejected; targetCount default applied.
- [ ] **Step 2: red**, then implement with zod (export `intentSchema`, `queueOpSchema`, `queueOpsSchema = z.array(queueOpSchema).min(1).max(20)`, inferred types `Intent`, `QueueOp`). Also export the TOOL DEFINITIONS handed to the LLM:

```ts
export const DJ_TOOLS = [
  {
    name: 'generate_queue',
    description: 'Create a fresh queue for this session from the listener\'s request. Replaces any existing queue. Convert requested durations to a track count (~3.5 min per track). themes: a rich free-text description of mood, meaning and vibe used for semantic matching against lyric meaning.',
    input_schema: /* zod-to-JSON-schema by hand: object with the intent fields above, required: ['themes'] */,
  },
  {
    name: 'edit_queue',
    description: 'Modify the current queue in place. ops run in order. Use swap/extend with an intent when the listener asked for a different flavour; omit intent to stay on the session\'s current vibe.',
    input_schema: /* { ops: array of the op union } */,
  },
] as const
```

Write the JSON schemas out longhand (they're small); a test asserts each tool's input_schema accepts what the matching zod schema accepts for 2–3 samples (parse both ways) so the two can't drift silently.
- [ ] **Step 3:** green + typecheck. **Commit** `feat(server): dj intent contracts`.

---

### Task 4: Candidate pool + scoring

**Files:** create `server/src/dj/pool.ts`; test `server/test/dj/pool.test.ts`.

- [ ] **Step 1: failing tests** over seeded PGlite (helper seeds a user + ~30 tracks with controlled features/meanings/play counts; fake Embedder returns a fixed unit vector so cosine is deterministic — seed some track embeddings equal/near/far from it):
  - hard filters hold (tempo window excludes out-of-range; explicit=false excludes explicit tracks; era range excludes)
  - a track with NO features still appears when it has meaning-similarity (and vice versa) — missing dimensions score 0, don't exclude
  - familiarity 'comfort' ranks high-play-count tracks above similar low-play tracks; 'adventurous' flattens that weight
  - pool size = min(15 × targetCount, 300, available)
  - only the requesting user's library (user_tracks join) is eligible
- [ ] **Step 2: red**, then implement `buildPool(db, embed, userId, intent): Promise<PoolTrack[]>`:
  - embed(intent.themes) → vector; sql: user_tracks JOIN tracks LEFT JOIN track_features LEFT JOIN track_meanings, WHERE filters (skip each filter when intent field absent; explicit filter uses `coalesce(tracks.explicit, false) = false` when allowExplicit is false), scored: `w_sim * COALESCE(1 - (tm.embedding <=> ${vecLiteral}), 0) + w_feat * <feature-fit expr> + w_fam * LN(1 + ut.play_count)` with weights by familiarity preset; ORDER BY score DESC LIMIT poolSize. Feature-fit: proximity of tempo to the window centre + energy presence — keep the expression simple and DOCUMENTED; P4 tunes it.
  - vector literal binding: `[v1,v2,...]` string cast `::vector` (parameterized as a string — never interpolate user text).
  - Returns rows with id, appleId, title, artist, playCount, tempo, energy, valence, releaseYear, durationMs, score.
- [ ] **Step 3:** green + typecheck. **Commit** `feat(server): candidate pool + scoring`.

---

### Task 5: Curation pass

**Files:** create `server/src/dj/curate.ts`; test `server/test/dj/curate.test.ts`.

- [ ] **Step 1: failing tests** with a FAKE LlmClient (scripted): given a 40-track pool and targetCount 10, returns 10 ordered {trackId, reason} drawn ONLY from the pool (fake returns some invalid ids → they're dropped and backfilled from pool order); count honored even when the fake under-returns; reasons default '' when absent; pool prompt includes play counts + features compactly; the pool block carries `cache_control` (assert via captured request).
- [ ] **Step 2: red**, then implement `curate(llm, pool, intent, sessionContext): Promise<Array<{trackId, reason}>>`:
  - One LLM call, NO tools: system = curation instructions (sequence for the intent's arc, respect targetCount, one short reason per track, output STRICT JSON `[{"id":"...","reason":"..."}]` and nothing else); user content = [poolBlock (one line per track: id | title — artist | plays | bpm | energy | valence | year, with `cache_control: {type:'ephemeral'}`), intentBlock].
  - Parse defensively (extract first JSON array; validate ids against pool; truncate/backfill to targetCount).
  - **Truncation is a failure, not parse noise**: when `turn.stopReason === 'max_tokens'`, do NOT silently backfill — retry once with `maxTokens` doubled; if still truncated, throw a typed CurationTruncated error (the loop surfaces it as a DJ apology rather than shipping a silently-uncurated queue). Test: fake returning stopReason 'max_tokens' first call, ok second → succeeds with one retry; 'max_tokens' twice → throws.
- [ ] **Step 3:** green + typecheck. **Commit** `feat(server): curation pass`.

---

### Task 6: Queue store

**Files:** create `server/src/dj/queue-store.ts`; test `server/test/dj/queue-store.test.ts`.

- [ ] **Step 1: failing tests**: replaceQueue writes tracks positions 0..n-1 and bumps session queueVersion; getActiveQueue returns active ordered; applyOps: remove marks state removed + removedBy + closes position gap; move reorders; ops are validated against current length (out-of-range → typed QueueOpError, nothing applied — all-or-nothing); extend appends; version bumps once per applyOps call; a second replaceQueue clears prior rows (hard delete of the session's rows — history lives in messages, not queue rows).
- [ ] **Step 2: red**, then implement (plain drizzle; positions renumbered on write; swap at store level = remove+insert-at using a provided replacement track — the ENGINE decides replacements, the store just applies). Export types `QueueTrackView` (joined with tracks for api responses: position, trackId, appleId, title, artist, reason, durationMs).
- [ ] **Step 3:** green + typecheck. **Commit** `feat(server): queue store`.

---

### Task 7: Agent loop

**Files:** create `server/src/dj/loop.ts`; test `server/test/dj/loop.test.ts`.

- [ ] **Step 1: failing tests** with scripted fake LlmClient sequences:
  - user msg → LLM returns tool_use generate_queue → engine (fake pool+curate injected via DjDeps) fills queue → tool_result fed back → LLM returns text → both messages persisted, dj message has new queueVersion, response contains queue
  - edit flow: LLM returns edit_queue(ops) → store applies → version bump
  - LLM returns text only → no queue change, queueVersion null on message
  - loop bound: MAX_TURNS=4 tool rounds → if exceeded, returns with a fallback text and whatever queue state exists (no infinite loops)
  - LLM throws → typed DjError; user message persisted, NO dj message, queue untouched
  - invalid tool input (zod fails) → tool_result carries the validation error text, loop continues (model can correct)
- [ ] **Step 2: red**, then implement `runDjTurn(db, deps: DjDeps, session, userText): Promise<DjTurnResult>` where `DjDeps = { llm: LlmClient; embed: Embedder }`:
  - Build system prompt: DJ persona (warm, brief, music-literate; NEVER invent tracks — queues come only from tools; convert durations to counts; when the listener manually removed tracks since last turn, acknowledge and adapt), plus compact session context (current queue summary line + last removals with removedBy=user since previous dj message).
  - History window: last 12 messages — replay assistant turns via turn.raw verbatim (includes thinking blocks); never reconstruct from text.
  - Tool execution: generate_queue → intentSchema.parse → buildPool → curate → replaceQueue; edit_queue → queueOpsSchema.parse → for swap/extend with intent: pool+curate for the replacement count; then applyOps.
  - Persist user message first, dj message on success (content = final text, queueVersion when changed).
- [ ] **Step 3:** green + typecheck. **Commit** `feat(server): dj agent loop`.

---

### Task 8: Session routes

**Files:** create `server/src/routes/sessions.ts`; modify `server/src/app.ts`; tests `server/test/dj/routes.test.ts`.

- [ ] **Step 1: failing tests** (createApp gains optional `dj: { deps: DjDeps }`; all routes behind requireSession; stub auth pattern from ingest tests; seeded PGlite):
  - POST /sessions {prompt} → 200 {session, messages[2], queue[]} (creates session titled from prompt ≤60 chars, runs the first dj turn via fake deps)
  - GET /sessions → user's sessions newest-first; other users' sessions invisible (seed two users)
  - GET /sessions/:id → messages + active queue; 404 for another user's session id
  - POST /sessions/:id/messages {text} → dj turn result
  - POST /sessions/:id/queue-ops {ops} → applies WITHOUT LLM (fake llm asserts zero calls), returns updated queue; removals recorded removedBy user
  - 400s on empty text/invalid ops
- [ ] **Step 2: red**, then implement routes + wiring (mirror ingest/enrich mounting: `if (db && dj) { app.use('/sessions/*', requireSession(auth)); app.route('/sessions', sessionRoutes(db, dj.deps)) }`). Roadmap comment: `/sessions/* [P3 live]`.
- [ ] **Step 3:** green + typecheck; existing createApp callers unaffected. **Commit** `feat(server): dj session routes`.

---

### Task 9: index wiring + config

**Files:** modify `server/src/index.ts`, `server/wrangler.jsonc`.

- [ ] Bindings add `ANTHROPIC_API_KEY?: string`. `buildDjDeps(env)`: requires `env.ANTHROPIC_API_KEY && env.AI` → `{ llm: anthropicLlm(buildAnthropic(env.ANTHROPIC_API_KEY)), embed: workersAiEmbedder(env.AI) }`; wire `dj` into createApp (absent → routes 404, same fail-loud-by-absence convention as enrich). wrangler secrets comment gains ANTHROPIC_API_KEY.
- [ ] Boot smoke (wrangler dev + /health) green; full `npm test` + typecheck. **Commit** `feat(server): wire dj engine`.

---

### Task 10: Deploy + live smoke (coordinator-run)

- [ ] Founder sets `ANTHROPIC_API_KEY` secret (see setup note). Apply migration 0005 to Neon (pre-flight: additive tables + one index; HNSW build on 4.6k rows is seconds). Deploy.
- [ ] Live smoke with a real bearer token (mint via internalAdapter against prod DB is NOT possible — instead the founder's device signs in; alternatively curl the native sign-in with a captured token — simplest: coordinator uses a short node script with the founder's session token captured from the app run, OR defer full E2E to P3b device smoke and here verify: unauth 401s on /sessions, a synthetic user via Better Auth admin... keep it simple: verify 401 + deploy health; the REAL conversational smoke happens in P3b's device pass where sign-in exists).
- [ ] Record engine cost observations (tokens per generate from the Anthropic response usage — log line) in docs/decisions.md; update README status.

---

## Out of scope for P3a
- All UI (P3b) · streaming · taste-signal learning (P4) · playlist creation (P3b bridge) · familiarity dial UI · prompt-cache tuning beyond the pool block
