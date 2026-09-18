// The restyled playlist browser (plan `docs/superpowers/plans/2026-09-17-
// native-design-implementation.md` task 8.1): flush rows with the 60 pt
// square art, the same pagination and keys the September 4 approval pinned.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/screens/playlist_browser_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';

class _SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

PlaylistSummary summary(
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

/// Two pages, then nothing; records what it was asked for.
class _PagedApi implements PlaylistApi {
  _PagedApi({this.failFirst = false, this.empty = false});

  final bool failFirst;
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
    if (failFirst && cursor == null) throw const PlaylistModelException();
    if (empty) return const PlaylistPage(playlists: []);
    if (cursor == null) {
      return PlaylistPage(
        playlists: [
          summary('p1'),
          summary('p2', name: 'Running, long', source: 'spotify_export'),
        ],
        nextCursor: 'page-2',
      );
    }
    return PlaylistPage(playlists: [summary('p3', name: 'Old drives')]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A first page that never lands until the test says so.
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
    return super.list(status: status, query: query, limit: limit, cursor: cursor);
  }
}

ProviderContainer _container(_PagedApi api) {
  final container = ProviderContainer(
    // Riverpod 3 retries a failed provider on a timer; the failure case wants
    // the error to stand still.
    retry: (_, __) => null,
    overrides: [
      authProvider.overrideWith(_SignedIn.new),
      playlistApiProvider.overrideWithValue(api),
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
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const PlaylistBrowserScreen(),
          ),
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

void main() {
  testWidgets('lists playlists as flush rows with counts and source', (
    tester,
  ) async {
    await _pump(tester, _container(_PagedApi()));

    expect(find.text('Playlists'), findsOneWidget);
    expect(find.byType(FlushRow), findsNWidgets(2));
    expect(find.text('Late nights'), findsOneWidget);
    expect(find.text('41 songs · Apple Music'), findsOneWidget);
    expect(find.text('41 songs · Spotify import'), findsOneWidget);
    expect(find.byKey(const Key('playlist-row-p1')), findsOneWidget);
  });

  testWidgets('Load more keeps its key and appends the next page', (
    tester,
  ) async {
    final api = _PagedApi();
    await _pump(tester, _container(api));

    expect(find.byKey(const Key('load-more-playlists')), findsOneWidget);
    await tester.tap(find.byKey(const Key('load-more-playlists')));
    await tester.pumpAndSettle();

    expect(api.cursors, [null, 'page-2']);
    expect(find.text('Old drives'), findsOneWidget);
    expect(find.byKey(const Key('load-more-playlists')), findsNothing);
  });

  testWidgets('the first page in flight shows skeleton rows', (tester) async {
    final api = _SlowApi();
    await _pump(tester, _container(api), settle: false);

    expect(find.byType(PlaylistSkeletonRows), findsOneWidget);
    expect(find.byKey(PlaylistSkeletonRows.rowKey), findsOneWidget);

    api.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistSkeletonRows), findsNothing);
  });

  testWidgets('an empty collection says so in the approved words', (
    tester,
  ) async {
    await _pump(tester, _container(_PagedApi(empty: true)));

    expect(find.byKey(PlaylistsEmpty.emptyKey), findsOneWidget);
    expect(find.text(kNoPlaylistsTitle), findsOneWidget);
    expect(find.text(kNoPlaylistsBody), findsOneWidget);
  });

  testWidgets('a failed load offers Try again', (tester) async {
    await _pump(tester, _container(_PagedApi(failFirst: true)));
    expect(find.text(kPlaylistsFailed), findsOneWidget);
    expect(find.byKey(PlaylistsFailed.retryKey), findsOneWidget);
  });

  testWidgets('holds at 200% text on a 320 pt phone, in dark', (tester) async {
    await _pump(
      tester,
      _container(_PagedApi()),
      brightness: Brightness.dark,
      size: const Size(320, 844),
      textScale: 2,
    );

    expect(find.byType(FlushRow), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
