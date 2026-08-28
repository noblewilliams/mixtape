# mixtape

Personal-DJ app: prompt → perfect Apple Music queue for the moment. Flutter client (`client/`) + Hono API on Cloudflare Workers (`server/`) + Neon Postgres (Drizzle) + Better Auth. `web/` is a pending placeholder.

Read before working:
- `docs/product/vision.md` — what this is and the endgame
- `docs/superpowers/specs/2026-08-29-mixtape-v1-design.md` — v1 architecture, build phases
- `docs/decisions.md` — locked decisions with rationale; append here when a decision lands, don't relitigate silently

## Ground rules

- **Sessions-first**: the primary object is an ephemeral session queue; playlists are a conversion, not the default.
- **Never store or display lyric text** — only embeddings/theme tags (`docs/decisions.md` → lyrics stance).
- Schema stays platform-agnostic: tracks keyed by internal id + ISRC, `apple_id` is one column among future peers.
- Curation LLM is Sonnet 5 (`claude-sonnet-5`); escalate only the sequencing pass to Opus 5 (`claude-opus-5`) and only with evidence. Embeddings use a dedicated embedding model, never a chat model.
- New iOS Swift files need pbxproj target-membership (recurring lesson from goalympics).
- GetSongBPM data requires a visible backlink to getsongbpm.com wherever we ship UI that uses it.

## Conventions

- TDD; server route tests + client widget/provider tests. Curation engine: golden-set structural assertions, not exact-track assertions.
- Docs are part of every change: significant behavior/architecture shifts update the design spec or add a `docs/decisions.md` entry in the same PR.
