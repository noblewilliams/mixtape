# Native design program — evidence, 2026-09-18

Plan: `superpowers/plans/2026-09-17-native-design-implementation.md`. All phases
1–8 are on `main` (`native-design-baseline` … `928b62d`), each task implemented
test-first by an Opus agent, reviewed by a second Opus agent, fixed, and committed
once; Fable orchestrated and verified.

## Gates on committed HEAD

| Check | Result |
| --- | --- |
| `flutter analyze` (client) | no issues |
| `flutter test` (client) | 1,276 passed, 0 failed |
| `npm test` (server) | 1,396 passed, 1 skipped |
| `npm run typecheck` (server) | clean |
| `flutter build ios --simulator --debug` | built (Xcode 26.5) |
| iOS 26.5 and 18.2 simulators | boot to sign-in on the gradient; no dock before the shell |

## Not done here

- No TestFlight or device build: signing is the founder's.
- Server not deployed: the insert queue op and `POST /transcribe` are on `main`
  only; `wrangler secret put GROQ_API_KEY` is required before transcription works
  (the route answers 503 `transcription_not_configured` until then).
- Signed-in flows were verified by widget tests only; Fable cannot sign in.

## Founder smoke (one pass)

Run on an iOS 26 device (genuine glass) and the iOS 18.2 simulator (fallback):

```bash
cd client && flutter run --dart-define-from-file=config/google-ios.json --dart-define=API_BASE_URL=https://mixtape-api.goalympics.workers.dev
```

1. Sign in with Apple or Google. Production (Worker version `2ef544fd`, deployed
   2026-09-18) accepts the iOS Google client id as audience; the earlier failure
   is diagnosed in `native-google-setup.md`. Without `API_BASE_URL` the app
   talks to localhost and every sign-in fails after the provider returns.
   The restyled sign-in itself: handwritten wordmark, cassette hubs turning
   (still under Reduce Motion), black Apple and white Google pills, everything
   in one screenful on an SE-size phone.
2. Home: empty space, bottom panel, three pills, mic; speak an idea (needs the
   server secret) and see it land in the field.
3. Start a mix; the conversation opens with the dock hidden; Back restores it.
4. Arrangement: reorder, remove, Undo; Play now; the mini-player appears.
5. Now Playing from the mini-player: scrub, transport, Up next, Send to Music.
6. Mixes, Library, You: each tab, then a pushed screen and its back cluster.
7. Dark mode, 200% text, Reduce Motion, Reduce Transparency.
8. On iOS 26 only: judge the tab bar's 22 pt side inset against the mini-player.

Departures from the approved boards are listed under "Implementation
departures" in each `mockups/approved/2026-09-17-*.md` record; open items are in
`backlog.md` under "Native design program follow-ups".
