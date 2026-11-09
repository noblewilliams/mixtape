// The shared mix handoff (plan task 5.3): the copy the arrangement and the
// conversation both toast, the gating both bars obey, the save alert both
// open, and the fixed per-platform mix actions (one platform,
// `docs/mockups/approved/2026-11-09-one-platform-play.md`). The two screen
// suites still cover how each screen wires these up; this covers the unit
// itself, so a copy change has exactly one place to break.
import 'dart:async';

import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoDialogAction, CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/service_marks.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';
import 'package:mixtape/presentation/widgets/spotify_handoff_sheets.dart'
    show SpotifyHandoffSheet;
import 'package:mixtape/presentation/widgets/tape_header.dart' show TapeBar;
import 'package:mixtape/presentation/widgets/tape_strip.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';

import '../../data/playback/playback_controller_test.dart' as playback
    show FakeApi, FakeBridge;
import '../../screens/queue_screen_test.dart' show FakeBridge, FakeDjApi;

QueueTrack _track(
  int position, {
  String? appleId = 'apple',
  String? spotifyId,
  bool newToYou = false,
}) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: appleId,
  spotifyId: spotifyId,
  title: 'Title $position',
  artist: 'Artist $position',
  durationMs: 180000,
  newToYou: newToYou,
);

/// A screen stand-in: the mixin's host, with the toasts captured instead of
/// shown so a test can read the exact string the shared builders produced.
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.queue, this.defaultName = 'Road Trip'});

  final List<QueueTrack> queue;
  final String defaultName;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with MixHandoff<_Host> {
  final List<String> snacks = [];

  @override
  String get mixSessionId => 's1';

  @override
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info}) => snacks.add(message);

  @override
  Widget build(BuildContext context) {
    // As both screens do, so the alert can read the account name non-blocking.
    ref.watch(accountNameProvider);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: const Key('open-save'),
              onPressed: () => createPlaylist(
                queue: widget.queue,
                defaultName: widget.defaultName,
                keys: MixHandoffKeys.arrangement,
              ),
              child: const Text('Create playlist'),
            ),
            TextButton(
              key: const Key('host-play-here'),
              onPressed: () => playHere(
                ChatState(
                  session: DjSession(
                    id: 's1',
                    title: 'Road Trip',
                    status: 'active',
                    queueVersion: 2,
                    updatedAt: DateTime(2026, 1, 1),
                  ),
                  messages: const [],
                  queue: widget.queue,
                ),
                widget.queue,
              ),
              child: const Text('Play here'),
            ),
          ],
        ),
      ),
    );
  }
}

ProviderContainer _container({
  FakeDjApi? api,
  FakeBridge? bridge,
  AuthorStore? authorStore,
  String? accountName,
  PlaybackController? player,
}) => ProviderContainer(
  overrides: [
    if (player != null) playbackProvider.overrideWithValue(player),
    djApiProvider.overrideWithValue(api ?? FakeDjApi()),
    musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
    authorStoreProvider.overrideWithValue(authorStore ?? InMemoryAuthorStore()),
    accountNameProvider.overrideWith((ref) async => accountName),
  ],
);

Future<_HostState> _pumpHost(
  WidgetTester tester,
  ProviderContainer container, {
  required List<QueueTrack> queue,
  String defaultName = 'Road Trip',
}) async {
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: _Host(queue: queue, defaultName: defaultName)),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

/// What the mix actions asked for.
class _Tapped {
  int plays = 0;
  int nowPlaying = 0;
  int playlists = 0;
  int spotifyPlaylists = 0;
  late ProviderContainer container;
}

/// The mix actions on their own: the design tokens they read off the theme,
/// the player they listen to for the Playing state, and the device's
/// platform.
Future<_Tapped> _pumpActions(
  WidgetTester tester, {
  required List<QueueTrack> queue,
  bool enabled = true,
  bool playing = false,
  MixHandoffKeys keys = MixHandoffKeys.arrangement,
  MusicPlatform? platform,
  double textScale = 1,
  double width = 390,
  bool onTape = false,
  bool sendingToMusic = false,
  PlaybackController? player,
}) async {
  final tapped = _Tapped();
  final container = ProviderContainer(
    overrides: [
      playbackProvider.overrideWithValue(
        player ?? PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
      musicPlatformStoreProvider.overrideWithValue(
        InMemoryMusicPlatformStore(platform),
      ),
      onboardingProvider.overrideWith(() => _Onboarding(null)),
    ],
  );
  addTearDown(container.dispose);
  tapped.container = container;
  final actions = MixActions(
    keys: keys,
    queue: queue,
    enabled: enabled,
    isPlayingThisMix: () => playing,
    onPlay: () => tapped.plays++,
    onOpenNowPlaying: () => tapped.nowPlaying++,
    onCreatePlaylist: () => tapped.playlists++,
    onCreateSpotifyPlaylist: () => tapped.spotifyPlaylists++,
    sendingToMusic: sendingToMusic,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MixtapeTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: width,
                child: onTape
                    ? TapeBar(primary: actions)
                    : TapeStrip(
                        title: 'Smooth Cruise Through Lagos',
                        version: 1,
                        songs: queue.length,
                        caseColor: const Color(0xFF617F9C),
                        onOpen: () {},
                        actions: actions,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tapped;
}

/// An app player whose start fails only once a test lets it.
class _LateFailBridge extends playback.FakeBridge {
  final gate = Completer<void>();

  @override
  Future<void> start(List<String> ids) async {
    starts++;
    await gate.future;
    throw PlatformException(code: 'playback_failed');
  }
}

class _Onboarding extends OnboardingNotifier {
  _Onboarding(this.service);
  final String? service;

  @override
  Future<OnboardingState> build() async => OnboardingState(
    userId: 'u1',
    sources: const [],
    hasLibrary: true,
    chosenService: service,
    markedRequestedAt: null,
    interviewCompletedAt: null,
    importCompletedAt: null,
  );
}

void main() {
  group('handoff copy', () {
    test('a clean play names Apple Music and nothing else', () {
      expect(mixPlaySuccessMessage(0), 'Playing in Apple Music');
    });

    test('skipped songs are counted, and singular at one', () {
      expect(
        mixPlaySuccessMessage(1),
        'Playing in Apple Music · 1 song skipped (not in Apple Music)',
      );
      expect(
        mixPlaySuccessMessage(3),
        'Playing in Apple Music · 3 songs skipped (not in Apple Music)',
      );
    });

    test("a refused play carries Apple's own reason", () {
      expect(
        mixPlayFailureMessage('not authorized'),
        "Couldn't play — not authorized",
      );
    });

    test('a save reports what landed, and the failures only when there are any', () {
      expect(mixSaveSuccessMessage(12, 0), 'Saved 12 songs to Apple Music');
      expect(
        mixSaveSuccessMessage(10, 2),
        'Saved 10 songs to Apple Music (2 failed)',
      );
    });

    test("a refused save carries Apple's own reason", () {
      expect(
        mixSaveFailureMessage('not authorized'),
        "Couldn't save the playlist — not authorized",
      );
    });

    test('a copy counts the songs and says where to paste them', () {
      expect(
        mixSpotifyCopiedMessage(1),
        'Copied 1 song · paste it in, then rename “My Playlist”',
      );
      expect(
        mixSpotifyCopiedMessage(9),
        'Copied 9 songs · paste them in, then rename “My Playlist”',
      );
    });

    test('the Spotify explainer says how to name the playlist in TuneMyMusic', () {
      expect(
        SpotifyHandoffSheet.lineFor(1),
        'We’ll copy the song and open TuneMyMusic. Paste it in, tap '
        '“My Playlist” to give it this mix’s name, then connect Spotify. '
        'TuneMyMusic adds its own note to the description; you can edit it '
        'in Spotify.',
      );
      expect(
        SpotifyHandoffSheet.lineFor(3),
        'We’ll copy your 3 songs and open TuneMyMusic. Paste them in, tap '
        '“My Playlist” to give it this mix’s name, then connect Spotify. '
        'TuneMyMusic adds its own note to the description; you can edit it '
        'in Spotify.',
      );
    });

    test('the Spotify Create playlist opens the paste-a-list page that makes a Spotify playlist', () {
      expect(
        mixTransferToolUrl.toString(),
        'https://www.tunemymusic.com/transfer/freetext-to-spotify',
      );
    });

    test('the copied list is one "Artist - Title" line per song, every song', () {
      expect(
        mixTransferText([_track(0), _track(1, appleId: null)]),
        'Artist 0 - Title 0\nArtist 1 - Title 1',
      );
    });
  });

  group('gating', () {
    test('a mix with Apple matches refuses nothing', () {
      expect(mixActionsDisabledReason([_track(0), _track(1)]), isNull);
    });

    test('a partial match still plays: the skip count says the rest', () {
      expect(
        mixActionsDisabledReason([_track(0), _track(1, appleId: null)]),
        isNull,
      );
    });

    test('a mix Apple Music cannot match at all says so', () {
      expect(
        mixActionsDisabledReason([_track(0, appleId: null)]),
        "these tracks aren't in Apple Music",
      );
    });

    test('an arrangement that does not exist yet needs no reason', () {
      expect(mixActionsDisabledReason(const []), isNull);
    });
  });

  group('Spotify rows', () {
    test('a track with no Spotify id opens a Spotify search for it', () {
      expect(
        mixSpotifySearch(_track(0)).toString(),
        'https://open.spotify.com/search/Artist%200%20Title%200',
      );
    });
  });

  group('the save alert', () {
    testWidgets('prefills the mix title and the remembered author', (tester) async {
      final host = await _pumpHost(
        tester,
        _container(authorStore: InMemoryAuthorStore('Noble'), accountName: 'Ada'),
        queue: [_track(0)],
        defaultName: 'Late drive',
      );
      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<CupertinoTextField>(find.byKey(MixHandoffKeys.arrangement.nameField))
            .controller!
            .text,
        'Late drive',
      );
      expect(
        tester
            .widget<CupertinoTextField>(find.byKey(MixHandoffKeys.arrangement.authorField))
            .controller!
            .text,
        'Noble',
        reason: 'the name typed on this device beats the account name',
      );
      expect(host.snacks, isEmpty);
    });

    testWidgets('an author typed here rides the save and is remembered', (
      tester,
    ) async {
      final store = InMemoryAuthorStore();
      final bridge = FakeBridge();
      final host = await _pumpHost(
        tester,
        _container(bridge: bridge, authorStore: store),
        queue: [_track(0), _track(1)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(MixHandoffKeys.arrangement.authorField),
        '  Noble  ',
      );
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.author, 'Noble');
      expect(bridge.createCalls.single.ids, ['apple', 'apple']);
      expect(await store.read(), 'Noble');
      expect(host.snacks, ['Saved 2 songs to Apple Music']);
    });

    testWidgets('no author at all falls back to the app name and stores nothing', (
      tester,
    ) async {
      final store = InMemoryAuthorStore();
      final bridge = FakeBridge();
      await _pumpHost(
        tester,
        _container(bridge: bridge, authorStore: store),
        queue: [_track(0)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.author, 'mixtape');
      expect(await store.read(), isNull);
    });

    testWidgets('a whitespace-only name cannot create a playlist', (tester) async {
      final bridge = FakeBridge();
      await _pumpHost(
        tester,
        _container(bridge: bridge),
        queue: [_track(0)],
        defaultName: 'Late drive',
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(MixHandoffKeys.arrangement.nameField),
        '   ',
      );
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls, isEmpty);
    });

    testWidgets('a second Save tap while the first is in flight creates nothing new', (
      tester,
    ) async {
      final completer = Completer<({int added, int failed})>();
      final bridge = FakeBridge()..onCreatePlaylist = (_, _) => completer.future;
      await _pumpHost(tester, _container(bridge: bridge), queue: [_track(0)]);

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pump();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pump();

      expect(bridge.createCalls, hasLength(1));
      completer.complete((added: 1, failed: 0));
      await tester.pumpAndSettle();
    });

    testWidgets('a refused save retains the draft and reports the reason inline', (
      tester,
    ) async {
      final bridge = FakeBridge()
        ..onCreatePlaylist = (_, _) async => throw MusicKitException('not authorized');
      final host = await _pumpHost(
        tester,
        _container(bridge: bridge),
        queue: [_track(0)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(find.byKey(MixHandoffKeys.arrangement.nameField), findsOneWidget);
      expect(host.snacks, isEmpty);
      expect(find.text("Couldn't save the playlist — not authorized"), findsOneWidget);
    });

    testWidgets('a save that added nothing posts no taste signal', (tester) async {
      final api = FakeDjApi();
      final bridge = FakeBridge()
        ..onCreatePlaylist = (_, _) async => (added: 0, failed: 2);
      final host = await _pumpHost(
        tester,
        _container(api: api, bridge: bridge),
        queue: [_track(0), _track(1)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(api.postedEvents, isEmpty);
      expect(host.snacks, ['Saved 0 songs to Apple Music (2 failed)']);
    });

    testWidgets('a successful save posts exactly one saved_playlist event', (
      tester,
    ) async {
      final api = FakeDjApi();
      await _pumpHost(tester, _container(api: api), queue: [_track(0)]);

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(api.postedEvents.map((e) => (e.sessionId, e.type)), [
        ('s1', 'saved_playlist'),
      ]);
    });

    testWidgets('an unexpected throw leaves the alert usable rather than stuck', (
      tester,
    ) async {
      // The two known outcomes pop the alert themselves; anything else
      // (an offline store, a programming error) leaves it open, and the
      // listener must still be able to retry or cancel.
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MixSaveDialog(
            keys: MixHandoffKeys.arrangement,
            defaultName: 'Late drive',
            defaultAuthor: '',
            onConfirm: (_, _) async {
              attempts++;
              throw StateError('boom');
            },
          ),
        ),
      );
      final keys = MixHandoffKeys.arrangement;

      await tester.tap(find.byKey(keys.saveConfirm));
      await tester.pumpAndSettle();
      // Reported to the app's error handler rather than lost as an
      // unhandled async error the discarded future would swallow.
      expect(tester.takeException(), isStateError);
      expect(attempts, 1);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(
        tester.widget<CupertinoDialogAction>(find.byKey(keys.saveConfirm)).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<CupertinoTextField>(find.byKey(keys.nameField)).enabled,
        isTrue,
      );
      expect(
        tester
            .widget<CupertinoDialogAction>(
              find.widgetWithText(CupertinoDialogAction, 'Cancel'),
            )
            .onPressed,
        isNotNull,
      );

      // And a retry is possible rather than dead.
      await tester.tap(find.byKey(keys.saveConfirm));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(tester.takeException(), isStateError);
    });

    testWidgets('each screen keeps its own keys and alert title', (tester) async {
      expect(
        MixHandoffKeys.arrangement.saveConfirm,
        isNot(MixHandoffKeys.conversation.saveConfirm),
      );
      expect(MixHandoffKeys.arrangement.saveDialogTitle, 'Save as playlist');
      expect(MixHandoffKeys.conversation.saveDialogTitle, 'Create playlist');

      await _pumpHost(tester, _container(), queue: [_track(0)]);
      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      expect(find.text('Save as playlist'), findsOneWidget);
    });
  });

  group('mix actions', () {
    Finder arrow() => find.byIcon(Icons.keyboard_arrow_down_rounded);

    for (final onTape in [false, true]) {
      final where = onTape ? 'the tape bar' : 'the strip';

      testWidgets('Apple Music on $where: Play and Create playlist, no arrow', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final tapped = await _pumpActions(
          tester,
          queue: [_track(0), _track(1)],
          platform: MusicPlatform.apple,
          onTape: onTape,
        );
        const keys = MixHandoffKeys.arrangement;
        expect(
          tester.widget<TapeButton>(find.byKey(keys.playNow)).label,
          'Play',
        );
        expect(
          tester.widget<LabelChip>(find.byKey(keys.createPlaylist)).label,
          'Create playlist',
        );
        expect(find.byKey(keys.spotifyPlaylist), findsNothing);
        expect(arrow(), findsNothing);
        expect(find.bySemanticsLabel('Choose where to play'), findsNothing);
        expect(find.byKey(MixHandoffKeys.meterKey), findsNothing);

        // Play on the left, Create playlist on the right, sharing the row.
        final play = tester.getRect(find.byKey(keys.playNow));
        final create = tester.getRect(find.byKey(keys.createPlaylist));
        expect(play.right, lessThan(create.left));
        expect(play.width, closeTo(create.width, 1));
        expect(play.height, greaterThanOrEqualTo(44));

        await tester.tap(find.byKey(keys.playNow));
        await tester.tap(find.byKey(keys.createPlaylist));
        expect(tapped.plays, 1);
        expect(tapped.playlists, 1);
        expect(tapped.spotifyPlaylists, 0);
        handle.dispose();
      });

      testWidgets(
        'Spotify on $where: one full-width Create playlist, no Play',
        (tester) async {
          final handle = tester.ensureSemantics();
          final tapped = await _pumpActions(
            tester,
            queue: [_track(0), _track(1, appleId: null)],
            platform: MusicPlatform.spotify,
            onTape: onTape,
          );
          const keys = MixHandoffKeys.arrangement;
          expect(find.byKey(keys.playNow), findsNothing);
          expect(find.byKey(keys.createPlaylist), findsNothing);
          expect(find.text('Play'), findsNothing);
          expect(arrow(), findsNothing);
          final button = find.byKey(keys.spotifyPlaylist);
          expect(tester.widget<TapeButton>(button).label, 'Create playlist');
          expect(
            find.descendant(of: button, matching: find.byType(SpotifyMark)),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel('Create Spotify playlist'),
            findsOneWidget,
          );
          // Full width: the whole row the strip or bar gives it.
          final row = tester.getRect(find.byType(MixActions));
          expect(tester.getRect(button).width, row.width);

          await tester.tap(button);
          expect(tapped.spotifyPlaylists, 1);
          expect(tapped.plays, 0);
          handle.dispose();
        },
      );
    }

    testWidgets('an unknown platform draws the Apple Music pair', (
      tester,
    ) async {
      await _pumpActions(tester, queue: [_track(0)]);
      expect(find.byKey(MixHandoffKeys.arrangement.playNow), findsOneWidget);
      expect(
        find.byKey(MixHandoffKeys.arrangement.createPlaylist),
        findsOneWidget,
      );
    });

    testWidgets(
      'while this mix plays here, Play reads Playing and opens Now Playing',
      (tester) async {
        final handle = tester.ensureSemantics();
        final tapped = await _pumpActions(
          tester,
          queue: [_track(0)],
          playing: true,
        );
        const keys = MixHandoffKeys.arrangement;
        expect(
          tester.widget<TapeButton>(find.byKey(keys.playNow)).label,
          'Playing',
        );
        expect(find.byKey(MixHandoffKeys.meterKey), findsOneWidget);
        expect(
          tester.getSemantics(find.byKey(keys.playNow)),
          matchesSemantics(
            label: 'Playing',
            hint: 'Opens Now Playing',
            isButton: true,
            isEnabled: true,
            hasEnabledState: true,
            hasTapAction: true,
          ),
        );
        // Nothing else on the bar changes.
        expect(find.byKey(keys.createPlaylist), findsOneWidget);
        await tester.tap(find.byKey(keys.playNow));
        expect(tapped.nowPlaying, 1);
        expect(tapped.plays, 0);
        handle.dispose();
      },
    );

    testWidgets('Play is inert while a start is in flight, and never opens Now Playing', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final gate = Completer<void>();
      final player = PlaybackController(
        playback.FakeApi(),
        playback.FakeBridge()..pending = gate,
      );
      final tapped = await _pumpActions(
        tester,
        queue: [_track(0)],
        // The mix reads as this one's from the tap: the controller marks it
        // `waiting` before the native call.
        playing: true,
        player: player,
      );
      const keys = MixHandoffKeys.arrangement;
      unawaited(player.start('s1', 1, 'Mix', [_track(0)]));
      await tester.pump();
      await tester.pump();
      expect(player.busy, isTrue);
      final play = tester.widget<TapeButton>(find.byKey(keys.playNow));
      expect(play.label, 'Play');
      expect(play.onPressed, isNull);
      expect(find.byKey(MixHandoffKeys.meterKey), findsNothing);
      await tester.tap(find.byKey(keys.playNow));
      expect(tapped.nowPlaying, 0);
      expect(tapped.plays, 0);

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(player.busy, isFalse);
      expect(
        tester.widget<TapeButton>(find.byKey(keys.playNow)).label,
        'Playing',
      );
      player.dispose();
    });

    testWidgets('Play is inert while the mix is on its way to the Music app', (
      tester,
    ) async {
      final tapped = await _pumpActions(
        tester,
        queue: [_track(0)],
        sendingToMusic: true,
      );
      const keys = MixHandoffKeys.arrangement;
      expect(
        tester.widget<TapeButton>(find.byKey(keys.playNow)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(keys.playNow));
      expect(tapped.plays, 0);
      // Create playlist is a different action and stays live.
      expect(
        tester.widget<LabelChip>(find.byKey(keys.createPlaylist)).onPressed,
        isNotNull,
      );
    });

    testWidgets('changing the platform changes the bar at once', (
      tester,
    ) async {
      final tapped = await _pumpActions(
        tester,
        queue: [_track(0)],
        platform: MusicPlatform.apple,
      );
      const keys = MixHandoffKeys.arrangement;
      expect(find.byKey(keys.playNow), findsOneWidget);
      await tapped.container
          .read(musicPlatformProvider.notifier)
          .choose(MusicPlatform.spotify);
      await tester.pumpAndSettle();
      expect(find.byKey(keys.playNow), findsNothing);
      expect(find.byKey(keys.spotifyPlaylist), findsOneWidget);
    });

    testWidgets('no Apple match keeps both, inert, beside the reason', (
      tester,
    ) async {
      final queue = [_track(0, appleId: null, spotifyId: 'sp0')];
      final tapped = await _pumpActions(
        tester,
        queue: queue,
        platform: MusicPlatform.apple,
      );
      const keys = MixHandoffKeys.arrangement;
      expect(find.byKey(keys.playNow), findsOneWidget);
      expect(find.byKey(keys.createPlaylist), findsOneWidget);
      expect(find.byKey(keys.spotifyPlaylist), findsNothing);
      await tester.tap(find.byKey(keys.playNow));
      await tester.tap(find.byKey(keys.createPlaylist));
      expect(tapped.plays, 0);
      expect(tapped.playlists, 0);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: tapped.container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: Scaffold(
              body: MixPlayReason(keys: keys, queue: queue),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(keys.reason)).data,
        "these tracks aren't in Apple Music",
      );
    });

    testWidgets('a Spotify listener has no Apple reason to read', (
      tester,
    ) async {
      final queue = [_track(0, appleId: null)];
      final tapped = await _pumpActions(
        tester,
        queue: queue,
        platform: MusicPlatform.spotify,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: tapped.container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: Scaffold(
              body: MixPlayReason(
                keys: MixHandoffKeys.arrangement,
                queue: queue,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a busy host makes them inert in place', (tester) async {
      final tapped = await _pumpActions(
        tester,
        queue: [_track(0), _track(1)],
        enabled: false,
      );
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.playNow));
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.createPlaylist));
      expect(tapped.plays, 0);
      expect(tapped.playlists, 0);
    });

    testWidgets('an inert action absorbs its tap instead of opening the tape', (
      tester,
    ) async {
      var opened = 0;
      Future<void> pump(MusicPlatform platform) async {
        final container = ProviderContainer(
          overrides: [
            playbackProvider.overrideWithValue(
              PlaybackController(playback.FakeApi(), playback.FakeBridge()),
            ),
            musicPlatformStoreProvider.overrideWithValue(
              InMemoryMusicPlatformStore(platform),
            ),
            onboardingProvider.overrideWith(() => _Onboarding(null)),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MixtapeTheme.light(),
              home: Scaffold(
                body: TapeStrip(
                  title: 'Mix',
                  version: 1,
                  songs: 1,
                  caseColor: const Color(0xFF617F9C),
                  onOpen: () => opened++,
                  actions: MixActions(
                    keys: MixHandoffKeys.conversation,
                    queue: [_track(0, appleId: null)],
                    enabled: false,
                    isPlayingThisMix: () => false,
                    onPlay: () {},
                    onOpenNowPlaying: () {},
                    onCreatePlaylist: () {},
                    onCreateSpotifyPlaylist: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      const keys = MixHandoffKeys.conversation;
      await pump(MusicPlatform.apple);
      await tester.tap(find.byKey(keys.playNow));
      await tester.tap(find.byKey(keys.createPlaylist));
      await pump(MusicPlatform.spotify);
      await tester.tap(find.byKey(keys.spotifyPlaylist));
      expect(opened, 0);
    });

    testWidgets('at accessibility sizes the pair stacks, each full width', (
      tester,
    ) async {
      await _pumpActions(
        tester,
        queue: [_track(0)],
        platform: MusicPlatform.apple,
        textScale: 2,
      );
      const keys = MixHandoffKeys.arrangement;
      final play = tester.getRect(find.byKey(keys.playNow));
      final create = tester.getRect(find.byKey(keys.createPlaylist));
      final row = tester.getRect(find.byType(MixActions));
      expect(play.bottom, lessThanOrEqualTo(create.top));
      expect(play.width, row.width);
      expect(create.width, row.width);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'at accessibility sizes the strip title may wrap to two lines',
      (tester) async {
        await _pumpActions(
          tester,
          queue: [_track(0)],
          textScale: 2,
          width: 320,
        );
        final title = tester.widget<Text>(
          find.text('Smooth Cruise Through Lagos'),
        );
        expect(title.maxLines, 2);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'in the strip the actions sit on their own row under the title',
      (tester) async {
        await _pumpActions(tester, queue: [_track(0)]);
        final title = tester.getRect(find.text('Smooth Cruise Through Lagos'));
        final play = tester.getRect(
          find.byKey(MixHandoffKeys.arrangement.playNow),
        );
        expect(play.top, greaterThan(title.bottom));
        expect(
          tester
              .widget<Text>(find.text('Smooth Cruise Through Lagos'))
              .maxLines,
          1,
        );
      },
    );

    testWidgets('the conversation draws them under its own keys', (
      tester,
    ) async {
      await _pumpActions(
        tester,
        queue: [_track(0)],
        keys: MixHandoffKeys.conversation,
      );
      expect(find.byKey(MixHandoffKeys.conversation.playNow), findsOneWidget);
      expect(
        find.byKey(MixHandoffKeys.conversation.createPlaylist),
        findsOneWidget,
      );
      expect(find.byKey(MixHandoffKeys.arrangement.playNow), findsNothing);
    });
  });

  group('save alert, new to you', () {
    const helper = 'Shown under the playlist in Apple Music';
    const one =
        '1 song here is new to you. Saving adds it to your Apple Music library.';
    const three =
        '3 songs here are new to you. Saving adds them to your Apple Music library.';

    Future<void> pumpDialog(WidgetTester tester, int count) => tester.pumpWidget(
      MaterialApp(
        home: MixSaveDialog(
          keys: MixHandoffKeys.arrangement,
          defaultName: 'Late drive',
          defaultAuthor: '',
          newToYouCount: count,
          onConfirm: (_, _) async {},
        ),
      ),
    );

    testWidgets('a mix of only owned songs keeps the alert unchanged', (
      tester,
    ) async {
      await pumpDialog(tester, 0);
      expect(find.text(helper), findsOneWidget);
      expect(find.textContaining('new to you'), findsNothing);
    });

    testWidgets('one new song reads in the singular, after the helper line', (
      tester,
    ) async {
      await pumpDialog(tester, 1);
      expect(find.text(one), findsOneWidget);
      expect(
        tester.getRect(find.text(one)).top,
        greaterThanOrEqualTo(tester.getRect(find.text(helper)).bottom),
      );
      final style = tester.widget<Text>(find.text(one)).style!;
      expect(style.fontSize, 12);
      expect(style, tester.widget<Text>(find.text(helper)).style);
    });

    testWidgets('several new songs read in the plural', (tester) async {
      await pumpDialog(tester, 3);
      expect(find.text(three), findsOneWidget);
    });

    testWidgets('the shared save flow, used by both screens, counts the queue\'s new songs', (tester) async {
      await _pumpHost(
        tester,
        _container(),
        queue: [
          _track(0, newToYou: true),
          _track(1),
          _track(2, newToYou: true),
          _track(3, newToYou: true),
        ],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();

      expect(find.text(three), findsOneWidget);
    });
  });
  group('Play here', () {
    PlatformException native(String code) =>
        PlatformException(code: code, message: 'native');

    Future<
      ({
        _HostState host,
        FakeBridge music,
        playback.FakeBridge app,
        PlaybackController player,
      })
    >
    pumpPlay(WidgetTester tester, {List<Object> startErrors = const []}) async {
      FlutterSecureStorage.setMockInitialValues({});
      final app = playback.FakeBridge()..startErrors.addAll(startErrors);
      final player = PlaybackController(playback.FakeApi(), app);
      final music = FakeBridge();
      final host = await _pumpHost(
        tester,
        _container(bridge: music, player: player),
        queue: [_track(0), _track(1, appleId: null)],
      );
      return (host: host, music: music, app: app, player: player);
    }

    Future<void> tapPlay(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('host-play-here')));
      // Now Playing animates its meter, so a settle would never finish.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a start that works opens Now Playing', (tester) async {
      final t = await pumpPlay(tester);
      await tapPlay(tester);
      expect(find.byType(PlaybackScreen), findsOneWidget);
      expect(t.player.sessionId, 's1');
      expect(t.music.playCalls, isEmpty);
      expect(t.host.snacks, isEmpty);
    });

    testWidgets('access never granted is asked for on the tap, then plays', (
      tester,
    ) async {
      final t = await pumpPlay(
        tester,
        startErrors: [native('authorization_required')],
      );
      await tapPlay(tester);
      expect(t.app.authorizes, 1);
      expect(find.byType(PlaybackScreen), findsOneWidget);
      expect(t.music.playCalls, isEmpty);
    });

    for (final code in [
      'authorization_denied',
      'playback_failed',
      'song_unavailable',
      'empty_queue',
    ]) {
      testWidgets('$code goes to the Music app with no error screen', (
        tester,
      ) async {
        final t = await pumpPlay(
          tester,
          startErrors: [
            code == 'authorization_denied'
                ? native('authorization_required')
                : native(code),
          ],
        );
        t.app.allowAccess = code != 'authorization_denied';
        await tapPlay(tester);
        expect(find.byType(PlaybackScreen), findsNothing);
        expect(t.music.playCalls, [
          ['apple'],
        ]);
        expect(t.host.snacks, [
          'Playing in Apple Music · 1 song skipped (not in Apple Music)',
        ]);
        // Nothing left on the app's player to show as a failure.
        expect(t.player.sessionId, isNull);
        expect(t.player.error, isEmpty);
      });
    }

    testWidgets('leaving the screen mid-start still releases and plays in Music', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final app = _LateFailBridge();
      final player = PlaybackController(playback.FakeApi(), app);
      final music = FakeBridge();
      final api = FakeDjApi();
      final container = _container(api: api, bridge: music, player: player);
      await _pumpHost(tester, container, queue: [_track(0), _track(1)]);

      await tester.tap(find.byKey(const Key('host-play-here')));
      await tester.pump();
      // The listener leaves before Apple answers.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      app.gate.complete();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(music.playCalls, [
        ['apple', 'apple'],
      ]);
      expect(player.sessionId, isNull, reason: 'released');
      expect(api.postedEvents.map((e) => e.type), ['played']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no subscription still tries the Music app', (tester) async {
      final t = await pumpPlay(
        tester,
        startErrors: [native('subscription_required')],
      );
      await tapPlay(tester);
      expect(find.byType(PlaybackScreen), findsNothing);
      expect(t.music.playCalls, hasLength(1));
      expect(t.host.snacks, [
        'Playing in Apple Music · 1 song skipped (not in Apple Music)',
      ]);
    });

    testWidgets('no subscription and no Music app says so plainly', (
      tester,
    ) async {
      final t = await pumpPlay(
        tester,
        startErrors: [native('subscription_required')],
      );
      t.music.onPlayQueue = (_) async => throw MusicKitException('nope');
      await tapPlay(tester);
      expect(find.byType(PlaybackScreen), findsNothing);
      expect(t.host.snacks, ['Playing needs an Apple Music subscription.']);
    });

    testWidgets('a failed fallback says so plainly, never the raw reason', (
      tester,
    ) async {
      final t = await pumpPlay(
        tester,
        startErrors: [native('playback_failed')],
      );
      t.music.onPlayQueue = (_) async => throw MusicKitException(
        "The operation couldn't be completed. (MPMusicPlayerControllerErrorDomain error 6.)",
      );
      await tapPlay(tester);
      expect(find.byType(PlaybackScreen), findsNothing);
      expect(t.host.snacks, [mixPlayFallbackFailedMessage]);
      expect(t.host.snacks.single, isNot(contains('MPMusicPlayer')));
    });
  });
}
