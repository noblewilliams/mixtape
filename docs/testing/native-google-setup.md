# Native Google sign-in configuration and acceptance

The Flutter app uses `google_sign_in` 7.2.0. The lockfile currently resolves
`google_sign_in_ios` 6.2.5 for this Flutter toolchain. It acquires an ID token
through the supported SDK and exchanges it at Better Auth's existing
`POST /api/auth/sign-in/social`. Linking uses `POST /api/auth/link-social` with
the current Mixtape bearer; it never replaces that bearer or implicitly merges
matching email addresses.

## Public configuration wired — September 9, 2026

The founder supplied the iOS OAuth client for **com.noble.mixtape**. Its exact
reversed callback scheme is registered in `client/ios/Runner/Info.plist`.
`client/config/google-ios.json` contains the public iOS client ID, the existing
web client ID from the local backend configuration, and the callback build flag.
Production audience acceptance still needs a real sign-in test.

From `client/`, include the configuration when running or building:

```sh
flutter run --dart-define-from-file=config/google-ios.json
flutter build ios --dart-define-from-file=config/google-ios.json
```

Set `API_BASE_URL` separately for the intended backend; without that define the
app uses its existing localhost default. This file contains only public OAuth
identifiers, never the Google client secret. Builds omitting the configuration
remain explicitly unavailable for native Google sign-in. The callback flag is a
build assertion, not runtime verification of Info.plist.

`RealGoogleAuthGateway` calls `initialize(clientId:, serverClientId:)` and
`authenticate()` on the official SDK. It signs out only the SDK's local cached
Google identity before a deliberate chooser; it does not revoke provider consent
or sign out the Mixtape account. It requests no additional data scopes and does
not use lightweight automatic authentication. Provider cancellation is quiet;
configuration and other errors expose fixed messages without SDK diagnostics.

## Local and device acceptance

Local fake-SDK and HTTP tests cover configuration gating, exact audience inputs,
cancellation, blank tokens, duplicate requests and late results after sign-out or
disposal. They do not prove provider configuration or native callback handling.

On an authorized iPhone/build with the real public values configured, verify:

- Existing and new Google sign-in, native cancellation and retry.
- Apple sign-in still works and MusicKit permission remains separate.
- An explicit Apple/Google link retains the current Mixtape user and mixes.
- A provider already linked elsewhere fails without merging accounts.
- Account-not-linked recovery directs the listener to their usual login method.
- Removing the last method is refused; stale-session removal asks for renewed
  authentication and canonical account methods are reloaded after uncertainty.
- Sign-out/disposal during identity or network work cannot restore a session.

No native Android target is supplied by this repository; Android browser support
remains independent from this iOS SDK work. CocoaPods integration and the unsigned iOS simulator build passed on September 8,
2026. Real provider acceptance remains required before shipping.

## Official references

- [Flutter Google Sign-In package](https://pub.dev/packages/google_sign_in)
- [Flutter iOS integration and callback scheme](https://pub.dev/packages/google_sign_in_ios)
- [Google iOS integration](https://developers.google.com/identity/sign-in/ios/start-integrating)

Verified against the current official package documentation and installed SDK
source on 2026-09-08. In this installed Better Auth version, unlink takes
`accountId` equal to the Better Auth account-row ID, not the provider subject.


## Local Apple sign-in diagnostic — September 9

Local Apple sign-in failed because the installed Miniflare outbound interceptor
adds `CF-Worker` to requests. Apple's public `/auth/keys` endpoint returned 403
with that header and 200 without it, reproduced using both Node and a local
Worker. The original Better Auth key fetch/import failed before the workaround
and passed afterwards. This explains a local verification failure; a successful
phone sign-in remains to be confirmed.

A temporary installed-dependency workaround in
`server/node_modules/miniflare/dist/src/workers/core/outbound.worker.js` omits
that header only for `https://appleid.apple.com/auth/keys`. It does not change
Better Auth token verification or production source. Reinstalling dependencies
can remove this workaround. The original interceptor is backed up at
`/tmp/mixtape-miniflare-outbound-before-apple-workaround.js`. Temporary Better Auth
diagnostics were removed. Restart Wrangler after the workaround; Flutter does
not need rebuilding. A durable dev-tooling fix remains before relying on fresh
installs for this local sign-in path.

## Diagnosis 2026-09-18 — "tried signing in with google but it failed"

Checked against the code and the checked-in configuration (task 8.5). **No code
defect was found in `google_auth_gateway.dart`; it is untouched.**

**Free first check, not a failure mode.** A build without
`--dart-define-from-file=config/google-ios.json` compiles Google *off*:
`GoogleAuthConfiguration` reads `String.fromEnvironment` /
`bool.fromEnvironment`, so with no defines `isAvailable` is false. That state
presents as a **greyed Google button with the visible reason** "Google sign-in
is not available in this build." under it (key `google-unavailable`), not as an
attempt that failed. Rule it out in one glance; pinned by
`test/data/google_auth_gateway_test.dart` → "a build with no dart-defines
reports no configuration at all".

Ranked causes of an attempt that *runs and then fails*:

1. **The API was unreachable.** `AppConfig.apiBaseUrl` defaults to
   `http://localhost:8787`. On a device that is the phone itself; on the
   simulator it resolves only while `wrangler dev` runs in `server/`. The native
   Google sheet succeeds, the exchange never lands, and the screen says
   "Sign-in failed. Try again." Most likely cause by a distance.
2. **The token exchange was rejected.** `POST /api/auth/sign-in/social` reached
   the server but Better Auth refused the ID token — a non-2xx becomes the same
   fixed sentence. Read the Worker log for the actual status before guessing.
   Two sub-causes, in order:
   - **Audience.** `server/src/auth/create-auth.ts` used to verify the token
     against `GOOGLE_CLIENT_ID` alone. The client sends
     `GOOGLE_SERVER_CLIENT_ID`, which equals the `GOOGLE_CLIENT_ID` in
     `server/.dev.vars` — but *which* client id the iOS SDK stamps as `aud`
     (server client, or the iOS client with the server client only in `azp`)
     is **not verifiable from this repository**. **Fixed on 2026-09-18**: the
     server now reads an optional `GOOGLE_IOS_CLIENT_ID` and, when it is set
     and non-empty, configures Better Auth's Google provider with
     `clientId: [GOOGLE_CLIENT_ID, GOOGLE_IOS_CLIENT_ID]`. Index 0 stays the
     primary that pairs with the client secret for the web authorization-code
     flow; later entries are accepted as additional ID token audiences only, so
     the exchange is correct either way and the web flow is unchanged. The var
     is a **public identifier, not a secret**: it is declared under `vars` in
     `server/wrangler.jsonc` (kept equal to `GOOGLE_IOS_CLIENT_ID` in
     `client/config/google-ios.json`), so it ships with a normal
     `wrangler deploy` from a clean worktree of committed HEAD — no
     `wrangler secret put`, nothing to add to `server/.dev.vars`. Pinned by
     `server/test/auth.test.ts` (both ids configured, web-only default, empty
     string treated as absent, and the web redirect still using the web id).
   - **A deployed secret that differs.** The Worker's `GOOGLE_CLIENT_ID` secret
     is not in the repo; confirm it is the same web client as
     `config/google-ios.json`'s `GOOGLE_SERVER_CLIENT_ID`.
3. **The native chooser was dismissed, or the simulator has no Google session.**
   `authenticate()` opens Google in `ASWebAuthenticationSession`; a dismissal
   maps to `GoogleSignInCancelled`, which is deliberately quiet — nothing
   happens, which reads as a failure. Not a defect; sign in to Google in the
   simulator's Safari first.

Checked and consistent, so **not** the cause:

- `GOOGLE_IOS_CLIENT_ID` ↔ the reversed scheme in
  `client/ios/Runner/Info.plist` (now pinned by a test).
- `PRODUCT_BUNDLE_IDENTIFIER` is `com.noble.mixtape` in every Runner
  configuration. Not verifiable from the repo: that the Google console's iOS
  client lists that bundle id.
- `GoogleService-Info.plist` is absent and is not needed; the client id goes to
  `initialize` directly.
- `google_sign_in` 7.x initialization. `RealGoogleAuthGateway.getIdentityToken`
  awaits `GoogleSignIn.instance.initialize(clientId:, serverClientId:)` once
  (guarded against a second, differing initialization), checks
  `supportsAuthenticate()`, then calls `authenticate()`.

If the exchange 500s against a **local** server, re-read the September 9 Apple
note above: the Miniflare outbound interceptor adds `CF-Worker` to provider key
fetches, which broke Apple's JWKS endpoint and could break Google's.

### The command to run

```sh
cd client
flutter run --dart-define-from-file=config/google-ios.json \
  --dart-define=API_BASE_URL=https://<the backend origin>
```

Omit `API_BASE_URL` only on the simulator against `wrangler dev` (the default is
`http://localhost:8787`). Without the first define, Google sign-in is off by
construction and the screen says so under the greyed button.
