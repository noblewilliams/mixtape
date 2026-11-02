# Account deletion — plan

**Status:** approved 2026-11-02 (founder: reconfirm with Apple on iOS, one
destructive alert). App Store guideline 5.1.1(v) requires an in-app way to
delete an account that the app lets you create; this is the App Store blocker.

## Decisions

- **Hard delete, one statement.** `DELETE FROM "user"` cascades to every
  user-keyed table (the anonymous-retention job already relies on this);
  `funnel_events.user_id` is `SET NULL`, so counts survive unlinked. A schema
  test pins that every foreign key to `user` is `CASCADE` except that one.
- **Apple tokens are revoked, best effort.** Apple asks apps that offer Sign in
  with Apple to revoke the user's tokens on deletion. Two sources:
  - iOS sends a fresh `authorizationCode` from the native Apple sheet (shown
    once, only when the account has an Apple login). The server exchanges it at
    `https://appleid.apple.com/auth/token` with `client_id` = bundle id and
    revokes the returned refresh token.
  - Otherwise the server revokes the refresh token (else access token) Better
    Auth stored for a web sign-in, with `client_id` = the web Services ID.
  A revoke failure is logged without detail and never blocks the deletion: the
  listener asked for their data to go.
- **Google** is not revoked server-side (no stored grant worth revoking); iOS
  calls the Google SDK's disconnect, best effort.
- **Anonymous listeners** may call the route (it is the same delete), but the
  clients only offer it to accounts; anonymous data still expires after 30 days.
- **Music services are untouched.** Nothing in Apple Music or Spotify is
  removed; the copy says so.

## Contract

`DELETE /me`, session required.

Body: optional JSON `{ "appleAuthorizationCode"?: string }` (non-empty, at
most 2048 characters). No body, or `{}`, is valid.

- `200 { "deleted": true, "apple": "revoked" | "failed" | "not_linked" | "no_token" }`
- `400 { "error": "invalid_request" }` for a malformed body or code
- `401` without a session

After 200 every session of the user is gone (cascade), so the bearer token is
dead; clients clear local state without calling sign-out.

## Copy (both clients)

- Row / button: **Delete account** (destructive colour).
- Alert title: **Delete your account?**
- Alert body: **This permanently deletes your mixes, library, memories and
  listening history from Mixtape. Your Apple Music and Spotify libraries are
  not touched.**
- Actions: **Cancel**, **Delete account** (destructive).
- Failure: **Couldn’t delete your account. Try again.**

## Tasks

1. Server: `DELETE /me`, Apple revoker (injected fetch), schema cascade test,
   wiring in `src/index.ts`.
2. iOS: `AppleAuthGateway.getAuthorizationCode`, `AccountApi.deleteAccount`,
   `AuthNotifier.deleteAccount` (clears local state like sign-out, without the
   server sign-out call), Delete account row + alert on the Account screen.
3. Web: Delete account row in Settings → Account, confirm dialog, API call,
   local sign-out on success.
4. Docs: `decisions.md` entry, backlog, privacy draft mentions deletion.

## Gate (founder)

Deploy the Worker from a clean worktree; on production delete a throwaway
anonymous user, then a throwaway Apple-linked account from an iOS build, and
confirm Settings › Apple ID › Sign in with Apple no longer lists Mixtape.
