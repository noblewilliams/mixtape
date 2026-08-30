# mixtape — agent instructions

Personal-DJ app: prompt → perfect Apple Music queue for the moment. Flutter client (`client/`) + Hono API on Cloudflare Workers (`server/`) + Neon Postgres (Drizzle) + Better Auth. `web/` is a pending placeholder.

**Read before working** (same list as CLAUDE.md — keep the two files in sync):
- `docs/product/vision.md` — what this is and the endgame
- `docs/superpowers/specs/2026-08-29-mixtape-v1-design.md` — v1 architecture, build phases
- `docs/decisions.md` — locked decisions with rationale; append here when a decision lands, don't relitigate silently
- `docs/backlog.md` — consolidated open items, deferred polish, reopen clauses

**Status (2026-08-30):** v1 phases P1 (auth+library sync), P2 (enrichment), P2.5 (local preview analysis — features 100%), P3 (conversational DJ, device-verified), P4 (taste learning + per-user memory, deployed) are all code-complete. Only open gate: P4 founder device smoke (script in the P4 plan §Task 5). 439 server + 216 client tests.

## Ground rules

- **Sessions-first**: the primary object is an ephemeral session queue; playlists are a conversion, not the default.
- **Never store or display lyric text** — only embeddings/theme tags (`docs/decisions.md` → lyrics stance).
- Schema stays platform-agnostic: tracks keyed by internal id + ISRC, `apple_id` is one column among future peers.
- Curation LLM is Sonnet (`claude-sonnet-5`); session titles use Haiku; escalate only the sequencing pass to Opus and only with evidence. Embeddings use a dedicated embedding model, never a chat model.
- Memory notes and all user-derived text are injected at USER altitude only, through `sanitizeForPrompt`, never into system prompts (P3a injection posture — test-pinned).
- New iOS Swift files need pbxproj target-membership.
- Workers has no NODE_ENV: any library default gated on "production" (Better Auth's secret guard, rate limiting) is silently OFF — configure explicitly and fail fast on missing env.
- `server/src/db/auth-schema.ts` is HAND-MAINTAINED (Better Auth CLI lags the runtime; regenerating drops `account.issuer` and breaks Apple sign-in).
- Prod DB driver is neon-serverless Pool (neon-http has NO transactions); one-off scripts use neon-http.
- User-scoped Riverpod providers must `ref.watch(authProvider)` in build() so auth transitions reset them; long-running services they own must cancel via `ref.onDispose`.
- Scripts touching prod: dry-run by default, `--apply` to write, fixed-string error logging (never interpolate error messages/response bodies — credential-leak lesson), `.dev.vars` loader strips surrounding quotes.
- iTunes lookup API 403s datacenter IPs — anything needing it runs locally (see `server/scripts/`).

## Conventions

- TDD (red first); server route tests + client widget/provider tests. Curation engine: golden-set structural assertions, not exact-track assertions. Full server suite: `npx vitest run --no-file-parallelism` is authoritative (PGlite cold-start contention flakes under parallel load).
- Commits: single-line subject only, conventional-commit prefix, no body, no AI attribution of any kind.
- Docs are part of every change: significant behavior/architecture shifts update the design spec or add a `docs/decisions.md` entry in the same PR; keep `docs/backlog.md` current.
- Specs in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`; execution is task-by-task with an adversarial review pass + fix round per task.
