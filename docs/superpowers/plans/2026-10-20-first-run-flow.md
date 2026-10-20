# Plan: first run, a mix before an account

Date: 2026-10-20. Spec: `../specs/2026-10-20-first-run-flow-design.md`.
Board approval: `../../mockups/approved/2026-10-20-first-run-flow.md`.
Decision: `../../decisions.md` → 2026-10-20 (anonymous listeners, merge
rule, cap).

House cadence: one fresh implementer per task, red tests first, then a
reviewer pass and one fix round. Implementers and reviewers run on Opus. At
most two agents in flight. One commit per task, files staged by explicit
path.

## Standing rules for every task

- **Shared working tree.** Other sessions may hold uncommitted work
  (`docs/mockups/2026-09-25-tape-materials*.html` and the rack assets are
  untracked and not ours). Edit in place. No `git stash`, `checkout`,
  `restore`, `reset`. Stage only the task's files.
- **No production writes, no deploy, no migration apply** unless a step says
  the founder runs it. Deploys come from a clean worktree of committed HEAD.
- **Workers has no NODE_ENV.** Anything gated on "production" is configured
  explicitly and fails fast on a missing env.
- New listener-facing strings contain no em dashes; the guard in
  `server/test/dj/no-em-dash.test.ts` covers new exported strings. Copy comes
  from the spec's Copy section verbatim.
- Never store or display lyric text.
- User-scoped providers on iOS `ref.watch(authProvider)` in `build()`; the
  anonymous-to-account transition is an auth transition and must reset them.
- Docs ride with the change: the spec's status line when a phase lands, and
  `docs/backlog.md`.
- Free plan limits stand (50 subrequests, 10 ms CPU per invocation): the
  retention job is one statement and runs inside the existing maintenance
  invocation.

## Phase 1: server

### Task 1: anonymous users

Files: `server/src/auth/create-auth.ts`, `server/src/db/auth-schema.ts`,
new `server/drizzle/0035_anonymous_users.sql` plus the journal entry,
`server/src/app.ts` (`AuthLike` seam if the plugin changes its shape),
`server/test/auth.test.ts`.

- Add the `anonymous()` plugin from `better-auth/plugins` with
  `emailDomainName: 'anonymous.mixtape.invalid'`, `generateName: () =>
  'Listener'`, and `onLinkAccount` wired to Task 3's function (a no-op stub
  until then). Keep `bearer()`.
- Migration: `user.is_anonymous boolean not null default false`. Generated
  with drizzle-kit, checked by hand, same shape as 0033 and 0034.
- Rate limit: `rateLimit.customRules` for `/sign-in/anonymous`, 5 per hour
  per IP, on top of the existing global rule.
- Tests: `POST /api/auth/sign-in/anonymous` returns a bearer token and a
  user flagged anonymous; `requireSession` accepts it; a second anonymous
  sign-in with that token is refused (the plugin's own error); a sixth
  anonymous sign-in from one IP inside an hour is 429.

### Task 2: the cap

Files: `server/src/routes/sessions.ts`, `server/src/dj/session-store.ts` (or
wherever `createSessionWithPlaylistSeed` counts), `server/test/session.test.ts`.

- In `POST /sessions`, when `c.get('user').isAnonymous`, count `dj_sessions`
  for the user. At 3 or more, return 403 `{ error: 'anonymous_cap', limit: 3 }`
  before any model call. Archived sessions count.
- The limit is one exported constant, `ANONYMOUS_MIX_CAP = 3`.
- Tests: the fourth anonymous session is 403 and no `dj_sessions` row is
  written; an account with thirty sessions is never capped; follow-up
  messages on an anonymous session past the cap still work.

### Task 3: the merge

Files: new `server/src/auth/link-anonymous.ts`, `server/src/auth/create-auth.ts`
(wire the hook), new `server/test/auth/link-anonymous.test.ts`.

- `linkAnonymousRows(db, { anonymousUserId, newUserId })` runs one
  transaction. Decide `mode`: `'all'` when the new user owns no `dj_sessions`,
  `user_music_sources` or `user_tracks`; otherwise `'mixes_only'`.
- `'all'`: `UPDATE ... SET user_id = new WHERE user_id = anon` on every
  user-keyed table listed in the spec ("The merge"), in FK-safe order.
- `'mixes_only'`: only `dj_sessions`, `dj_memories`, `funnel_events`,
  `playback_evidence`. Everything else stays with the anonymous user and goes
  with the plugin's cascade delete.
- Idempotent: a second call with the same ids is a no-op; a missing
  anonymous user returns early with `mode: 'none'`.
- Record the outcome: insert a `funnel_events` row for the new user,
  `account_linked_new` or `account_linked_existing`.
- The sign-in response must carry `merged` to the client. The plugin owns
  the response, so write the mode to a short-lived row or to the new
  session's `session` table via `additionalFields` (`merged_mode text`) and
  expose it on `GET /me`. Pick whichever the reviewer finds simpler; the
  client reads it once and the server clears it.
- Tests: new account gets every row (count per table before and after);
  existing account with a library keeps its library and gains the anonymous
  sessions, memories, evidence and funnel rows; the anonymous library is
  gone after the plugin's delete; retry is a no-op; unique keys never
  collide (`user_tracks`, `user_music_sources`, `user_artist_seeds`,
  `playback_settings`, `suggestion_settings`, the open-run indexes).

### Task 4: retention and funnel events

Files: `server/src/enrich/scheduled.ts`, new `server/src/jobs/anonymous-retention.ts`,
`server/src/seeds/contracts.ts` (`FUNNEL_EVENT_TYPES`),
`server/test/enrich/scheduled.test.ts` (or the nearest), `server/test/seeds/*`.

- `expireAnonymousUsers(db, { idleDays: 30, limit: 200 })`: delete users
  where `is_anonymous` and the newest `session.updated_at` is older than the
  window (or no session at all and `created_at` older). One statement.
  Returns a count, logged as `anonymous_expired` in the maintenance cron
  line, in its own try/catch.
- Add the new funnel event types from the spec to `FUNNEL_EVENT_TYPES`.
- Tests: expires only idle anonymous users; never an account; respects the
  limit; the cron line carries the count.

### Task 4b: funnel rows outlive their anonymous user

Files: `server/src/db/schema.ts`, new migration 0038, `server/test/jobs/anonymous-retention.test.ts`.

Found in the Task 4 review: `funnel_events.user_id` cascades, so the
retention job would erase exactly the non-converters the first-run funnel
(and the `first_mix_refused` reopen clause) needs. Make `user_id` nullable
with `ON DELETE SET NULL`; the merge in Task 3 still repoints rows to the
account. Test: expiring an anonymous user leaves its funnel rows with a null
user id. Deferred on 2026-10-20: another session holds an uncommitted
migration 0038 (album picks), so this takes the next free number once that
lands. Retention only bites after 30 idle days, so Gate 1 does not wait.

### Gate 1: migrations 0035 to 0037 and deploy (founder)

From a clean worktree of committed HEAD: apply 0035 to 0037, deploy the Worker,
confirm `POST /api/auth/sign-in/anonymous` on production returns a token and
`GET /me` on it works. Existing clients are unaffected: nothing calls the
new endpoint yet.

## Phase 2: web

### Task 5: anonymous session plumbing

Files: `web/src/lib/auth-client.ts`, `web/src/lib/session-token.ts`,
`web/src/lib/api.ts` (or where `MixtapeApi` is built), new
`web/src/lib/anonymous-session.ts`, tests beside them.

- Add `anonymousClient()` to the Better Auth React client.
- `ensureSession()`: if there is no session, call `signIn.anonymous()` and
  store the token as a signed-in token is stored today. Called by the
  first-run pages right before the first prompt, seed save or sync start,
  never on load.
- `RootApp` gains a third state: no session renders `FirstRun`; anonymous
  and signed-in render `SignedInApp` with `user.isAnonymous` available.
- The 403 `anonymous_cap` from `POST /sessions` becomes a typed error the
  composer can catch.
- Tests: no network on load; the anonymous sign-in happens once; a cached
  identity still restores as today.

### Task 6: first-run pages

Files: new `web/src/components/first-run/` (`FirstRun.tsx`, `Welcome.tsx`,
`Artists.tsx`, `StepPage.tsx`, `ChooseService.tsx`, `ChooseMethod.tsx`,
`DoingPage.tsx`, `first-run.css`), `web/public/first-run/bg-*.jpg` (copied
from `docs/mockups/2026-10-20-first-run-assets/`), tests beside them.

- Build against the approved board: full-bleed image, scrim, cream text,
  paper pills, outlined tape back button, "STEP n OF 3" and the progress
  line on path B only, the Step 1 line, the 420 px column.
- Routes use history so the browser's back works; document title and the
  focused heading read "Step n of 3, ...".
- `Artists` posts to `/me/artist-seeds` after `ensureSession()`, then sends
  the prompt. `ChooseMethod` and `DoingPage` reuse the existing import,
  sync and request components (`ImportPanel`, `AppleMusicSyncPanel`,
  `SpotifyRequest`) inside the step chrome; no second implementation.
- Remove `ChooseServiceDialog`; Your music's add flow opens the same step
  pages.
- Tests: each page's copy and controls; Continue enables at three artists;
  Skip for now goes to Artists; after a sync with no usable songs the prompt
  page is preceded by Artists.

### Task 7: sheet, cap, You row, merge notice

Files: `web/src/components/Conversation.tsx` (first-mix hook),
new `web/src/components/first-run/KeepSheet.tsx`, `web/src/components/HomeComposer.tsx`,
`web/src/components/AccountDialog.tsx` or the You surface, `web/src/components/AuthGate.tsx`
(headline variant and background), tests beside them.

- Keep this mix sheet after the first mix lands, once per session; its pill
  opens the sign-in page with "Keep your mixes."; Not now dismisses.
- Cap: on 403 `anonymous_cap` the composer keeps the prompt and pushes the
  sign-in page with the cap line; after sign-in the kept prompt is sent.
- Anonymous You surface: the "Sign in to keep your mixes" row, no Sign out.
- Merge notice toast when `merged === 'mixes_only'`, shown once.
- Funnel events from the spec, one-time per anonymous user via `funnel-once`.
- Tests for each, including that the composer panel never renders provider
  buttons.

### Gate 2: Netlify (founder)

Deploy the web from committed HEAD. One run in a private window: Welcome,
artists, mix, sheet, sign in with a fresh test account, rows present. One
run that signs into the existing test account from an anonymous state and
sees the merge notice.

## Phase 3: iOS

### Task 8: anonymous auth plumbing

Files: `client/lib/presentation/providers/auth_provider.dart`,
`client/lib/data/auth/auth_repository.dart`, `client/lib/data/auth/token_store.dart`,
`client/lib/main.dart`, tests under `client/test/presentation/` and
`client/test/data/`.

- `AuthStatus` becomes `unknown`, `noSession`, `session`; the notifier
  exposes `isAnonymous`. `signInAnonymously()` posts to
  `/api/auth/sign-in/anonymous`, stores the bearer token, and does not
  invalidate user-scoped providers (there were none yet).
- The social sign-in request carries the current anonymous bearer token so
  the plugin can link. After link the new token is stored and
  `authProvider` is invalidated exactly as a sign-in is today.
- `main.dart`: `noSession` renders the first-run flow; `session` renders the
  shell. `ServiceGate` is removed; `choose_service_screen.dart` goes.
- Tests: the three-way switch; the sign-in request header; the anonymous
  token survives a cold start.

### Task 9: first-run screens

Files: new `client/lib/presentation/screens/first_run/` (`first_run_flow.dart`,
`welcome_screen.dart`, `artists_screen.dart`, `step_scaffold.dart`,
`choose_service_screen.dart`, `choose_method_screen.dart`,
`doing_screen.dart`), new `client/assets/first_run/bg-*.jpg` at 2x and 3x
with the pubspec entry, widget tests under `client/test/screens/`.

- `StepScaffold`: image, scrim, counter, progress line, outlined tape back
  (reusing `TapeButton`'s radii from `MixtapeMetrics`), cream text theme.
  Semantics label carries the step.
- Reuse `spotify_request_screen.dart` content and `import_sheet.dart` inside
  the step chrome; Library's Add your music pushes the same screens.
- 200 % text scrolls; reduced motion stops the hubs and cross-fades pushes.
- Tests per screen, matching Task 6's list.

### Task 10: sheet, cap, You row, merge notice

Files: `client/lib/presentation/screens/chat_screen.dart` (first-mix hook),
new `client/lib/presentation/widgets/keep_sheet.dart`,
`client/lib/presentation/screens/home_screen.dart` (cap handling),
`client/lib/presentation/screens/tabs/you_*.dart`, `sign_in_screen.dart`
(headline variant and background), tests beside them.

- Same behaviour as Task 7. `MixtapeSheet` for the sheet; `MixtapeFeedback`
  for the merge toast.
- iOS Swift files, if any (none expected): pbxproj target membership.

### Gate 3: TestFlight (founder)

Build from committed HEAD with the documented define file. One fresh-install
run through path A and path B on a device, one cap run, one sign-in into the
existing account.

## Phase 4: close

- Spec status line, `docs/backlog.md`, and a note in the approval record's
  "Implementation departures" if anything moved.
- Watch `first_mix_refused` against `first_mix_made` for a week; that ratio
  decides whether the catalogue-seeded corpus program opens (decision
  2026-10-20, reopen clause).

## What the founder does, in order

1. Gate 1: apply migrations 0035 to 0037 and deploy the Worker from a clean worktree; Task 4b follows with its own migration.
2. Gate 2: deploy the web, run the two private-window checks.
3. Gate 3: TestFlight build and the device checks.
4. Read the refusal ratio after a week.
