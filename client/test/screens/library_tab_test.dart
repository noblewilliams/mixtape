// The Library tab skeleton (plan `docs/superpowers/plans/2026-09-17-native-
// design-implementation.md` task 2.4): the large title, the glass Sync
// cluster, and the flush rows that reach everything Home's menu used to offer
// under "Your music" — the sources screen, the Spotify import guide, the
// music-setup entry and the library sync sheet.
//
// The tab hosts the existing screens unchanged; Phase 8 restyles them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/screens/tabs/library_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart'
    show kFrostedDockHeight;
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const LibraryTab(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container() =>
    onboardingContainer(listening: FakeListeningApi());

/// A sync already under way, so the sheet's running copy can be asserted
/// without touching the MusicKit bridge.
class _RunningSync extends LibrarySyncNotifier {
  @override
  SyncState build() => const SyncRunning(0.4);
}

/// LibraryTab's own build watches nothing, so the running-sync case needs
/// only the sync override.
ProviderContainer _syncContainer() {
  final container = ProviderContainer(
    overrides: [librarySyncProvider.overrideWith(_RunningSync.new)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('chrome', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders the title, the section and the Sync cluster in '
          '${brightness.name}', (tester) async {
        await _pump(tester, _container(), brightness: brightness);

        expect(find.text('Library'), findsOneWidget);
        expect(find.text('Sources'), findsOneWidget);
        expect(find.byType(GlassCluster), findsOneWidget);
        expect(
          find.byKey(LibraryTab.syncButtonKey),
          findsOneWidget,
          reason: 'the Sync action Home\'s menu offered',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('leaves room under the list for the floating dock', (
      tester,
    ) async {
      await _pump(tester, _container());

      final bottoms = tester
          .widgetList<SliverPadding>(find.byType(SliverPadding))
          .map((padding) => padding.padding.resolve(TextDirection.ltr).bottom);
      expect(
        bottoms.any((bottom) => bottom >= kFrostedDockHeight),
        isTrue,
        reason: 'content has to clear the dock',
      );
    });

    testWidgets('wraps rather than overflows at 200% text on a 320 pt phone', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(),
        size: const Size(320, 844),
        textScale: 2,
      );

      expect(find.text('Library'), findsOneWidget);
      expect(find.byType(FlushRow), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('routing', () {
    testWidgets('Your music opens the sources screen', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.yourMusicKey));
      await tester.pumpAndSettle();

      expect(find.byType(MusicSourcesScreen), findsOneWidget);
    });

    testWidgets('Add Spotify music opens the import guide', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.addSpotifyKey));
      await tester.pumpAndSettle();

      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    });

    // Music setup is deliberately absent: it duplicated Add Spotify music,
    // and the real setup sheet stays on Home's waiting card.
    testWidgets('offers Sources without a Music setup row', (tester) async {
      await _pump(tester, _container());

      expect(find.text('Music setup'), findsNothing);
      expect(find.byType(FlushRow), findsNWidgets(2));
    });

    testWidgets('Sync opens the library sync sheet', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.syncButtonKey));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(LibraryTab.syncStartKey), findsOneWidget);
    });

    testWidgets('the sheet shows a sync already running', (tester) async {
      await _pump(tester, _syncContainer());

      await tester.tap(find.byKey(LibraryTab.syncButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Syncing… 40%'), findsOneWidget);
      expect(find.byKey(LibraryTab.syncStartKey), findsNothing);
    });
  });
}
