# mixtape

Your personal DJ. Tell it what you want to hear — a mood, a moment, a memory — and it builds the exact queue for that session from everything it knows about your taste: real play counts, genre, BPM, energy, and what the lyrics actually mean.

## Layout

- `client/` — Flutter app (iOS-first, Apple Music via native MusicKit bridge)
- `server/` — Hono API on Cloudflare Workers · Neon Postgres · Better Auth
- `web/` — pending (MusicKit JS companion, shares the server)
- `docs/` — start with [product/vision.md](docs/product/vision.md), then the [v1 design spec](docs/superpowers/specs/2026-08-29-mixtape-v1-design.md) and [decisions.md](docs/decisions.md)

## Status

P3a DJ engine deployed (304 tests, fable-reviewed): conversational agent loop + retrieval engine + session API live — /sessions dark pending ANTHROPIC_API_KEY. P3b (chat UI) next. Build phases are listed at the end of the design spec.
