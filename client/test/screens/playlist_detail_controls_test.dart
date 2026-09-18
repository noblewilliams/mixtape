import 'package:flutter/cupertino.dart' show CupertinoAlertDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/new_mix_inspiration_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';
import 'package:mixtape/presentation/widgets/foundation/square_art.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import '../presentation/providers/playlist_taste_provider_test.dart'
    show TestAuth, ReadApi, WriteApi, summary;

PlaylistEntry entry(int position, String title, {bool resolved = true}) =>
    PlaylistEntry(
      id: 'entry-$position',
      position: position,
      trackId: resolved ? 'track-$position' : null,
      title: title,
      artist: resolved ? 'North Parade' : 'Home recording',
      resolved: resolved,
    );

Future<void> pumpDetail(
  WidgetTester tester, {
  required ReadApi reads,
  required WriteApi writes,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Size? size,
  ValueChanged<PlaylistSummary>? onInspire,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(TestAuth.new),
        playlistApiProvider.overrideWithValue(reads),
        playlistContextApiProvider.overrideWithValue(writes),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: PlaylistDetailScreen(playlistId: 'p', onInspire: onInspire),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'inspiration passes exact playlist without confirming; taste requires modal',
    (tester) async {
      final reads = ReadApi();
      final writes = WriteApi();
      var current = summary();
      reads.read = () async => PlaylistDetail(
        playlist: current,
        entries: const [],
        nextEntryCursor: 'keep-page',
      );
      writes.write = (_) async {
        current = summary(origin: 'user_confirmed');
      };
      PlaylistSummary? inspired;
      await pumpDetail(
        tester,
        reads: reads,
        writes: writes,
        onInspire: (playlist) => inspired = playlist,
      );
      await tester.tap(find.text('Make a mix inspired by this'));
      expect(inspired!.id, 'p');
      expect(writes.writes, 0);
      await tester.tap(find.text('I chose these songs'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('Did you choose these songs?'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(writes.writes, 0);
      await tester.tap(find.text('I chose these songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes.writes, 1);
      expect(find.text('Remove confirmation'), findsOneWidget);
    },
  );

  testWidgets(
    'browse inspiration returns to existing root with local draft attached, '
    'and switches the shell to the Home tab that holds the composer',
    (tester) async {
      final reads = ReadApi();
      final writes = WriteApi();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(TestAuth.new),
            playlistApiProvider.overrideWithValue(reads),
            playlistContextApiProvider.overrideWithValue(writes),
          ],
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return Scaffold(
                  body: Column(
                    children: [
                      Text(
                        ref.watch(newMixInspirationProvider)?.playlist.id ??
                            'No attachment',
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const PlaylistDetailScreen(playlistId: 'p'),
                          ),
                        ),
                        child: const Text('Browse'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      container.read(selectedTabProvider.notifier).selectTab(AppTab.library);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make a mix inspired by this'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDetailScreen), findsNothing);
      expect(find.text('p'), findsOneWidget);
      expect(writes.writes, 0);
      // The composer that takes the attachment is Home's.
      expect(container.read(selectedTabProvider), AppTab.home.index);
    },
  );

  testWidgets('header carries the title, the art, the meta and the tape action', (
    tester,
  ) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: summary(),
      entries: [entry(0, 'After the Last Train')],
    );
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    // The playlist name is the large title, not a generic 'Playlist'.
    expect(find.text('Night'), findsWidgets);
    expect(find.text('Playlist'), findsNothing);
    expect(find.text('2 songs · Imported playlist'), findsOneWidget);
    final art = tester.widget<SquareArt>(
      find.byKey(PlaylistDetailScreen.headerArtKey),
    );
    expect(art.size, PlaylistDetailScreen.headerArtSize);
    expect(
      tester
          .widget<TapeButton>(find.byKey(PlaylistDetailScreen.inspireKey))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a confirmed playlist reads as chosen and offers removal', (
    tester,
  ) async {
    final reads = ReadApi();
    reads.read = () async =>
        PlaylistDetail(playlist: summary(origin: 'user_confirmed'), entries: const []);
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    final word = tester.widget<StatusWord>(find.byType(StatusWord));
    expect(word.label, 'You chose these songs');
    expect(word.kind, StatusKind.ok);
    // Back is pinned top-left, in its own cluster; only More sits opposite.
    expect(
      find.descendant(
        of: find.byKey(LargeTitleScaffold.pinnedRowKey),
        matching: find.byKey(PlaylistDetailScreen.backKey),
      ),
      findsOneWidget,
    );
    expect(find.byType(GlassButton), findsNWidgets(2));
    expect(find.text('Remove confirmation'), findsOneWidget);
    expect(find.text('I chose these songs'), findsNothing);
  });

  testWidgets('a playlist the DJ cannot count reads as neutral', (
    tester,
  ) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: summary(inLibrary: false),
      entries: const [],
    );
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    expect(find.text('Neutral in your taste'), findsOneWidget);
    expect(
      tester.widget<StatusWord>(find.byType(StatusWord)).kind,
      StatusKind.muted,
    );
    expect(find.text('I chose these songs'), findsNothing);
    expect(find.text('Remove confirmation'), findsNothing);
  });

  testWidgets('an unknown confirmation asks for a reload before any change', (
    tester,
  ) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: const PlaylistSummary(
        id: 'p',
        name: 'Night',
        kind: 'user',
        entryCount: 2,
        inLibrary: true,
        capability: 'copy_only',
        origin: 'unknown',
        originKnown: false,
      ),
      entries: const [],
    );
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    expect(
      find.text(
        'Playlist confirmation is unavailable. Reload before changing it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reload confirmation'), findsOneWidget);
    expect(find.text('I chose these songs'), findsNothing);
  });

  testWidgets('track rows are flush, numbered, and name what is unmatched', (
    tester,
  ) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: summary(),
      entries: [
        entry(0, 'Window Seat'),
        entry(1, 'Window Seat'),
        entry(2, 'Home recording 7', resolved: false),
      ],
    );
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    expect(find.byType(FlushRow), findsNWidgets(3));
    expect(find.text('Window Seat'), findsNWidgets(2));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Local or unmatched'), findsOneWidget);
    final art = tester.widget<SquareArt>(
      find.descendant(
        of: find.byType(FlushRow).first,
        matching: find.byType(SquareArt),
      ),
    );
    expect(art.size, PlaylistDetailScreen.rowArtSize);
  });

  testWidgets('Load more songs appends the next page and then retires', (
    tester,
  ) async {
    final reads = ReadApi();
    var page = 0;
    reads.read = () async {
      final first = page == 0;
      page++;
      return PlaylistDetail(
        playlist: summary(),
        entries: first
            ? [entry(0, 'Window Seat')]
            : [entry(1, 'After the Last Train')],
        nextEntryCursor: first ? 'next' : null,
      );
    };
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    final loadMore = find.byKey(PlaylistDetailScreen.loadMoreKey);
    expect(loadMore, findsOneWidget);
    expect(tester.widget<TextAction>(loadMore).label, 'Load more songs');
    await tester.tap(loadMore);
    await tester.pumpAndSettle();

    expect(find.text('After the Last Train'), findsOneWidget);
    expect(find.byKey(PlaylistDetailScreen.loadMoreKey), findsNothing);
  });

  testWidgets('More holds the private draft entry', (tester) async {
    final reads = ReadApi();
    reads.read = () async =>
        PlaylistDetail(playlist: summary(), entries: const []);
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    expect(find.text('Edit with the DJ'), findsNothing);
    await tester.tap(find.byKey(PlaylistDetailScreen.moreKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-with-dj')), findsOneWidget);
    expect(find.text('Edit with the DJ'), findsOneWidget);
    expect(find.text(PlaylistDetailScreen.draftPromise), findsOneWidget);
  });

  testWidgets('loading keeps the chrome and shows skeleton rows', (
    tester,
  ) async {
    final reads = ReadApi();
    final completer = <PlaylistDetail>[];
    reads.read = () async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      completer.add(PlaylistDetail(playlist: summary(), entries: const []));
      return completer.last;
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(TestAuth.new),
          playlistApiProvider.overrideWithValue(reads),
          playlistContextApiProvider.overrideWithValue(WriteApi()),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const PlaylistDetailScreen(playlistId: 'p'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(PlaylistDetailScreen.skeletonRowKey(0)), findsOneWidget);
    expect(find.byKey(PlaylistDetailScreen.moreKey), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(PlaylistDetailScreen.skeletonRowKey(0)), findsNothing);
  });

  testWidgets('a failed load keeps its copy and offers the tape retry', (
    tester,
  ) async {
    final reads = ReadApi();
    var attempts = 0;
    reads.read = () async {
      attempts++;
      if (attempts == 1) throw StateError('offline');
      return PlaylistDetail(playlist: summary(), entries: const []);
    };
    await pumpDetail(tester, reads: reads, writes: WriteApi());

    expect(find.text("Couldn't load this playlist."), findsOneWidget);
    expect(find.byType(TapeButton), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load this playlist."), findsNothing);
  });

  testWidgets('dark renders the same states', (tester) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: summary(origin: 'user_confirmed'),
      entries: [entry(0, 'Window Seat')],
    );
    await pumpDetail(
      tester,
      reads: reads,
      writes: WriteApi(),
      brightness: Brightness.dark,
    );

    expect(find.text('You chose these songs'), findsOneWidget);
    expect(find.text('Window Seat'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% text at 320 pt lays out without overflow', (tester) async {
    final reads = ReadApi();
    reads.read = () async => PlaylistDetail(
      playlist: summary(),
      entries: [entry(0, 'Window Seat'), entry(1, 'Home tape', resolved: false)],
      nextEntryCursor: 'next',
    );
    await pumpDetail(
      tester,
      reads: reads,
      writes: WriteApi(),
      textScale: 2,
      size: const Size(320, 800),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Make a mix inspired by this'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(PlaylistDetailScreen.loadMoreKey),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(PlaylistDetailScreen.loadMoreKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
