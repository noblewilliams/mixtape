// Screen-level haptics (`haptics.dart`, `docs/decisions.md` → Haptics): the
// raw touches screens own, beyond what the foundation widgets already play.
// One representative touch per kind of action, through each screen's own
// test harness.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playback/listening_meter.dart';
import 'package:mixtape/data/shell/shell_channel.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';

import '../data/playback/playback_controller_test.dart' show FakeApi;
import '../helpers/haptic_recorder.dart';
import 'mixes_screen_test.dart' show FakeDjApi, TestAuthNotifier;
import 'playback_screen_test.dart' show FakeMusicKit;
import 'shell_screen_test.dart'
    show RecordingBridge, messenger, pumpShell, shellContainer;

const _song = QueueTrack(
  position: 0,
  trackId: 'track-0',
  appleId: '100',
  title: 'Song 0',
  artist: 'Someone',
  durationMs: 235000,
);

PlaybackController _player(RecordingBridge bridge) {
  final player = PlaybackController(FakeApi(), bridge)
    ..sessionId = 'mix-1'
    ..version = 4
    ..title = 'A slow way into Sunday'
    ..tracks = [_song]
    ..sample = const PlayerSample(index: 0, positionMs: 0, status: 'playing');
  addTearDown(player.dispose);
  return player;
}

void main() {
  testWidgets('Mixes: the pull that reveals Archived crosses a threshold', (
    tester,
  ) async {
    final played = recordHaptics(tester);
    final api = FakeDjApi()
      ..onListSessions = () async => [
        DjSession(
          id: 's1',
          title: 'Active One',
          status: 'active',
          queueVersion: 1,
          updatedAt: DateTime.now(),
        ),
        DjSession(
          id: 's2',
          title: 'Old One',
          status: 'archived',
          queueVersion: 1,
          updatedAt: DateTime.now(),
        ),
      ];
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        djApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        albumPicksEnabledProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const MixesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(played, isEmpty);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(find.byKey(MixesScreen.archivedRowKey), findsOneWidget);
    expect(played, [HapticKind.threshold]);
  });

  group('Now Playing', () {
    Future<List<HapticKind>> pump(
      WidgetTester tester, {
      MusicKitBridge? musicKit,
    }) async {
      final played = recordHaptics(tester);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackProvider.overrideWithValue(_player(RecordingBridge())),
            musicKitBridgeProvider.overrideWithValue(
              musicKit ?? FakeMusicKit(),
            ),
            mixEnergyProvider.overrideWith((ref, key) async => const {}),
          ],
          child: MaterialApp(
            theme: MixtapeTheme.dark(),
            home: const PlaybackScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return played;
    }

    testWidgets('Play/Pause is the call to action; Previous and Next tap', (
      tester,
    ) async {
      final played = await pump(tester);

      await tester.tap(find.byKey(PlaybackScreen.playPauseKey));
      await tester.tap(find.byKey(PlaybackScreen.nextKey));
      await tester.tap(find.byKey(PlaybackScreen.previousKey));
      await tester.pump();

      expect(played, [HapticKind.primary, HapticKind.tap, HapticKind.tap]);
    });

    testWidgets('Send to Music commits; Close dismisses', (tester) async {
      final played = await pump(tester);

      await tester.tap(find.byKey(PlaybackScreen.sendToMusicKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlaybackScreen.closeKey));
      await tester.pump();

      expect(played, [HapticKind.commit, HapticKind.dismiss]);
    });
  });

  group('a removal confirmation', () {
    final source = MusicSource(
      source: 'spotify_export',
      connectedAt: DateTime(2026, 10, 1),
      lastImportedAt: DateTime(2026, 10, 1),
      ledgerFrom: null,
      ledgerTo: null,
    );

    Future<List<HapticKind>> pump(WidgetTester tester) async {
      final played = recordHaptics(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirmSourceRemoval(context, source),
              child: const Text('ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      return played;
    }

    testWidgets('keeping it dismisses', (tester) async {
      final played = await pump(tester);
      await tester.tap(find.byKey(const Key('remove-keep')));
      await tester.pumpAndSettle();
      expect(played, [HapticKind.dismiss]);
    });

    testWidgets('removing it is destructive', (tester) async {
      final played = await pump(tester);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      expect(played, [HapticKind.destructive]);
    });
  });

  testWidgets('first run: Back and a foot link are ordinary taps', (
    tester,
  ) async {
    final played = recordHaptics(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              TapeBackButton(onPressed: () {}),
              FootLink(label: 'Skip', onPressed: () {}),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(TapeBackButton.defaultKey));
    await tester.tap(find.text('Skip'));
    await tester.pump();

    expect(played, [HapticKind.tap, HapticKind.tap]);
  });

  group('the native dock', () {
    Future<void> fromDock(String method, [Object? arguments]) =>
        messenger.handlePlatformMessage(
          ShellChannel.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );

    setUp(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel(ShellChannel.channelName),
        (call) async => null,
      );
    });
    tearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel(ShellChannel.channelName),
        null,
      ),
    );

    testWidgets('a tab change plays nothing (the tab bar ticks natively); '
        'the mini-player opens, plays and skips', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final bridge = RecordingBridge();
        await pumpShell(
          tester,
          shellContainer(nativeDock: true, player: _player(bridge)),
        );
        final played = recordHaptics(tester);

        await fromDock('tabChanged', 1);
        await tester.pumpAndSettle();
        expect(played, isEmpty);

        await fromDock('miniPlayerPlayPause');
        await fromDock('miniPlayerNext');
        await fromDock('miniPlayerTapped');
        await tester.pumpAndSettle();

        expect(played, [HapticKind.primary, HapticKind.tap, HapticKind.open]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
