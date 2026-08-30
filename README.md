# mixtape

Your personal DJ. Tell it what you want to hear — a mood, a moment, a memory — and it builds the exact queue for that session from everything it knows about your taste: real play counts, genre, BPM, energy, and what the lyrics actually mean.

## Layout

- `client/` — Flutter app (iOS-first, Apple Music via native MusicKit bridge)
- `server/` — Hono API on Cloudflare Workers · Neon Postgres · Better Auth
- `web/` — pending (MusicKit JS companion, shares the server)
- `docs/` — start with [product/vision.md](docs/product/vision.md), then the [v1 design spec](docs/superpowers/specs/2026-08-29-mixtape-v1-design.md) and [decisions.md](docs/decisions.md)

## Status

P3 complete (2026-08-30, device-verified end-to-end): conversational DJ engine + session API live in prod, Flutter client shipping chat, queue (reorder/swipe/play/save-as-playlist), sessions-first home, and Haiku-named sessions. 328 server + 179 client tests. P2.5 complete (2026-08-30): local preview analysis lifted feature coverage 59.9% → 100%. P4 complete (2026-08-30): per-user DJ memory (remember_preference tool + "What the DJ knows" screen) and taste-aware scoring (swipes/keeps/plays/saves, subtle rerank). 439 server + 216 client tests. Build phases are listed at the end of the design spec.
