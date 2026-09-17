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
