# Exportify release — 2026-09-09

Isolated from live commit cace81e. Only the Exportify import implementation is
carried from the shared working tree. Existing database migrations 0025–0026
and their schema declarations are included to preserve the production ledger;
unreleased playlist-edit routes and native editing changes are not included.

Real archive acceptance: 13 CSV files, 844 unique tracks, 856 entries, zero
unresolved rows. Web and Dart canonical snapshots match. In-memory database
checks pass for initial import, idempotent repeat, partial preservation and
stale-review rejection. Raw archive data stays outside Git.

Production rollout has been authorized after real-export validation.

Validation: server 1,269 tests, web 355 tests, native 544 tests passed; server
typecheck and Flutter analysis passed. Opt-in real archive acceptance passed.
Worker dry-run and production web build passed.

Build web with `VITE_API_URL=https://mixtape-api.goalympics.workers.dev npm run build`.
Build native with `--dart-define=API_BASE_URL=https://mixtape-api.goalympics.workers.dev`.

Database rollout: `server/scripts/exportify-release.mjs` checks the full migration
ledger by default; `--apply` applies pending migrations in one transaction.
Only 0027 and 0028 are pending against production's verified 27-entry ledger.
The previous Worker remains compatible with these additive schema changes.
Rollback Worker version: `f2c5014b-a199-4398-bec9-e0dd22ac0d7e`.
Previous Netlify deploy: `6a9bffa0a3859500081f577d`.

## Production result

- Release implementation: `33e7957`; native dependency lock: `3519372`.
- Migrations: 29 matching ledger entries, all four import columns present, zero pending.
- Worker: `cc7261da-d02f-4bdc-82b0-d3a3d7a87369`. Health returns 200;
  unauthenticated Spotify review returns 401.
- Web: https://miixtape.netlify.app, deploy `6aa1b14474726bde60819fe0`.
  Production serves `index-BS9iWETN.js`; browser session check completes and
  enables Apple and Google sign-in.
- Signed iOS archive and App Store IPA built: version 1.0.0, build 2026090901.
  Artifact: `client/build/releases/Mixtape-1.0.0-2026090901.ipa` in the shared checkout.
  TestFlight upload and physical-device testing have not run. Xcode reports
  existing placeholder app-icon and launch-image assets.
- Authenticated production import was not run; the real archive was tested
  only locally, including the production import pipeline against in-memory Postgres.
- GitHub push was initially blocked by automatic approval review because the
  destination had not been verified. The destination is now verified as the public
  `noblewilliams/mixtape` repository with ADMIN access. The user explicitly approved publishing the release branch, and
  `codex/exportify-release-2026-09-09` was pushed successfully. No merge into main
  was attempted.

Approved UX: compact actions, no decorative left-border containers, Exportify
ZIP/CSV import first, explicit manual refresh review, official Spotify data
requests under Go deeper.
