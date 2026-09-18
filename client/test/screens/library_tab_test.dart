// The Library tab (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 8.1; board frame L1): Sources and Playlists as two
// flush lists under bold section words, the glass Sync/More cluster at the
// title, and the states the approved record names — empty, loading, failed.
//
// The tab hosts Your music and the playlist browser unchanged; both are
// pushed, and this file asserts by pushed type.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';
import 'package:mixtape/presentation/screens/playlist_browser_screen.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/screens/tabs/library_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart'
    show kFrostedDockHeight;
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/library_sync_sheet.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

PlaylistSummary _summary(
  String id, {
  String name = 'Late nights',
  String source = 'apple',
  int entryCount = 41,
}) => PlaylistSummary(
  id: id,
  name: name,
  source: source,
  kind: 'user',
  entryCount: entryCount,
  inLibrary: true,
  capability: 'copy_only',
);

/// A collection of [pages] pages, each 12 rows deep so the list is long
/// enough to scroll.
class _PagedApi implements PlaylistApi {
  _PagedApi({this.empty = false, this.failPage = false});

  /// The second page throws, once.
  final bool failPage;
  bool _failed = false;

  /// Two pages, then the cursor runs out.
  static const int pages = 2;

  final bool empty;
  final cursors = <String?>[];

  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async {
    cursors.add(cursor);
    if (empty) return const PlaylistPage(playlists: []);
    if (failPage && cursor != null && !_failed) {
      _failed = true;
      throw const PlaylistModelException();
    }
    final page = cursor == null ? 0 : int.parse(cursor);
    return PlaylistPage(
      playlists: [
        for (var i = 0; i < 12; i++)
          _summary(
            'p$page-$i',
            name: page == 0 && i == 0 ? 'Late nights' : 'Playlist $page-$i',
            source: page == 0 && i == 1 ? 'spotify_export' : 'apple',
          ),
      ],
      nextCursor: page + 1 < pages ? '${page + 1}' : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A collection that never lands until the test says so.
class _SlowApi extends _PagedApi {
  final _gate = Completer<void>();

  void complete() => _gate.complete();

  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async {
    await _gate.future;
    return super.list(
      status: status,
      query: query,
      limit: limit,
      cursor: cursor,
    );
  }
}

MusicSource _apple() => musicSource(
  source: 'apple_live',
  lastImportedAt: DateTime(2026, 9, 4, 10),
);

MusicSource _spotify() => musicSource(
  packages: ['spotify_account'],
  lastImportedAt: DateTime(2026, 9, 3, 10),
);

/// The onboarding harness's fakes plus this tab's own providers.
///
/// Built here rather than through `onboardingContainer` because the playlist
/// and sync overrides have to share one container: a nested `ProviderScope`
/// would leave `playlistCollectionProvider` hosted by the root, reading the
/// root's API.
ProviderContainer _container({
  FakeListeningApi? listening,
  PlaylistApi? playlists,
  // `Override` is not exported by flutter_riverpod; the list is spread into
  // the container's own typed list.
  List<dynamic> extra = const [],
}) {
  final container = ProviderContainer(
    // Riverpod 3 retries a failed provider on a timer; the failure cases want
    // the error to stand still.
    retry: (_, __) => null,
    overrides: [
      listeningImportServiceProvider.overrideWithValue(FakeImportService()),
      archivePickerProvider.overrideWithValue(FakeArchivePicker()),
      openedArchiveSourceProvider.overrideWithValue(FakeOpenedArchiveSource()),
      deviceTimeZoneProvider.overrideWithValue(() async => 'Africa/Lagos'),
      exportDiagnoserProvider.overrideWithValue((_) async => brokenDiagnostics),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(BareDjApi()),
      listeningApiProvider.overrideWithValue(
        listening ??
            FakeListeningApi(
              onboarding: onboardingState(
                chosenService: 'apple',
                hasLibrary: true,
                sources: [_apple(), _spotify()],
              ),
            ),
      ),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
      reminderSchedulerProvider.overrideWithValue(FakeReminderScheduler()),
      servicePreferenceStoreProvider.overrideWithValue(
        InMemoryServicePreferenceStore(),
      ),
      funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
      linkOpenerProvider.overrideWithValue(FakeLinkOpener().call),
      playlistApiProvider.overrideWithValue(playlists ?? _PagedApi()),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool dockInset = false,
  bool settle = true,
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
          builder: (context) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              // `dockInset` stands in for the shell, which hands a tab root
              // the dock's own height as bottom padding (task 2.2).
              data: media.copyWith(
                textScaler: TextScaler.linear(textScale),
                padding: dockInset
                    ? media.padding.copyWith(bottom: kFrostedDockHeight)
                    : media.padding,
              ),
              child: const LibraryTab(),
            );
          },
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// A sync already under way, so the sheet's running copy can be asserted
/// without touching the MusicKit bridge.
class _RunningSync extends LibrarySyncNotifier {
  @override
  SyncState build() => const SyncRunning(0.4);
}

void main() {
  group('chrome', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders the title, both sections and the glass cluster in '
          '${brightness.name}', (tester) async {
        await _pump(tester, _container(), brightness: brightness);

        expect(find.text('Library'), findsOneWidget);
        expect(find.text('Sources'), findsOneWidget);
        expect(find.text('Playlists'), findsOneWidget);
        expect(find.byType(GlassCluster), findsOneWidget);
        expect(find.byKey(LibraryTab.syncButtonKey), findsOneWidget);
        expect(find.byKey(LibraryTab.moreButtonKey), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('leaves room under the list for the floating dock', (
      tester,
    ) async {
      // An empty collection keeps the body short, so the scaffold's closing
      // sliver is actually laid out.
      await _pump(
        tester,
        _container(playlists: _PagedApi(empty: true)),
        dockInset: true,
      );

      final media = MediaQuery.of(tester.element(find.byType(LibraryTab)));
      expect(media.padding.bottom, kFrostedDockHeight);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.height == media.padding.bottom,
        ),
        findsWidgets,
        reason: "the scaffold ends on the dock's own height",
      );
      expect(
        media.padding.bottom + LibraryTab.defaultBottomInset,
        greaterThanOrEqualTo(kFrostedDockHeight + 16),
        reason: 'content has to clear the dock, once',
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
      expect(find.byKey(LibraryTab.addSpotifyKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('sources', () {
    testWidgets('each source is a row with a status word and its detail', (
      tester,
    ) async {
      await _pump(tester, _container());

      expect(find.byKey(LibraryTab.sourceRowKey('apple_live')), findsOneWidget);
      expect(
        find.byKey(LibraryTab.sourceRowKey('spotify_export')),
        findsOneWidget,
      );
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.text('Spotify · account data'), findsOneWidget);
      expect(find.byType(StatusWord), findsNWidgets(2));
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('1 of 2 in'), findsOneWidget);
      expect(find.text('Imported 4 Sep'), findsOneWidget);
    });

    testWidgets('the Apple row opens Your music', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.sourceRowKey('apple_live')));
      await tester.pumpAndSettle();

      expect(find.byType(MusicSourcesScreen), findsOneWidget);
    });

    testWidgets('an imported source offers Import again and Remove, keeping '
        'the approved confirmation', (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          sources: [_spotify()],
        ),
      );
      await _pump(tester, _container(listening: listening));

      await tester.tap(find.byKey(LibraryTab.sourceRowKey('spotify_export')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(LibraryTab.sourceImportAgainKey('spotify_export')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(LibraryTab.sourceRemoveKey('spotify_export')));
      await tester.pumpAndSettle();

      expect(find.text('Remove Spotify · account data?'), findsOneWidget);
      expect(find.byKey(const Key('remove-keep')), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();

      expect(listening.deletedSources, ['spotify_export']);
    });

    testWidgets('Add Spotify music opens the import guide', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.addSpotifyKey));
      await tester.pumpAndSettle();

      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    });

    testWidgets('no sources: the cassette, the words and a way in', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await _pump(tester, _container(listening: listening));

      expect(find.byKey(LibraryTab.emptyKey), findsOneWidget);
      expect(find.byType(CassetteTile), findsOneWidget);
      expect(find.text(LibraryTab.emptyTitle), findsOneWidget);
      expect(find.text(LibraryTab.emptyBody), findsOneWidget);
      // Nothing to list yet: the Playlists section stays away.
      expect(find.text('Playlists'), findsNothing);

      await tester.tap(find.byKey(LibraryTab.emptySetupKey));
      await tester.pumpAndSettle();
      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    });

    testWidgets('a failed sources load offers Try again', (tester) async {
      final listening = FakeListeningApi();
      listening.onGetOnboarding = () async => throw StateError('boom');
      await _pump(tester, _container(listening: listening));

      expect(find.text("couldn't load your sources"), findsOneWidget);
      expect(find.byKey(LibraryTab.sourcesRetryKey), findsOneWidget);
    });
  });

  group('playlists', () {
    testWidgets('playlists are flush rows with counts and source', (
      tester,
    ) async {
      await _pump(tester, _container());

      expect(find.text('Late nights'), findsOneWidget);
      expect(find.text('41 songs · Apple Music'), findsWidgets);
      expect(find.text('41 songs · Spotify import'), findsOneWidget);
    });

    testWidgets('a playlist row opens its detail', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('playlist-row-p0-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The detail screen is pushed rather than the browser; it fetches its
      // own entries, which this container does not answer.
      expect(find.byType(PlaylistDetailScreen), findsOneWidget);
      expect(find.byType(PlaylistBrowserScreen), findsNothing);
    });

    testWidgets('scrolling to the end fetches the next page, with no button', (
      tester,
    ) async {
      final api = _PagedApi();
      await _pump(tester, _container(playlists: api));

      expect(find.byKey(const Key('load-more-playlists')), findsNothing);
      expect(api.cursors, [null]);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      expect(api.cursors, [null, '1']);
      expect(find.byKey(const Key('load-more-playlists')), findsNothing);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('playlist-row-p1-11')),
        findsOneWidget,
        reason: 'the second page is on screen at the end of the list',
      );
    });

    testWidgets('a failed page stops the scroll paging and offers Load more', (
      tester,
    ) async {
      final api = _PagedApi(failPage: true);
      await _pump(tester, _container(playlists: api));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(api.cursors, [null, '1'], reason: 'the page was asked for once');

      // Scrolling again must not ask again: the failure waits for the reader.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(api.cursors, [null, '1']);

      final retry = find.byKey(LibraryTab.loadMoreKey);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(api.cursors, [null, '1', '1']);
      expect(find.byKey(LibraryTab.loadMoreKey), findsNothing);
    });

    testWidgets('overscrolling an empty library asks for no playlists at all', (
      tester,
    ) async {
      final api = _PagedApi();
      await _pump(
        tester,
        _container(
          listening: FakeListeningApi(
            onboarding: onboardingState(chosenService: 'spotify'),
          ),
          playlists: api,
        ),
      );

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(find.text('Playlists'), findsNothing);
      expect(api.cursors, isEmpty, reason: 'no section, no request');
    });

    testWidgets('an empty collection says so in the approved words', (
      tester,
    ) async {
      await _pump(tester, _container(playlists: _PagedApi(empty: true)));

      expect(find.text(kNoPlaylistsTitle), findsOneWidget);
      expect(find.text(kNoPlaylistsBody), findsOneWidget);
    });

    testWidgets('the first page in flight shows skeleton rows', (tester) async {
      final api = _SlowApi();
      await _pump(tester, _container(playlists: api), settle: false);

      expect(find.byType(PlaylistSkeletonRows), findsWidgets);

      api.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistSkeletonRows), findsNothing);
    });
  });

  group('cluster', () {
    testWidgets('Sync opens the shared library sync sheet', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.syncButtonKey));
      await tester.pumpAndSettle();

      expect(find.byType(LibrarySyncSheet), findsOneWidget);
      expect(find.byKey(LibrarySyncSheet.startKey), findsOneWidget);
    });

    testWidgets('the sheet shows a sync already running', (tester) async {
      await _pump(
        tester,
        _container(
          listening: FakeListeningApi(
            onboarding: onboardingState(
              chosenService: 'apple',
              hasLibrary: true,
              sources: [_apple()],
            ),
          ),
          extra: [librarySyncProvider.overrideWith(_RunningSync.new)],
        ),
      );

      await tester.tap(find.byKey(LibraryTab.syncButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Syncing… 40%'), findsOneWidget);
      expect(find.byKey(LibrarySyncSheet.startKey), findsNothing);
    });

    testWidgets('More holds Your music, and nothing else is lost', (
      tester,
    ) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.moreButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(LibraryTab.yourMusicKey), findsOneWidget);

      await tester.tap(find.byKey(LibraryTab.yourMusicKey));
      await tester.pumpAndSettle();
      expect(find.byType(MusicSourcesScreen), findsOneWidget);
    });
  });

  testWidgets('every flush row is a real row, not a card', (tester) async {
    await _pump(tester, _container());

    expect(find.byType(FlushRow), findsWidgets);
    expect(find.byType(Card), findsNothing);
  });
}
