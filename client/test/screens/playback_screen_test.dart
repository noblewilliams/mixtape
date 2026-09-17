import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playback/listening_meter.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import '../data/playback/playback_controller_test.dart'
    show FakeApi, FakeBridge, song;
import '../helpers/auth_ui_snapshot.dart';

void main() {
  testWidgets('player stays reachable at large text on a short phone', (
    tester,
  ) async {
    final api = FakeApi(), bridge = FakeBridge();
    final player = PlaybackController(api, bridge)
      ..sessionId = 'mix'
      ..version = 4
      ..title = 'Sunday, unhurried'
      ..tracks = [song]
      ..sample = const PlayerSample(
        index: 0,
        positionMs: 84000,
        status: 'playing',
      );
    await loadAuthSnapshotFonts(tester);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playbackProvider.overrideWithValue(player)],
        child: RepaintBoundary(
          key: authSnapshotKey,
          child: MaterialApp(
            theme: authSnapshotTheme(Brightness.dark),
            home: const PlaybackScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await captureAuthSnapshot(tester, 'player-native-dark');
    expect(find.text('Sunday, unhurried · version 4'), findsOneWidget);
    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playbackProvider.overrideWithValue(player)],
        child: MaterialApp(
          theme: authSnapshotTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const PlaybackScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Listening preferences'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listening preferences'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Learn from my listening in Mixtape'),
      100,
    );
    await tester.pumpAndSettle();
    expect(find.text('Learn from my listening in Mixtape'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    player.dispose();
    await bridge.events.close();
  });
}
