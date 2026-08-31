# Playlist Intelligence Phase 0–1 Implementation Plan

> Execute task-by-task with a red-first test, implementation, adversarial review, and fix round for every task. Do not begin Phase 2 playlist sync until both Phase 0 evidence gates are recorded.

**Goal:** Lock the Apple runtime contract on real infrastructure, raise the app minimum to iOS 16, and ship album artwork metadata—URL, dimensions, and `artwork_bg_color`—through the server and existing client data contracts without adding playlist sync or UI yet.

**Architecture:** Reuse the MusicKit ES256 signer introduced by the web integration, but split it into origin-bound browser tokens and server-only catalog tokens. A typed Apple catalog client fetches song metadata in batches of at most 300. Artwork is stored globally on `tracks`, retried by an independent artwork runner, and exposed as optional metadata in every existing mix response. A temporary Cloudflare-runtime probe and a temporary DEBUG-only iPhone harness establish the two unknown Apple capabilities before later playlist plans are written.

**Tech stack:** Existing Hono/Drizzle/Neon/Vitest server; `jose` ES256 signer; Apple Music Catalog API; Flutter/Dart models; native Swift MusicKit only for the device capability spike.

**Working directory:** `/Users/admin/Documents/work/mixtape`. Work directly on `main` as requested. Preserve unrelated working-tree changes and never stage them accidentally.

**Design source:** `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`.

## Preconditions and collision boundary

- The concurrent web integration currently owns uncommitted changes under `server/src/musickit/`, `server/src/routes/musickit.ts`, `server/src/app.ts`, `server/src/index.ts`, `server/wrangler.jsonc`, and related tests.
- **Do not start Task 2 until those changes are committed and the working tree no longer shows another task editing those files.** Re-read the committed contract; do not apply this plan against a remembered snapshot.
- `MUSICKIT_KEY_ID` and `MUSICKIT_PRIVATE_KEY` remain secrets. Never print, interpolate into errors, or pass them in a shell command captured in logs.
- The Apple Developer App ID must have the MusicKit service enabled and the iPhone provisioning profile must be refreshed before the native probe.
- External actions require action-time confirmation: Cloudflare remote runtime, developer-portal changes, disposable Apple Music playlist mutations, production migration, production deploy, and production backfill.
- All production deploys come from a clean git worktree at committed HEAD. Never deploy from the shared working tree.

## Binding facts—do not re-derive during execution

- Minimum iOS version is locked to 16. The current repo still declares 13 in the Podfile comment, Flutter framework plist, and three Xcode build settings.
- Apple catalog song lookup: `GET /v1/catalog/{storefront}/songs?ids=...`, at most 300 IDs.
- Apple artwork provides an HTTPS URL/template, width, height, and background colour. Store background colour as lowercase six-digit hex without `#`.
- The founder's catalog IDs require the Nigerian storefront; use `ng` for this phase. Per-user storefront persistence lands with playlist sync in Phase 2.
- The Worker-side iTunes endpoint is blocked. Do not use it to validate artwork.
- Browser MusicKit developer tokens include an origin restriction. Server-to-Apple catalog tokens must omit `origin` and must never be returned in HTTP responses.
- Artwork failure state is independent of `enrichment_failures`; adding an `artwork` stage there would make the existing exhausted-feature status query count artwork failures incorrectly.
- Phase 1 does not add album entities, playlist tables, playlist UI, or image storage.

---

## Phase 0 — capability evidence

### Task 1: Raise the minimum deployment target to iOS 16

**Files:**
- Modify: `client/ios/Podfile`
- Modify: `client/ios/Flutter/AppFrameworkInfo.plist`
- Modify: `client/ios/Runner.xcodeproj/project.pbxproj`
- Test/build: existing Flutter and Xcode build surfaces

- [ ] **Step 1: Capture the red precondition.** Run:

  ```sh
  rg -n "13\.0|MinimumOSVersion" client/ios --glob '!Pods/**' --glob '!Flutter/ephemeral/**'
  ```

  Expected: the Podfile advertises 13.0, `AppFrameworkInfo.plist` has 13.0, and all three Runner build configurations have `IPHONEOS_DEPLOYMENT_TARGET = 13.0`.

- [ ] **Step 2: Make the minimum consistent.** Using `apply_patch`:
  - set/uncomment `platform :ios, '16.0'` in `client/ios/Podfile`;
  - set `MinimumOSVersion` to `16.0` in `client/ios/Flutter/AppFrameworkInfo.plist`;
  - set all Runner `IPHONEOS_DEPLOYMENT_TARGET` values to `16.0`.

  Do not edit generated Pods project files directly.

- [ ] **Step 3: Refresh generated iOS dependencies.** Run `flutter pub get`, then `cd client/ios && pod install` only if the lock/workspace needs regeneration. Review the diff; do not accept unrelated dependency upgrades.

- [ ] **Step 4: Verify the declaration.** Repeat the `rg` command. Expected: no project-owned 13.0 declaration remains and every relevant value is 16.0.

- [ ] **Step 5: Build and test.** Run:
  - `cd client && flutter test`
  - `cd client && flutter build ios --no-codesign`

  Record any unrelated existing failure separately; touched-path build must pass.

- [ ] **Step 6: Adversarial review.** Check Debug/Profile/Release, framework plist, Podfile, and Xcode project all agree. Verify no Pods project or signing identity was hand-edited.

- [ ] **Step 7: Commit only target-related files.** Commit headline: `chore(client): Require iOS 16`.

### Task 2: Split MusicKit token modes and add the Apple catalog client

**Start gate:** the concurrent web MusicKit signer work is committed. Re-read its tests and production wiring before editing.

**Files:**
- Modify: `server/src/musickit/token.ts`
- Modify: `server/test/musickit.test.ts`
- Create: `server/src/musickit/catalog.ts`
- Create: `server/test/musickit/catalog.test.ts`
- Modify: `server/src/app.ts` and `server/src/index.ts` only as required by the committed signer contract

- [ ] **Step 1: Write failing token-mode tests.** Preserve the existing browser-origin test and add assertions that:
  - `generateMusicKitDeveloperToken` accepts an explicit server mode or omitted origin;
  - the verified server JWT has `iss`, `iat`, and `exp` but no `origin` claim;
  - the server token is not exposed by `GET /musickit/token`;
  - invalid/partial MusicKit configuration still fails fast.

- [ ] **Step 2: Write failing catalog tests.** In `catalog.test.ts`, cover:
  - batches are capped at 300 IDs;
  - IDs and storefront are URL-encoded with `URL`/`URLSearchParams`;
  - `Authorization: Bearer <token>` is sent through an injected fetch seam;
  - response order is irrelevant—results map by Apple ID;
  - artwork maps URL, positive dimensions, and lowercase background colour;
  - missing artwork remains null;
  - malformed URL/colour/dimensions reject only that artwork payload, not the entire valid song;
  - 401/403, 429, 5xx, timeout, and malformed JSON become fixed-category typed errors containing status/category only, never response text;
  - no request over 300 is issued even if a caller passes more IDs.

- [ ] **Step 3: Run red tests.** `cd server && npx vitest run test/musickit.test.ts test/musickit/catalog.test.ts` must fail for missing server mode/client.

- [ ] **Step 4: Generalize the signer without weakening the browser route.** Keep one ES256 implementation. The signed payload includes `origin: [allowedOrigin]` only in browser mode. Server mode omits it. Keep the existing short TTL and validation; never add a long-lived static developer token to config.

- [ ] **Step 5: Implement the catalog client behind structural seams.** Proposed surface:

  ```ts
  export type ArtworkMetadata = {
    url: string
    width: number | null
    height: number | null
    bgColor: string | null
  }

  export type CatalogSong = {
    appleId: string
    isrc: string | null
    title: string
    artist: string
    album: string | null
    artwork: ArtworkMetadata | null
  }

  export type AppleCatalogClient = {
    getSongs(storefront: string, appleIds: readonly string[]): Promise<Map<string, CatalogSong>>
  }
  ```

  Inject `fetchLike` and `issueServerToken`. Validate artwork with a dedicated pure parser. Accept HTTPS Apple CDN URLs/templates only, cap stored URL length, normalize colour, and never trust array position.

- [ ] **Step 6: Wire a server-only token issuer.** Browser route wiring remains origin-bound. Catalog wiring receives an internal `issueServerToken` function and is not mounted as a token endpoint. Cache only the signed token and expiry in Worker-isolate memory with a refresh margin; never cache the private key import outside the established safe signer boundary unless review confirms it is isolate-safe.

- [ ] **Step 7: Run focused checks.** `cd server && npx vitest run test/musickit.test.ts test/musickit/catalog.test.ts && npm run typecheck`.

- [ ] **Step 8: Adversarial review.** Specifically try:
  - an Apple response with a requested ID missing;
  - an extra unrequested ID;
  - a `javascript:`/HTTP artwork URL;
  - a colour containing `#`, whitespace, or seven characters;
  - a server JWT accidentally returned from a route;
  - error handling that includes Apple response bodies.

- [ ] **Step 9: Fix findings and run the authoritative server suite.** `cd server && npx vitest run --no-file-parallelism && npm run typecheck`.

- [ ] **Step 10: Commit only the signer/catalog unit.** Commit headline: `feat(server): Apple Music catalog client`.

### Task 3: Verify catalog access from Cloudflare's runtime

**Files:**
- Temporarily create: `server/scripts/probe-apple-catalog-worker.ts`
- Modify after evidence: `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`
- Modify after evidence: `docs/decisions.md`
- Delete before commit: `server/scripts/probe-apple-catalog-worker.ts`

- [ ] **Step 1: Add a temporary minimal Worker entrypoint.** It imports the committed signer/catalog client, reads one known founder Apple ID from an uncommitted `.dev.vars` key such as `MUSICKIT_PROBE_APPLE_ID`, uses `ng`, and returns only:

  ```json
  {
    "ok": true,
    "matched": 1,
    "hasArtwork": true,
    "hasBackgroundColor": true
  }
  ```

  It must never return the token, URL, title, artist, album, raw colour, or upstream response. Guard it with `ENRICH_ADMIN_TOKEN` using a constant-time comparison where practical. Use fixed error categories.

- [ ] **Step 2: Run local unit/type checks** before any network call.

- [ ] **Step 3: Ask for action-time approval** to use Cloudflare remote development with MusicKit secrets. This is an external network/runtime action.

- [ ] **Step 4: Run on Cloudflare's network, not local Node.** From `server/`, use the installed Wrangler remote-development mode against the temporary entrypoint on a dedicated port. Keep secrets in `.dev.vars`; do not put them on the command line or in captured output.

- [ ] **Step 5: Call the localhost proxy with the admin guard** using a task-specific shell variable such as `MIXTAPE_PROBE_TOKEN`. Do not echo it. Expected: `ok: true`, one match, artwork present, background colour valid.

- [ ] **Step 6: Test the negative path.** An invalid admin token returns 401/403 without making the Apple request. A deliberately unknown Apple ID returns a sanitized no-match result, not upstream content.

- [ ] **Step 7: Stop remote dev and remove the temporary entrypoint.** Confirm `git status` has no probe source file.

- [ ] **Step 8: Record evidence.** Update the design spec's open question and append a decision entry with date, Cloudflare remote-runtime result, storefront, response category, and whether the Phase 1 client is approved. Do not record track metadata or secrets.

- [ ] **Step 9: Commit documentation only.** Commit headline: `docs: Record Apple catalog probe`.

**Gate:** If Cloudflare receives 401/403 from Apple despite a verified token, stop. Diagnose token/App Service configuration before artwork schema work. If Apple blocks Cloudflare infrastructure, mark the goal blocked and redesign around client-fetched metadata; do not fall back to the already-blocked iTunes endpoint.

### Task 4: Verify playlist ownership and exact rebuild on the founder's iPhone

**Files:**
- Temporarily modify: `client/ios/Runner/MusicKitBridge.swift`
- Temporarily modify: `client/lib/data/musickit/musickit_bridge.dart`
- Temporarily modify: `client/lib/main.dart` or add a DEBUG-only probe entrypoint
- Modify after evidence: `docs/superpowers/specs/2026-08-31-artwork-playlist-intelligence-design.md`
- Modify after evidence: `docs/decisions.md`
- Remove all probe-only code before commit

- [ ] **Step 1: Verify developer configuration.** Confirm the App ID has MusicKit enabled, refresh provisioning, and confirm `NSAppleMusicUsageDescription` remains present. Do not commit profiles or keys.

- [ ] **Step 2: Prepare two disposable playlists.** Ask the user to identify/prepare:
  - one small playlist created through Mixtape's current create-playlist flow;
  - one small playlist created directly in Music.

  Each should contain only a few non-sensitive tracks and be safe to no-op rebuild. This is setup, not permission to mutate them yet.

- [ ] **Step 3: Add a temporary DEBUG-only capability method.** Under `#if DEBUG`, fetch the two disposable playlists, resolve their current items, and attempt `MusicLibrary.shared.edit(...items:)` with the **same ordered items**. Return only fixed categories:

  ```text
  mixtapeCandidateFound
  mixtapeExactRebuild: supported | rejected | failed
  externalCandidateFound
  externalExactRebuild: supported | rejected | failed
  ```

  Do not print playlist names, IDs, descriptions, track metadata, or localized Apple error text. Production ownership must not infer from name/description; any marker used to locate the disposable probe candidate is probe-only.

- [ ] **Step 4: Add a temporary opt-in trigger.** It runs only in DEBUG with `--dart-define=MUSICKIT_CAPABILITY_PROBE=true`. A normal debug/release build never invokes it.

- [ ] **Step 5: Compile before device mutation.** Run `cd client && flutter test && flutter build ios --no-codesign`.

- [ ] **Step 6: Ask for action-time approval** immediately before the no-op Apple Music mutations. Explain the exact two disposable playlists and that modified timestamps may change even though track order is identical.

- [ ] **Step 7: Run on the founder's iPhone** and capture only the fixed capability categories. Manually verify both playlists still contain the same ordered tracks in Music.

- [ ] **Step 8: Remove every probe-only change.** Re-run `git diff` and search for `MUSICKIT_CAPABILITY_PROBE`/`probePlaylist`; expected: no matches. The committed app must contain no hidden probe path.

- [ ] **Step 9: Rebuild after removal.** `cd client && flutter test && flutter build ios --no-codesign`.

- [ ] **Step 10: Record evidence and narrow the later contract.** Update the spec capability table/open questions and decision log. If the Mixtape-created playlist is editable and the Music-created playlist is rejected, lock the planned rebuild/revised-copy model. If results differ, update the capability matrix honestly before Phase 2 planning.

- [ ] **Step 11: Commit documentation only.** Commit headline: `docs: Record playlist capability probe`.

**Gate:** Phase 2 playlist sync/edit planning begins only after this evidence is recorded. Phase 1 artwork may continue independently once Task 3 passes.

---

## Phase 1 — artwork metadata

### Task 5: Add the artwork schema and pure normalization contract

**Files:**
- Modify: `server/src/db/schema.ts`
- Create: next generated Drizzle migration under `server/drizzle/`
- Modify: `server/test/db.test.ts`
- Create: `server/src/artwork/normalize.ts`
- Create: `server/test/artwork/normalize.test.ts`

- [ ] **Step 1: Write failing normalization tests.** Cover:
  - valid `{w}`/`{h}` HTTPS Apple URL;
  - valid concrete HTTPS Apple URL;
  - lowercase normalization of `A1B2C3`;
  - null colour;
  - rejection of `#a1b2c3`, whitespace, invalid length/characters;
  - zero/negative dimensions become null or validation failure according to one pinned rule;
  - URL maximum length and Apple CDN host validation.

- [ ] **Step 2: Write failing database tests.** Insert a track with full artwork, read it back, and assert:
  - URL, dimensions, colour, and fetched timestamp survive;
  - invalid colour fails the database check;
  - non-positive dimensions fail the database check;
  - all fields remain nullable for existing tracks.

- [ ] **Step 3: Run red tests.** `cd server && npx vitest run test/artwork/normalize.test.ts test/db.test.ts`.

- [ ] **Step 4: Add nullable columns to `tracks`.** Drizzle names:

  ```text
  artworkUrlTemplate
  artworkWidth
  artworkHeight
  artworkBgColor
  artworkFetchedAt
  ```

  Add database checks for lower-case six-digit hex and positive dimensions when non-null.

- [ ] **Step 5: Implement the pure normalizer.** The catalog client and persistence path share this one parser; do not duplicate colour/URL rules.

- [ ] **Step 6: Generate and inspect the migration.** Use `npm run db:generate`; never hand-invent the migration filename. Confirm it is expand-only—nullable columns and checks, no rewrites/drops. Ensure `server/test/helpers/db.ts` loads it cleanly through the template database.

- [ ] **Step 7: Run focused and full checks.** `cd server && npx vitest run test/artwork/normalize.test.ts test/db.test.ts && npm run typecheck`, then `npx vitest run --no-file-parallelism`.

- [ ] **Step 8: Adversarial review.** Check null compatibility, migration rollback expectations, URL/colour validation parity, and no album table/image blob.

- [ ] **Step 9: Commit.** Commit headline: `feat(server): Track artwork metadata`.

### Task 6: Add the independent artwork runner, status, and admin route

**Files:**
- Create: `server/src/artwork/runner.ts`
- Create: `server/test/artwork/runner.test.ts`
- Modify: `server/src/db/schema.ts`
- Create: next generated Drizzle migration if failure state uses a table
- Modify: `server/src/routes/enrich.ts`
- Modify: `server/src/enrich/scheduled.ts`
- Modify: `server/src/index.ts`
- Modify: related route/scheduled tests

- [ ] **Step 1: Write failing runner tests.** Seed tracks and a fake catalog client. Assert:
  - only tracks with `apple_id` and missing/refreshable artwork are selected;
  - selection order is deterministic;
  - at most 300 IDs reach one Apple request;
  - successful hits update metadata monotonically;
  - a later null artwork does not erase known data;
  - an unrequested/unknown response ID is ignored;
  - no-match, rate-limit, upstream, timeout, and malformed outcomes record separate fixed categories;
  - artwork failure never writes `enrichment_failures` or changes feature/meaning attempt counts;
  - retries respect `next_attempt_at`;
  - a batch continues safely when some IDs fail/miss.

- [ ] **Step 2: Design independent failure state.** Preferred table:

  ```text
  track_artwork_status
    track_id uuid primary key
    attempts integer not null
    last_category text not null
    next_attempt_at timestamptz not null
    updated_at timestamptz not null
  ```

  Delete/reset the status row on success. Pin retry windows in named constants. No-match receives a long refresh window; 429/5xx receive bounded shorter backoff. Do not permanently exhaust artwork.

- [ ] **Step 3: Run red tests.** Focused runner and route tests must fail before implementation.

- [ ] **Step 4: Implement one-query candidate selection and one batched Apple call.** Normalize raw DB driver result shapes as the existing enrichment runner does. Use the configured storefront (`ITUNES_STOREFRONT`, default `ng`) for Phase 1 and name the dependency `storefront` so Phase 2 can replace it with per-user grouping.

- [ ] **Step 5: Add admin endpoints under the existing `/enrich/*` guard.** Proposed contract:

  ```text
  POST /enrich/artwork/run?limit=300
    -> { processed, matched, missing, failed, remaining }

  GET /enrich/artwork/status
    -> { tracks, withArtwork, missingArtwork, retryable }
  ```

  Clamp/floor `limit`; never accept more than 300. Responses contain counts only.

- [ ] **Step 6: Add steady-state cron work.** Extend scheduled handling so feature/meaning and artwork runs are independently bounded and one failure does not suppress the other. Respect Cloudflare subrequest limits. One artwork batch costs one Apple fetch plus database work, so keep it separate from the per-track feature batch.

- [ ] **Step 7: Wire dependencies only when MusicKit secrets are complete.** Partial config fails fast. Missing config skips artwork work and leaves existing enrich/session routes healthy. Do not couple browser allowlisted origins to server catalog availability.

  Refactor the current enrich wiring deliberately: `/enrich/*` is presently mounted only when both `ENRICH_ADMIN_TOKEN` and Workers AI are available. Change the wiring so the admin group mounts when the admin token exists and at least one sub-pipeline is configured. Feature/meaning handlers require their existing `EnrichDeps`; artwork handlers require catalog deps; neither optional dependency may disable the other. Apply the same separation to scheduled handling.

- [ ] **Step 8: Run focused tests, full suite, and typecheck.** Authoritative: `cd server && npx vitest run --no-file-parallelism && npm run typecheck`.

- [ ] **Step 9: Adversarial review.** Inspect retry amplification, cron overlap, partial results, free-plan subrequests, secret/log leakage, and status math.

- [ ] **Step 10: Commit schema/runner/route together only after review.** Commit headline: `feat(server): Artwork enrichment runner`.

### Task 7: Expose artwork through existing mix contracts

**Files:**
- Modify: `server/src/dj/queue-store.ts`
- Modify: server queue/session tests
- Modify: `client/lib/data/dj/dj_models.dart`
- Modify: Flutter model/API/provider/widget fixtures and tests that construct `QueueTrack`
- Modify after the concurrent web task is complete: `web/src/api/client.ts`, `web/src/api/mappers.ts`, `web/src/domain.ts`, fixtures/tests

- [ ] **Step 1: Write failing server contract tests.** A queue response for a track with artwork includes:

  ```json
  {
    "artworkUrl": "https://.../{w}x{h}...",
    "artworkWidth": 3000,
    "artworkHeight": 3000,
    "artworkBgColor": "1a2b3c"
  }
  ```

  A track without artwork returns explicit nulls or consistently omitted nullable keys—choose one contract and pin it across all clients. Recommended: explicit nulls.

- [ ] **Step 2: Extend `QueueTrackView` and its select.** Map database names to API camelCase. Do not make artwork required for queue generation, playback, playlist creation, or existing session history.

- [ ] **Step 3: Run focused server tests and typecheck.** Fix every fixture intentionally rather than hiding drift with broad casts.

- [ ] **Step 4: Write failing Dart parser tests.** Full artwork, all-null artwork, and malformed optional types must follow existing defensive parsing conventions. Add optional fields to `QueueTrack`; no artwork widget in this task.

- [ ] **Step 5: Update Flutter fixtures and run `flutter test`.** Playback and playlist creation tests must remain unchanged in behavior.

- [ ] **Step 6: Update web API/domain/mappers only after the web owner has committed.** Artwork remains optional and no visual redesign ships here. Run the web test/typecheck/build commands defined in `web/package.json`.

- [ ] **Step 7: Run cross-surface checks.** Server authoritative suite, Flutter suite, web tests/typecheck/build, and `flutter build ios --no-codesign`.

- [ ] **Step 8: Adversarial review.** Confirm old rows/sessions parse, nulls do not crash, URLs are not interpolated unsafely, and no UI claims covers are displayed yet.

- [ ] **Step 9: Commit only contract/model changes.** Commit headline: `feat: Expose track artwork`.

### Task 8: Apply migration, deploy safely, and backfill founder artwork

**Files:**
- Create if useful: `server/scripts/backfill-artwork.sh` following existing script safety rules
- Modify: `docs/decisions.md`
- Modify: `docs/backlog.md`
- Modify: relevant README/status docs

- [ ] **Step 1: Build a safe backfill operator loop.** It calls the authenticated admin artwork-run endpoint, prints counts only, stops on non-2xx, backs off on 429/5xx, and never prints response bodies or tokens. Dry-run/status is the default; require `--apply` for writes. Load `.dev.vars` with surrounding-quote stripping. Use fixed error strings.

- [ ] **Step 2: Run all local gates at committed HEAD.** Required:
  - `cd server && npx vitest run --no-file-parallelism && npm run typecheck`
  - `cd client && flutter test && flutter build ios --no-codesign`
  - web tests/typecheck/build if Task 7 touched web
  - `git diff --check`

- [ ] **Step 3: Create a clean deployment worktree from the exact reviewed commit.** Verify `git status --short` is empty inside it. The shared working tree is never the deployment source.

- [ ] **Step 4: Ask for action-time approval** before each external write group: production migration, Worker deploy, and production artwork backfill.

- [ ] **Step 5: Apply the expand-only migration from the clean worktree.** Verify schema columns/checks and do not begin backfill if migration status is uncertain.

- [ ] **Step 6: Deploy the Worker from the same clean committed worktree.** Verify `/health`, existing auth/session surfaces, `/enrich/artwork/status`, and no missing-secret startup failure.

- [ ] **Step 7: Run status/dry-run.** Record total tracks and missing artwork count. Do not claim coverage from expected arithmetic.

- [ ] **Step 8: Run `--apply` in batches of at most 300.** Approximately 16 Apple requests cover the current ~4,689 tracks if every ID is eligible, but the script follows returned `remaining`, not a hardcoded iteration count.

- [ ] **Step 9: Verify coverage and data quality.** Query counts only first, then inspect a tiny founder-approved sample in the app/API:
  - URL is HTTPS and renderable after size substitution;
  - width/height are positive when present;
  - background colour is six-digit lowercase hex;
  - missing artwork remains null without breaking mixes;
  - no feature/meaning coverage regressed.

- [ ] **Step 10: Record outcomes.** Update decisions/backlog with exact coverage, no-match/error counts, wall time, and any reopen clause. Never record private track metadata in logs/docs unless the founder explicitly approves a tiny named sample.

- [ ] **Step 11: Remove the clean deployment worktree only after confirming no unique changes exist there.** Use the normal non-destructive git worktree removal flow; do not delete broad paths.

- [ ] **Step 12: Commit operator/docs changes.** Commit headline: `docs: Record artwork backfill`.

---

## Phase 0–1 exit gates

- iOS 16 is declared consistently and the client builds.
- Browser MusicKit token behavior remains test-pinned.
- Server catalog tokens omit `origin` and are never exposed.
- Apple catalog artwork succeeds from Cloudflare's runtime for the Nigerian storefront.
- Real-device evidence records whether current Mixtape-created playlists support exact rebuild and whether Music-created playlists reject it.
- Track artwork schema is nullable, validated, and independently retryable.
- Existing mix APIs and client models expose optional artwork without changing playback or curation.
- Production backfill coverage and failures are measured, not estimated.
- Full server, Flutter, web-if-touched, and iOS no-codesign build gates pass.
- No probe-only code, token, playlist name, or Apple response body remains in git or logs.

## Explicitly deferred to later plans

- Phase 2: per-user storefront persistence, staged playlist snapshot tables, native playlist paging, browse APIs.
- Phase 3: playlist taste score and named-playlist seed profiles.
- Phase 4: playlist-context DJ sessions, catalog search, bounded on-demand enrichment, drafts/diffs.
- Phase 5: exact rebuild/append/revised-copy apply, state-board-approved Flutter UI, full device smoke.

Do not start those plans until Task 4 has updated the capability matrix with device evidence.
