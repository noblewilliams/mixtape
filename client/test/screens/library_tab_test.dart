// The Library tab (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 8.1; reworked by `docs/mockups/approved/2026-11-03-
// library-sources.md`; restyled by the add your music board r3/r4, L1): two
// flush source rows with the official icons and the Playlists list, the
// title's one "Add music" pill into Add your music, and the states the
// approved records name — empty, loading, failed. Sync lives with Apple
// Music, never on this title.
//
// Add your music is pushed, and this file asserts by pushed type.
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';
import 'package:mixtape/data/api/api_client.dart' show NetworkException;
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
import 'package:mixtape/presentation/screens/music_sources_screen.dart'
    show kSourcesLoadFailedTitle;
import 'package:mixtape/presentation/screens/playlist_browser_screen.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/screens/tabs/library_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/brand_icons.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/empty_state.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart'
    show kFrostedDockHeight;
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';

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

MusicSource _apple() =>
    musicSource(source: 'apple_live', lastImportedAt: DateTime(2026, 9, 4, 10));

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
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
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
              // The top stays at the test view's 0: these geometry tests
              // predate the top floor a page gets where no status bar runs
              // across the top (`PageInsets`, tested on its own).
              data: media.copyWith(
                textScaler: TextScaler.linear(textScale),
                padding: dockInset
                    ? media.padding.copyWith(top: 0, bottom: kFrostedDockHeight)
                    : media.padding.copyWith(top: 0),
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

/// A sync already under way, so the strip's running copy can be asserted
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
        // Beside the title, not under it (board r3 `.large-title.lib2`).
        final title = tester.getRect(find.text('Library'));
        final add = tester.getRect(find.byKey(LibraryTab.addMusicKey));
        expect(add.left, greaterThan(title.right));
        expect(add.top, lessThan(title.bottom));
        expect(find.text('Sources'), findsNothing);
        expect(find.text('Playlists'), findsOneWidget);
        expect(find.byType(GlassCluster), findsOneWidget);
        // One button that says what it does (2026-11-09): no Sync beside it,
        // since sync is Apple Music's alone.
        expect(
          find.descendant(
            of: find.byType(GlassCluster),
            matching: find.byType(GlassLabelButton),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(LibraryTab.addMusicKey),
            matching: find.text('Add music'),
          ),
          findsOneWidget,
        );
        expect(find.text('Sync'), findsNothing);
        expect(find.text('Your music'), findsNothing);
        expect(find.byIcon(Icons.more_horiz), findsNothing);
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
      expect(find.byKey(LibraryTab.spotifySourceKey), findsOneWidget);
      expect(find.byKey(LibraryTab.addMusicKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('sources', () {
    testWidgets('VoiceOver can open each source row', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _container());
      for (final key in [
        LibraryTab.appleSourceKey,
        LibraryTab.spotifySourceKey,
      ]) {
        expect(
          tester
              .getSemantics(find.byKey(key))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
          reason: '$key has no tap action',
        );
      }
      handle.dispose();
    });

    testWidgets('two flush rows, each with its official icon and status', (
      tester,
    ) async {
      await _pump(tester, _container());

      final apple = find.byKey(LibraryTab.appleSourceKey);
      final spotify = find.byKey(LibraryTab.spotifySourceKey);
      expect(
        find.descendant(of: apple, matching: find.text('Apple Music')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: apple, matching: find.byType(AppleMusicIcon)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: apple, matching: find.text('Synced 4 Sep')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: spotify, matching: find.byType(SpotifyIcon)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: spotify, matching: find.text('1 of 2 in')),
        findsOneWidget,
      );
      // Two rows, one above the other, each at least a 44 pt target.
      expect(
        tester.getRect(spotify).top,
        greaterThanOrEqualTo(tester.getRect(apple).bottom - 1),
      );
      for (final row in [apple, spotify]) {
        final rect = tester.getRect(row);
        expect(rect.height, greaterThanOrEqualTo(44));
        expect(rect.height, lessThan(60), reason: 'compact flush rows');
        // The 22 pt icon, the status on the same line as the name.
        expect(
          tester.getSize(
            find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (w) => w is AppleMusicIcon || w is SpotifyIcon,
              ),
            ),
          ),
          const Size(22, 22),
        );
      }
      expect(
        tester.getCenter(find.text('Synced 4 Sep')).dy,
        moreOrLessEquals(
          tester.getCenter(find.text('Apple Music')).dy,
          epsilon: 2,
        ),
      );
      // Each row is one button that says where the service stands.
      expect(
        find.bySemanticsLabel('Apple Music, Synced 4 Sep'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Spotify, 1 of 2 in'), findsOneWidget);
    });

    testWidgets('a service with nothing in yet says Not added, in full '
        'colour', (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'apple',
          hasLibrary: true,
          sources: [_apple()],
        ),
      );
      await _pump(tester, _container(listening: listening));

      final spotify = find.byKey(LibraryTab.spotifySourceKey);
      expect(
        find.descendant(of: spotify, matching: find.text('Not added')),
        findsOneWidget,
      );
      // The official icon is never greyed or faded.
      expect(
        find.descendant(of: spotify, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(
        find.descendant(of: spotify, matching: find.byType(SpotifyIcon)),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Spotify, not added'), findsOneWidget);
    });

    testWidgets('an account with only the Apple history says so', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'apple',
          sources: [
            musicSource(
              source: 'apple_export',
              lastImportedAt: DateTime(2026, 10, 28),
            ),
          ],
        ),
      );
      await _pump(tester, _container(listening: listening));

      expect(
        find.descendant(
          of: find.byKey(LibraryTab.appleSourceKey),
          matching: find.text('History added'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('at large text the status drops under the name and the '
        'icons grow', (tester) async {
      await _pump(tester, _container(), textScale: 1.3);

      final name = tester.getRect(find.text('Apple Music'));
      final status = tester.getRect(find.text('Synced 4 Sep'));
      expect(status.top, greaterThanOrEqualTo(name.bottom - 1));
      expect(tester.getSize(find.byType(AppleMusicIcon)), const Size(28, 28));
      expect(tester.getSize(find.byType(SpotifyIcon)), const Size(28, 28));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Apple row opens Add your music on Apple Music', (
      tester,
    ) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.appleSourceKey));
      await tester.pumpAndSettle();

      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
      expect(find.byKey(SpotifyRequestScreen.appleSyncKey), findsOneWidget);
    });

    testWidgets('the Spotify row opens Add your music on Spotify', (
      tester,
    ) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.spotifySourceKey));
      await tester.pumpAndSettle();

      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
      expect(
        tester
            .widget<SpotifyRequestScreen>(find.byType(SpotifyRequestScreen))
            .initialSegment,
        SpotifyRequestScreen.spotifySegment,
      );
      // The account data is in, so its pane opens on Saved music, done.
      expect(
        find.byKey(SpotifyRequestScreen.spotifyImportAgainKey),
        findsOneWidget,
      );
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
      // The empty state's own "Add your music" is the one way in; the title
      // stands aside rather than offer a second one that goes elsewhere.
      expect(find.byKey(LibraryTab.addMusicKey), findsNothing);
      expect(find.text('Add your music'), findsOneWidget);

      await tester.tap(find.byKey(LibraryTab.emptySetupKey));
      await tester.pumpAndSettle();
      // Path B's Step 1, in the mode that comes back here.
      expect(find.byType(ChooseServiceScreen), findsOneWidget);
      expect(
        tester
            .widget<ChooseServiceScreen>(find.byType(ChooseServiceScreen))
            .mode,
        AddMusicMode.library,
      );
    });

    testWidgets('the cassette sits mid-band, under the bar and over the dock', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await _pump(tester, _container(listening: listening), dockInset: true);

      // The band is measured on the screen, not on this tab's own title row
      // (smoke round three, note 7), so every tab agrees on it.
      final cassette = tester.getRect(find.byKey(EmptyState.cassetteKey));
      const dockTop = 844 - kFrostedDockHeight;
      const middle = (EmptyStateSliver.topOffset + dockTop) / 2;
      expect(
        (cassette.center.dy - middle).abs(),
        lessThanOrEqualTo(1),
        reason: 'it neither hugs the title nor drifts onto the dock',
      );
      final empty = tester.getRect(find.byKey(LibraryTab.emptyKey));
      expect(empty.top, lessThan(cassette.center.dy));
      expect(empty.bottom, lessThan(dockTop));
    });

    testWidgets('Mixes and Library centre their empty block at the same y', (
      tester,
    ) async {
      // Smoke round three, note 7: one block, one placement rule, so the
      // cassette does not jump when the listener switches tabs.
      const size = Size(390, 844);
      Future<Rect> cassetteIn(Widget tab) async {
        final listening = FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        );
        final container = _container(listening: listening);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MixtapeTheme.light(),
              home: Builder(
                builder: (context) {
                  final media = MediaQuery.of(context);
                  return MediaQuery(
                    // The shell hands each tab root the dock as bottom
                    // padding; both tabs get exactly the same one here.
                    data: media.copyWith(
                      padding: media.padding.copyWith(
                        bottom: kFrostedDockHeight,
                      ),
                    ),
                    child: tab,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(EmptyState.cassetteKey), findsOneWidget);
        final rect = tester.getRect(find.byKey(EmptyState.cassetteKey));
        await tester.pumpWidget(const SizedBox());
        return rect;
      }

      final library = await cassetteIn(const LibraryTab());
      // Both tabs carry an action, as they do in the shell — Mixes only
      // offers "Start a mix" when the shell can switch tabs for it.
      final mixes = await cassetteIn(MixesScreen(onStartMix: () {}));

      expect(library.width, EmptyState.cassetteWidth);
      expect(mixes.width, EmptyState.cassetteWidth);
      expect(
        (library.center.dy - mixes.center.dy).abs(),
        lessThanOrEqualTo(1),
        reason: 'the two tabs put the block in the same place',
      );
    });

    testWidgets('a failed sources load offers Try again', (tester) async {
      final listening = FakeListeningApi();
      listening.onGetOnboarding = () async => throw StateError('boom');
      await _pump(tester, _container(listening: listening));

      // The shared load-error state, placed like the empty one.
      expect(find.byType(LoadErrorState), findsOneWidget);
      expect(find.text(kSourcesLoadFailedTitle), findsOneWidget);
      expect(
        tester.widget(find.byKey(LibraryTab.sourcesRetryKey)),
        isA<TapeButton>(),
      );
    });

    testWidgets('offline, it says so, and Try again shows it is working', (
      tester,
    ) async {
      final listening = FakeListeningApi();
      listening.onGetOnboarding = () async => throw NetworkException(
        const SocketException('Failed host lookup: api.example.com'),
      );
      await _pump(tester, _container(listening: listening));

      expect(find.text(LoadErrorState.offlineBody), findsOneWidget);

      final answer = Completer<OnboardingState>();
      listening.onGetOnboarding = () => answer.future;
      await tester.tap(find.byKey(LibraryTab.sourcesRetryKey));
      await tester.pump();

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text(LoadErrorState.busyLabel), findsOneWidget);

      answer.complete(onboardingState());
      await tester.pump(LoadErrorState.minBusy);
      await tester.pump();
      expect(find.byType(LoadErrorState), findsNothing);
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

  group('title', () {
    testWidgets('Add music opens Add your music on its default segment', (
      tester,
    ) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(LibraryTab.addMusicKey));
      await tester.pumpAndSettle();
      final screen = tester.widget<SpotifyRequestScreen>(
        find.byType(SpotifyRequestScreen),
      );
      expect(screen.initialSegment, isNull);
      expect(screen.onDone, isNull);
      expect(find.text('Your music'), findsNothing);
    });

    for (final service in ['apple', 'spotify']) {
      testWidgets('a $service listener gets no Sync on the title', (
        tester,
      ) async {
        final listening = FakeListeningApi(
          onboarding: onboardingState(
            chosenService: service,
            hasLibrary: service == 'apple',
            sources: [if (service == 'apple') _apple(), _spotify()],
          ),
        );
        await _pump(tester, _container(listening: listening));

        expect(find.bySemanticsLabel('Sync Apple Music'), findsNothing);
        expect(find.byType(GlassLabelButton), findsOneWidget);
        expect(find.byKey(LibraryTab.addMusicKey), findsOneWidget);
      });
    }

    testWidgets('the Apple row carries a sync already running', (tester) async {
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
        // The spinner never settles.
        settle: false,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Syncing… 40%'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(LibraryTab.appleSourceKey),
          matching: find.byType(CupertinoActivityIndicator),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('every flush row is a real row, not a card', (tester) async {
    await _pump(tester, _container());

    expect(find.byType(FlushRow), findsWidgets);
    expect(find.byType(Card), findsNothing);
  });
}
