# Shared mixes — plan

**Status:** direction approved 2026-11-13 (founder: "Yes, write it"). Board
pending (task B0).
- Spec: `../specs/2026-11-13-shared-mixes-design.md`.
- Decision: `../../decisions.md` → 2026-11-13 Shared mixes.

**Cadence:** house style. Each task goes to a fresh implementer agent
(Opus) with red-first tests. Then a reviewer pass and one fix round, then
one commit per task, with files staged by explicit path. At most two agents
in flight.

**Order:**
1. B0 (board) first. No client UI task starts before the founder approves it.
2. Server S1 → S2 → S3 → S4 can start straight away, since they don't depend
   on the board.
3. Clients follow the shared contract below. Web W1 → W2 → W3 and iOS
   C1 → C2 → C3 → C4 run beside each other once S2 is committed (they need
   the real response shape for fakes, not a deployed server).
4. Gates G1–G4 come last.

## Before starting

- **Another session's work.** On 2026-11-13 another session held
  uncommitted changes in `client/lib/presentation/` (chat, home, mixes,
  shell, the prompt input, `dj_providers.dart`) and their tests, plus
  `docs/backlog.md` and `docs/decisions.md` (DJ turn steps).
  - iOS tasks C2–C4 touch `mixes_screen.dart`, `dj_providers.dart` and the
    chat menu. They start only once that work is committed. Otherwise they
    run in a worktree cut from committed HEAD and rebase before commit.
  - Server and web tasks don't overlap it, but still run in a worktree.
  - Never stage another session's hunks.
- **Migration number.** Check `server/drizzle/` for the highest number
  before S1. The plan assumes `0050`.
- **Formatting.** Never run `dart format` on a folder. Format only the files
  the task touched.
- **Team ID and bundle id** for the association file. Read them from
  `client/ios/Runner.xcodeproj/project.pbxproj` (`DEVELOPMENT_TEAM`,
  `PRODUCT_BUNDLE_IDENTIFIER`). Never guess them.

## Shared contract

- **Share URL:** `https://miixtape.netlify.app/m/<token>`. The base comes
  from config on every surface (server `SHARE_BASE_URL`, web `APP_ORIGIN`,
  iOS `AppConfig.shareBaseUrl`), never a literal in feature code.
- **Token:** 22 characters, base62, made with `crypto.getRandomValues`.
  Clients treat it as opaque and accept `[A-Za-z0-9]{22}` when parsing links.
- **`GET /shared/:token` body** (both clients parse it strictly):
  ```
  { token, title, caseColor, sharerName, sharedAt, isOwner,
    sessionId?,            // only when isOwner
    tracks: [{ title, artist, album, durationMs, artwork, appleId, isrc }] }
  ```
  `artwork` is `{ url, width, height, bgColor }` (the Mixes list's shape) or
  null. `appleId` and `isrc` may be null. `sharerName` is the profile's first
  name or null (the sender cleared it later); clients then show "a friend"
  ("From a friend", "Shared by a friend").
- **Errors:**
  - `404 not_found` and `410 revoked` both read "This mix isn't shared
    anymore."
  - On `POST /sessions/:id/share`, `409 name_required` opens the name page,
    and `422 empty_mix` hides Share (the clients hide it anyway when the mix
    has no songs).
- **`GET /sessions/:id`** adds `shared: boolean`.
- **`GET /me/shared-mixes` row:**
  `{ token, title, caseColor, sharerName, savedAt, trackCount, durationMs, artwork }`.
- **Copy** (identical on both clients):
  - share text: `Listen to my mix “<title>” on Mixtape`;
  - row subtitle: `From <name>`;
  - web header: `Shared by <name>`;
  - stop-sharing confirm: `People with the link won't be able to open it.`;
  - copied toast: `Link copied`.

## Board

**B0. State board.** About 2 hours. Use the `ui-state-board` skill and save
it as `docs/mockups/2026-11-13-shared-mixes.html`. It needs these states:
- iOS mix menu with Share / Stop sharing, and the name page reached from
  Share (no Skip);
- iOS `SharedMixScreen`: loaded, unknown platform, revoked;
- iOS Mixes with a "From Ada" row, including its Remove swipe;
- web `/m/<token>` on phone and desktop: loaded, the Play modal, revoked;
- web Mixes row;
- the link preview card (`og:` image and text).

Follow `mobile-design-preferences` and `web-design-preferences` (no serifs,
no boxes, flush lists, compact quiet controls). Founder approval goes in
`docs/mockups/approved/2026-11-13-shared-mixes.md`.

## Server

**S1. Migration 0050: `mix_shares` and `mix_share_saves`.** About 1 hour.
- Files:
  - `server/src/db/schema.ts`: both tables, as in the spec's Data section,
    with comments pointing at the spec.
  - `server/drizzle/0050_*.sql` and the journal entry.
- Tests:
  - a schema test showing the cascades: deleting a session removes its
    shares and their saves, and deleting a user removes their saves;
  - token uniqueness.
- Done when the generated SQL only creates the two tables and the partial
  index, and the typecheck is green.

**S2. Share routes and the public read.** About 3 hours.
- Files:
  - `server/src/shares/store.ts`: the token generator, `createOrReuseShare`,
    `revokeShares`, `readShare` (live track metadata joined from `tracks`
    in snapshot order), `firstName(name)`;
  - `server/src/routes/sessions.ts`: `POST` and `DELETE /:id/share`, and
    `shared` on `GET /:id`;
  - `server/src/routes/shared.ts`: `GET /:token`, `POST` and
    `DELETE /:token/save`;
  - `server/src/middleware/optional-session.ts`: reads the session when the
    request has one, never 401s;
  - `server/src/app.ts`: mount `/shared` with the optional session, outside
    `requireAiConsent`.
- **Rate limit:** use a Workers rate-limit binding on `GET /shared/:token`,
  60 a minute per IP, configured in `wrangler` and injected so tests use a
  fake. If the binding is missing, the route fails fast at boot. It must not
  run unlimited (CLAUDE.md: Workers has no NODE_ENV).
- Tests (route), for:
  - **Creating a share:**
    - share then share again at the same version gives the same token;
    - after a queue op, a new token;
    - `name_required` for an anonymous user with no usable name;
    - `empty_mix`;
    - 404 for album sessions and non-owners.
  - **Reading a share:**
    - the snapshot order holds after the owner reorders;
    - the title is the snapshot's after a rename;
    - only the first name is returned;
    - no reasons, prompt or messages anywhere in the body;
    - `isOwner`/`sessionId` appear only for the owner;
    - 410 after revoke and 404 for an unknown token;
    - the rate-limit fake returns 429.
  - **Saves:**
    - idempotent;
    - the owner's own save writes no row;
    - DELETE removes the save only.
- Done when the server suite and typecheck are green.

**S3. Saved shares list, merge, and the anonymous cap.** About 2 hours.
- Files:
  - `server/src/routes/shared-mixes.ts`: `GET /me/shared-mixes`, with track
    count, duration and the first song's artwork computed from the snapshot,
    active shares only;
  - `server/src/auth/link-anonymous.ts`: move saves to the account inside
    `linkAnonymousRows`, using `ON CONFLICT DO NOTHING`;
  - confirm the anonymous mix cap counts `dj_sessions` only (add a test
    proving saves don't count).
- Tests:
  - the list leaves out revoked shares;
  - the order is newest save first;
  - merge moves saves, de-duplicates them, and leaves no anonymous rows
    behind;
  - account deletion leaves no saves.
- Done when the suite and typecheck are green.

**S4. Link plumbing on the site: association file, rewrite, preview.**
About 2 hours.
- Files:
  - `scripts/build-site.mjs`:
    - write `dist/.well-known/apple-app-site-association` (`applinks`,
      `appIDs: ["<TeamID>.<bundle id>"]`, `components: [{ "/": "/m/*" }]`);
    - add `/m/* /app/index.html 200` before the catch-all;
    - fail the build if either is missing.
  - `netlify.toml`:
    - a `Content-Type: application/json` header for the association file;
    - the edge function declaration for `/m/*`.
  - `netlify/edge-functions/shared-mix-og.ts`: fetch `GET /shared/:token`
    from `VITE_API_URL`; inject the `og:`/`twitter:` tags and
    `<title>`; on any failure, pass the page through untouched.
- Tests:
  - a build-site test checking that the association JSON and the
    `_redirects` order are right;
  - an edge-function unit test with a fake fetch, covering:
    - tags injected and HTML-escaped (a title with `"<>&`);
    - 410 → generic tags;
    - a thrown fetch → unchanged HTML.
- Done when `node scripts/build-site.mjs` produces both files locally.

## Web

**W1. API client and the public `SharedMixPage`.** About 3 hours.
- Files:
  - `web/src/api/client.ts` and `mappers.ts`: `getSharedMix`,
    `saveSharedMix`, `removeSharedMix`, `listSharedMixes`, `shareSession`,
    `stopSharing`;
  - `web/src/lib/shared-route.ts`: parse `/m/<token>` from `location`;
  - `web/src/main.tsx` / `RootApp.tsx`: a shared route renders
    `SharedMixPage` outside `AuthGate`;
  - `web/src/components/SharedMixPage.tsx` and its CSS, from the approved
    board.
  - `test/fake-api.ts`: the new calls.
- **Behaviour:**
  - The page loads with no session.
  - If a session token already exists, it calls `saveSharedMix` once.
  - Get the app uses the existing install/download destination.
  - Make your own mix goes to `/app/`.
  - The owner is sent to their mix at `/app/` (the existing restore path).
- Tests:
  - the loaded, revoked and owner-redirect states;
  - no save without a session, and one save with one;
  - nothing sends a request that needs AI consent.

**W2. Play on the shared page.** About 2 hours.
- Files: `SharedMixPage.tsx`, plus a small `SharedPlayModal` that reuses
  QueuePanel's "Where do you listen?" pieces (extract them; don't copy them).
- **Behaviour:**
  - `plays-on` answered: no modal.
  - **Apple:** `ensureSession` → MusicKit authorize → the playback
    controller plays the tracks that have Apple ids, in order.
  - **Spotify:** the existing TuneMyMusic handoff, explainer included.
  - The answer is written to `plays-on`.
  - Once `ensureSession` has made a session, the share is saved.
- Tests:
  - the modal appears only when `plays-on` is unset;
  - the Apple path calls `ensureSession` before the token;
  - songs without Apple ids are skipped;
  - the Spotify path opens the handoff with the share's songs.

**W3. Share in the web app, and shared rows in Mixes.** About 3 hours.
- Files:
  - `TapeActions.tsx` (Share / Stop sharing);
  - the name page reached from Share with no Skip, reusing the
    `name-page.ts` logic;
  - Mixes (`TapeRack.tsx` / `MixHistory` list): merge `listSharedMixes`
    rows, labelled `From <name>`, opening a read-only view (the
    `SharedMixPage` body inside the shell) with Remove.
- **Sharing:** `navigator.share` when it exists, otherwise copy the link and
  show the `Link copied` toast.
- Tests:
  - share → name page on `name_required` → share completes;
  - the stop-sharing confirm;
  - shared rows sort by `savedAt` among sessions;
  - Remove calls `removeSharedMix`;
  - albums have no Share.

## iOS

**C1. Data layer.** About 2 hours.
- Files:
  - `client/lib/data/dj/dj_api.dart` and `dj_models.dart`: `SharedMix`,
    `SharedMixRow`, the six calls, and `shared` on session detail;
  - `client/lib/data/config/`: `shareBaseUrl`;
  - `client/lib/data/share/share_link.dart`: build a share URL and parse a
    token from a URL.
- Tests: model parsing (strict, missing keys fail), token parsing
  (accepts the share host only, any trailing slash or query), and the error
  mapping for 404/410/409/422.

**C2. Universal links.** About 2 hours.
- Files:
  - `pubspec.yaml`: add `app_links`;
  - `client/ios/Runner/Runner.entitlements`: add
    `com.apple.developer.associated-domains` =
    `applinks:miixtape.netlify.app`. The entitlements file is already in the
    target; check `CODE_SIGN_ENTITLEMENTS` covers every configuration;
  - `client/lib/presentation/providers/incoming_link_provider.dart`: listens
    to `app_links` (initial link plus the stream), turns share URLs into a
    `pendingSharedMix` token, and cancels its subscription in
    `ref.onDispose`;
  - `shell_screen.dart` and the first-run root: when a token is pending,
    push `SharedMixScreen` on the root navigator. This works both before and
    after first run.
- Tests: a provider test with a fake link source (cold start, while
  running, non-share URL ignored); a shell widget test showing the push.

**C3. `SharedMixScreen`.** About 3 hours.
- Files: `client/lib/presentation/screens/shared_mix_screen.dart`, built
  from the approved board, reusing the cassette, track rows and
  `mix_handoff.dart` actions.
- **Behaviour:**
  - The platform's fixed actions; an unknown platform opens the existing
    sheet on the first action.
  - Apple Play plays the share's Apple ids through the existing playback
    controller, with the one-platform-play fallbacks.
  - Saves once if a session exists. Otherwise the token stays pending and
    is saved once a session appears (watch `authProvider`).
  - The revoked state has Remove.
  - The owner's link opens their own `ChatScreen`.
- Tests: loaded/revoked/owner, no composer or row swipe, save-on-session,
  actions per platform.

**C4. Share, Stop sharing, and shared rows in Mixes.** About 3 hours.
- Files:
  - the mix menu in `chat_screen.dart` and the arrangement bar menu: Share
    (via `share_plus`) and Stop sharing (Cupertino confirm);
  - the name page pushed on `name_required`, with no Skip;
  - `mixes_screen.dart` and `mix_home_row.dart`: shared rows from a
    `sharedMixesProvider`, which must `ref.watch(authProvider)` in `build()`.
    Rows show `From <name>`, swipe to Remove, and tap opens
    `SharedMixScreen`;
  - `debug/mixes_preview.dart`: add a shared row to the fake data.
- Tests: the share flow including `name_required`, the menu shows Stop
  sharing only when `shared`, Mixes merges and sorts, Remove, and an auth
  change resets the provider.

## Gates (founder, at action time)

- **G1.** Apply migration `0050` from a clean worktree of committed HEAD with
  `DATABASE_URL` from `server/.dev.vars` (production Neon), add the
  rate-limit binding, then deploy the Worker from the same worktree. Smoke it
  with curl and a throwaway anonymous user:
  1. share;
  2. `GET /shared/:token` with no auth;
  3. revoke gives 410;
  4. delete the user.
- **G2.** Netlify publishes `main`. Then check:
  - `curl -I https://miixtape.netlify.app/.well-known/apple-app-site-association`
    returns 200 with JSON and no redirect;
  - a `/m/<token>` link pasted into iMessage shows the preview card;
  - a private-window pass: open, Play → Apple Music, and Play → Spotify.
- **G3.** In the Apple Developer portal, turn on Associated Domains for the
  App ID and regenerate the profile. Build on TestFlight, then on a device:
  - a link in Messages opens the app on the mix;
  - it appears in Mixes as "From …";
  - Play works;
  - Stop sharing from the sender makes it disappear on the next refresh.
- **G4.** On a device without the app, the link opens the web page.

## Docs and close-out

- In each task's commit, keep the spec in step if anything moves.
- At the end:
  - add `docs/backlog.md` lines for the known limits (storefront mismatch,
    deferred deep links, custom-domain migration) and for anything left
    open;
  - note in the spec any way the shipped copy differs from the board.
