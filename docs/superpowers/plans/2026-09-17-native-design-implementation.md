# Native design implementation — 2026-09-17

Status: reviewed by the founder on 2026-09-17; answers folded in below. Phase 0 landed
(`native-design-baseline`). Phase 1 landed (c6189df…41c9883); the founder approved the
gallery gate. Phase 2 landed (72a4304…48fd3a8), verified to sign-in on the iOS 26.5 and
18.2 simulators. On 2026-09-17 the founder asked for all remaining phases to complete
before a single smoke (Google sign-in failed for them; see Phase 8.5). Per-phase gates
are therefore replaced by the per-task review loop; Fable verifies on the simulators
where sign-in is not required. Server 5.1 (insert op) and 7.1 (transcription) landed
(7926d77, cfedaa0); Phases 3–8 landed on 2026-09-18 (see the decisions entry of that
date); Phase 9 docs and the founder's single smoke remain. Gallery: `cd client && flutter run
--dart-define=MIXTAPE_GALLERY=true --dart-define-from-file=config/google-ios.json`.

## Goal

Implement the approved native design across the Flutter client, wire the
features the boards assume but the app lacks, and finish the remaining screens
directly in the app (simulator review, not more boards).

Approved inputs, in this order of authority:

1. `docs/mockups/approved/2026-09-17-mobile-shell.md` — four tabs, glass dock,
   titles, gradient, type, prism, controls, Now Playing, conversation frame.
2. `docs/mockups/approved/2026-09-17-mobile-home-states.md`
3. `docs/mockups/approved/2026-09-17-mobile-conversation-states.md`
4. `docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`
5. Earlier interaction approvals (September 8 parity, September 9 features)
   still govern behaviour they cover; the shell record supersedes their shell
   and visual language only.

Boards are the visual specification. Where a board and this plan differ, the
board wins; where implementation cannot match, stop and surface it.

## Working method

- Fable (this session) plans, splits tasks, briefs agents, reviews outcomes
  against the boards, and keeps the docs current.
- Opus agents implement and review. One fresh implementer per task, one
  reviewer pass, one fix round, then a commit. No task starts on top of an
  unreviewed one.
- TDD as the house rule: failing widget or provider test first, then the
  change. Existing screen tests under `client/test/screens/` are updated, not
  deleted; new components get their own tests under
  `client/test/presentation/widgets/`.
- Commits: one-line conventional subject, no attribution trailers. One commit
  per task. Server changes deploy only from a clean worktree of committed HEAD.
- All work lands on `main`; nothing has shipped yet, so there is no release
  branch to protect. The founder reviews each phase in the iOS Simulator and
  on an iOS 26 device before the next phase begins. Design refinements found there are
  logged as follow-up tasks in the phase, not as new boards.

## Known gaps the boards assume

| Gap | Where it bites | Resolution in this plan |
| --- | --- | --- |
| Native Liquid Glass tab bar and mini-player inside a Flutter app | Shell | Phase 2 native dock on the goalympics host pattern; frosted Flutter fallback for iOS 16–25 and Android |
| Remove has no Undo; queue ops are remove/move only | Arrangement | Server insert op plus client Undo (Phase 5) |
| Voice input does not exist | Home, conversation composer | Phase 7 implements it the goalympics way (recorded clip → server Groq Whisper route → on-device fallback); the mic stays hidden until that phase lands |
| Working tree holds ~270 uncommitted files (mix history, energy, player, suggestions) | Everything | Phase 0 lands them first |
| iOS deployment target is 16.0 | Fallback | Keep 16.0; glass path compiled with availability checks |

## Phase 0 — Baseline (1 task)

**0.1 Land the pending local work.** Run the client and server suites on the
current working tree, fix nothing beyond what blocks green, commit in feature
groups matching `docs/testing/2026-09-09-*.md` (mix history, energy journeys,
apple player feedback, routine suggestions, exportify entry), and tag
`native-design-baseline`. Update `docs/handoff.md` with the landed state.
Owner: Opus implementer with server and client test runs; reviewer confirms
commit boundaries match the testing records.

Gate: `flutter test` and the server suite green on committed HEAD.

## Phase 1 — Foundation (5 tasks)

Everything later screens are built from. No screen changes yet except
`main.dart` wiring the theme.

**1.1 Tokens and theme.** `client/lib/presentation/theme/mixtape_theme.dart`:
light and dark colour tokens from the shell board (text, plum, smoke, muted,
hairline, tape, prism stops, ok/warn/err ink, glass), type scale (SF only:
large title 34 heavy, small title 17 semibold, section 20 bold, row 16, body
16, secondary 13, label 10), radii (3 pt tile, 6/10 tape corners, 12/16
composer), spacing and 44 pt target constants. `ThemeExtension` so widgets read
tokens from `Theme.of(context)`. Replace the Material 3 seed in `main.dart`
with a theme that sets these tokens, keeps Material component defaults quiet
(no elevation tints), and uses the system font. Test: golden-free unit test
that light and dark tokens exist and meet 4.5:1 for body and 3:1 for meta.

**1.2 Gradient background and glass materials.** `GradientBackground` widget
(vertical fall plus violet glow and corner tints, per theme; artwork-colour
variant for Now Playing) and `FrostedSurface` (blur + tint + hairline, the
fallback material) with a `reducedTransparency` opaque mode. Test: renders
without overflow at 320 and 768 widths; opaque when the platform reports
reduced transparency.

**1.3 Controls.** `TapeButton` (40 pt, reel, optional playing meter),
`LabelChip` (36 pt, reel hole), `TextAction`, `IdeaPill` (34 pt), `StatusWord`
(coloured word with icon, never a box), and `PrismStripe`. Restyle
`MixPromptInput` into `Composer` with the stripe, focus ring, optional mic
slot (hidden unless `voiceInputEnabled`), and send key. Tests: targets ≥ 44
pt, disabled states, mic hidden by default, existing `mix_prompt_input_test`
updated.

**1.4 Lists and tiles.** `FlushRow` (art, title, subtitle, trailing, inset
hairline), `SquareArt` (3 pt radius, artwork or gradient placeholder),
`CassetteTile` (port of `web/public/tape.svg` geometry as a `CustomPainter`
with five case colours by id hash and an optional turning-hub animation that
stops under reduced motion), `SectionWord`, `InsetGroup` (native grouped
list), `ReasonBand`. Replace `MixHomeRow` and `PlaylistArtwork` internals.
Tests: cassette paints at 22/44/60/150 without exceptions; reduced motion
disables animation; row wraps at 200% text.

**1.5 Large title and collapsing bar.** `LargeTitleScaffold`: large title
with Apple Music's top margin, collapsing on scroll to a small centred title
over a progressive blur (BackdropFilter under a gradient ShaderMask, no
hairline), optional trailing glass cluster, optional segmented control slot.
Test: title state flips at the scroll threshold; blur is opaque under reduced
transparency.

Gate: founder reviews a `Foundation` debug gallery screen in the simulator
(light, dark, 200%). Gallery is debug-only and excluded from release.

## Phase 2 — Shell (4 tasks)

The host follows the pattern the founder already shipped in goalympics
(`client/ios/Runner/NativeTabBar.swift`, `lib/core/services/
native_tab_bar_channel.dart`, `lib/presentation/screens/shell/app_shell.dart`
in that repo): a native `UITabBar` installed in the window above the Flutter
view, never inside it, so Flutter's compositor cannot restack it; a method
channel for `setTab`, `show`, `hide`, `setMinimized`, `isAvailable`; the tab
bar's own iOS 26 glass; minimise driven from Flutter scroll notifications; a
Flutter fallback bar below iOS 26. A `UIGlassEffect` platform view provides
glass for surfaces that live inside Flutter.

**2.1 Native dock.** `client/ios/Runner/ShellDock.swift` (added to the Runner
target in `project.pbxproj`): `UITabBar` with four SF Symbol tabs (Home,
Mixes, Library, You), installed in the window; above it a native mini-player
view in a `UIGlassEffect` container (artwork, title, artist, play/pause,
next), driven from Flutter over `mixtape/shell` with `setMiniPlayer({visible,
title, artist, artworkUrl, playing})` and reporting `miniPlayerTapped`,
`pause`, `next` back; both minimise together on `setMinimized`; `hide`/`show`
for inside-a-mix. Availability gated on iOS 26; below it the Flutter
`FrostedDock` draws the same geometry. `LiquidGlassSurface` platform view for
the collapsing title bar and the Home panel on iOS 26, `FrostedSurface`
otherwise. Tests: Swift contract test for the channel; Dart contract test
mirroring `native_musickit_contract_test.dart`; `FrostedDock` widget test.

**2.2 Flutter shell.** `ShellScreen` with four tab `Navigator`s in an
`IndexedStack`; `selectedTabProvider`; tab taps arrive on the channel; scroll
notifications from the tabs drive `setMinimized`; a pushed route inside a tab
calls `hide`, popping back calls `show`; auth reset still rebuilds the shell.
Move today's Home menu destinations: Your music, sync and Spotify import →
Library; memories, listening, suggestions, account, sign out → You. Tests:
`root_gate_test`, `service_gate_test` updated; new `shell_screen_test`.

**2.3 Mixes tab.** New `MixesScreen` from the session list on Home today:
native segmented control beside the large title, flush rows with 60 pt
cassette tiles, swipe to archive with Undo, long-press menu (Rename, Version
history), first-run empty state. Home no longer lists mixes. Tests: list cases
move from `home_screen_test` to `mixes_screen_test`.

**2.4 Library and You skeletons.** Placeholder tabs that host the existing
Your music, memory, listening, suggestion and account screens unchanged, so
the shell is navigable end to end before Phase 7 restyles them. Tests: tab
routing reaches each existing screen.

Gate: founder smoke on an iOS 26 device (glass) and an iOS 18 simulator
(fallback).

## Phase 3 — Home (3 tasks)

**3.1 Home layout.** Large title, empty open space with the hint line, bottom
panel with drag handle, `Composer`, and up to three `IdeaPill`s (routine
suggestion first when eligible, then starter prompts). Panel rides the
keyboard; dock behind it. Starting state (hubs turning, composer locked),
start failed line, the created-but-failed-turn handoff into the conversation.
Tests: `home_screen_test` rewritten to the new layout; keyboard, starting,
failure cases.

**3.2 Pills and suggestions.** `suggestions_provider` feeds one routine pill;
skeleton only for that slot; context menu (Not today, Why this?, Turn off) on
routine pills; starter prompts fill the field and never send; pills dim while
typing. Tests: `routine_suggestions_test` rewritten for pills.

**3.3 Attachment and Spotify waiting.** Playlist attachment chip with
Replace / Exclude its songs / Detach; picker as a sheet with search, source
labels, too-few state and exclude toggle; Spotify waiting card becomes two
flush rows plus the note. Tests: `home_inspiration_test`, `home_waiting_test`
updated.

Gate: simulator review against the Home board.

## Phase 4 — Conversation (3 tasks)

**4.1 Frame.** Glass back and action clusters, small title with the "Not
personal yet" subtitle, bubbles without the accent bar, bottom panel with
attachments, composer and mix actions in the new controls, tab bar hidden via
the shell. Tests: `chat_screen_test`, `chat_controls_test` updated.

**4.2 Turns.** Tape card on the current-version reply (cassette, count,
duration, version, Open), "Version n" chips replacing "queue updated · vN",
energy line, working indicator with delayed caption, error turn with Resend,
skeleton loading, could-not-open. Tests for each branch.

**4.3 Sheets and menus.** Energy shape as a sheet with the shipped presets,
attachment conflict chips and toast, More menu with archive Undo toast,
Rename alert. Tests: `energy_journey_test` updated; new cases for conflicts.

Gate: simulator review against the conversation board.

## Phase 5 — Arrangement (3 tasks)

**5.1 Server insert op.** `server/src/dj/` queue ops accept
`{type:'insert', position, trackId}` against the expected version, bounded and
validated like remove/move; migration only if the ops log stores op types.
Route tests. Deploy from a clean worktree after review; client tolerates the
op being absent (Undo hidden until the server reports support).

**5.2 Arrangement screen.** Meta line, actions row (Play now, Create playlist,
Send to Music; Spotify variant with Send to a transfer tool and Open in
Spotify rows), numbered flush rows with reason band, reorder with lifted row,
swipe remove with Undo toast using the insert op, unavailable-song row, stale
version refresh toast, empty and could-not-load. Tests: `queue_screen_test`
rewritten; Undo and conflict cases.

**5.3 Create playlist alert and handoff toasts.** Native alert with remembered
author; success, partial and failure copy as shipped. Tests for copy.

Gate: simulator review against the arrangement board.

## Phase 6 — Playback (2 tasks)

**6.1 Now Playing sheet.** Apple Music layout from the shell board: artwork,
title and artist, one-line mix reference with a 22 pt cassette, prism
scrubber, transport, volume, Shape / Up next / Send to Music. Artwork-colour
gradient background. Unavailable-track state. Tests: `playback_screen_test`
rewritten.

**6.2 Mini-player wiring.** Player state to the native mini-player; Play now
from the arrangement starts the app player and flips the button; Send to Music
handoff retained. Device test on iOS 26 and an earlier iOS.

Gate: founder device smoke of playback.

## Phase 7 — Voice (4 tasks)

The goalympics pattern: record a clip, send it to a server route that calls
Groq Whisper, fall back to Apple's on-device recogniser, and land the
transcript in the field for editing. Live word-by-word dictation is a later
option, not part of this phase.

**7.1 Server transcription route.** `server/src/routes/transcribe.ts`:
authenticated `POST /transcribe` with a multipart `audio` field, 1 KB–25 MB
bounds, forwarded to Groq `whisper-large-v3-turbo` with a 15 s timeout;
`GROQ_API_KEY` required at startup (Workers has no NODE_ENV, so the check is
explicit and fails fast). Route tests with a stubbed fetch. Deploy from a
clean worktree after review.

**7.2 Recording and transcription service.** Add `record` to the client;
`client/lib/data/voice/voice_capture_service.dart` records AAC mono to a temp
file with an amplitude stream for the level meter; `transcription_service`
posts the clip, then falls back to a `mixtape/speech` channel backed by
`SFSpeechRecognizer` in `client/ios/Runner/SpeechTranscriber.swift`; clips are
deleted after use; iOS audio session activated over a channel before
recording. `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription` in `Info.plist`. Tests: service state
machine with fakes; contract test for the channel.

**7.3 Composer listening state.** The mic in `Composer` (Home and
conversation) starts capture; the field shows the prism level meter and
"Listening…"; the mic becomes Stop; the transcript lands in the field with the
cursor at the end and never sends by itself. Permission denied and failures
use the composer's error line with the copy from the Home board. Tests:
`mix_prompt_input_test` cases for listening, stop, failure, denied.

**7.4 Flag removal and smoke.** Remove the `voiceInputEnabled` gate; device
smoke on iOS 26 and an earlier iOS; evidence under `docs/testing/`.

Gate: founder device smoke of voice on Home and in a conversation.

## Phase 8 — Remaining screens, in-app (8 tasks, one per screen group)

Restyle with the foundation components; behaviour unchanged from its existing
approval; founder refines in the simulator. Each task updates its screen test.

7.1 Library (sources and playlists) · 7.2 Playlist detail and private edit
draft/review · 7.3 You (inset groups, toggles, Together ghost) · 7.4 What the
DJ knows and Forget · 7.5 Account and sign-in (including diagnosing the founder's failed native Google sign-in: dart-define config, URL scheme, server client id) · 7.6 Choose service, Apple
connection and sync sheet · 7.7 Spotify import guide, import sheet and results
· 7.8 Version history and taste interview.

Gate: full simulator pass through every screen, light and dark, 200% text.

## Phase 9 — Release readiness (2 tasks)

**9.1 Docs.** `docs/decisions.md` entry for the host outcome and any board
departures; `docs/backlog.md` updated (Undo server op, voice flag, Android
fallback font, artwork colour extraction); approval records amended where the
app deliberately departed.

**9.2 TestFlight.** Build from committed HEAD, founder smoke against the
approved records, evidence file under `docs/testing/`.

## Order and parallelism

Phases run in order. Within a phase, tasks on different files can run in
parallel implementer agents (1.1–1.4; 8.x). Phase 2.1 blocks 2.2–2.4. Phase
5.1 and 7.1 (server) can start during Phase 4.

## Founder answers, 2026-09-17

1. Land the pending working tree first: yes.
2. Genuine glass, following the goalympics host: yes.
3. Undo with the server insert op: included.
4. Voice: implemented in this program, the goalympics way (Phase 7).
5. Devices and Xcode 26 available; all work on `main`.
