# Profile name — plan

**Status:** spec `../specs/2026-11-02-profile-name-design.md`, board approved
2026-11-02 (`../../mockups/approved/2026-11-02-profile-name.md`), decision
`../../decisions.md` → 2026-11-02 profile name. Each task: red-first tests,
implementation, a reviewer pass and one fix round. Work happens on branch
`profile-name` in its own worktree (the main checkout holds unrelated
uncommitted release work).

## Contract

- **Name rule (server, one place):** trim, collapse inner whitespace, drop
  control and format characters, cap at 40 characters (by code point, never
  splitting a surrogate pair). Applied by Better Auth `databaseHooks.user`
  on create and update. An empty result stores `''`. Anonymous creation keeps
  `Listener`.
- **Usable name:** non-empty after the rule and not `Listener`.
- **Asked flag:** `user.name_prompted_at` (timestamp, nullable), Better Auth
  additional field `namePromptedAt`, `input: true`, so the owner sets it
  through `POST /api/auth/update-user` (`{ namePromptedAt: <now ISO> }`).
  Setting a name through update-user from Account also sends it.
- **`GET /me`** adds `askName: boolean` = signed-in, not anonymous, no usable
  name, and `namePromptedAt` null. Clients never recompute the rule.
- **Writes:** clients call Better Auth `POST /api/auth/update-user` with
  `{ name }` and/or `{ namePromptedAt }` (web through the auth client, iOS
  through `AccountApi` with the bearer token), then refetch `/me`.
- **DJ:** `firstName(user.name)` = first whitespace-separated word of a usable
  name, `sanitizeForPrompt`, at most 20 characters; the mix and album system
  prompts gain one data line ("The listener's first name: X. Use it rarely, at
  most once in a conversation, never as a greeting.") only when present.
- **Migration 0045** adds the nullable column; additive, no backfill.

## Tasks

1. **Server.** Schema column + migration 0045; `namePromptedAt` additional
   field; the name rule as a pure function with tests (spaces, controls,
   emoji/surrogates at the cap, `Listener`, blank); hooks on create and
   update; `askName` on `GET /me`; Apple ID-token sign-in with
   `idToken.user.name` stores the name (route test through the auth handler
   if the harness allows, else a hook-level test); DJ first-name line in mix
   and album prompts with sanitisation tests.
2. **Web, Settings edit.** `Your account` fallback; "Edit name" / "Add name"
   inline edit per the board (14 px field, Save/Cancel, Enter/Escape, 40 cap
   with count from 30, paste cut message, blank clears, failure keeps text +
   Retry, live-region announcements); write through the auth client, refresh
   the session/`/me`. Hidden for anonymous. Add `?ui-preview` states.
3. **Web, name page.** After sign-in, when `/me` reports `askName`, show the
   first-run-grammar page on `bg-sign-in` (no back, no autofocus, 16 px field,
   Continue pill with disabled grammar, foot link Skip, Saving, failure +
   Retry). Continue writes name + flag; Skip writes the flag and moves on even
   if the write fails. Never for anonymous. `?ui-preview` states.
4. **iOS, Apple name.** `AppleAuthGateway.getIdentityToken` also returns
   `givenName`/`familyName`; the sign-in and link bodies carry
   `idToken.user.name.{firstName,lastName}` when present.
5. **iOS, Account edit.** Identity row as the button with trailing "Edit" /
   "Add name"; inline edit per the board (as `mix_name_editor.dart`); writes
   through `AccountApi.updateUser`; invalidates `meProvider` so Account, You
   and the save dialog default update; announcements. Not for anonymous.
6. **iOS, name page.** A first-run-style screen on `bg-sign-in` with a dark
   keyboard, pushed after sign-in (including the Keep this mix path) or at
   launch when `/me` reports `askName`; same write and Skip rules as web.
7. **Docs and checks.** Backlog entry, spec status, web preview screenshots
   against the board (light, dark, 390), iOS widget tests and an unsigned
   simulator build.

## Done (2026-11-02)

All seven tasks done with a review and fix round each: `1ceb8f2`, `6709c69` (server); `f7bf3be`, `510bc1b`, `fd29f91`, `c5c8838`, `8b3b2f3` (web); `9b0632e`, `949c34d`, `b8aa751`, `379d220`, `9d32ae5`, `f6083aa` (iOS). Departures from the contract, all reviewed: the server stamps `namePromptedAt` itself from any truthy value and never clears it; a non-string `name` is a 400; ZWJ and ZWNJ are kept and the cap takes whole graphemes; `link-social` ignores `idToken.user`, so linking sends only the token; both clients release the post-sign-in hold after 3.5 s and settle Skip only after its write succeeds.

**Merge note:** the main checkout holds another session's uncommitted `server/drizzle/0045_ai_consents.sql`. Whichever lands second regenerates its migration as 0046 from the merged schema (fresh journal `when`).

## Founder gates

1. Apply 0045 and deploy the Worker from a clean worktree of the merged
   commit. Check `GET /me` returns `askName`.
2. Web: Netlify publishes `main`; in a private window, sign in with a test
   account that has no name, see the page once, Skip, reload, no page.
3. iOS (with the next TestFlight build): Account edit; and the Apple name on
   a first-ever sign-in (needs an Apple ID that has never used Mixtape, or
   Settings › Apple ID › Sign in with Apple › Mixtape › Stop using first).
