import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_edit_api.dart';
import 'package:mixtape/data/playlists/playlist_edit_models.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/data/musickit/playlist_apply_bridge.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/screens/playlist_browser_screen.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import 'package:mixtape/presentation/screens/playlist_edit_screen.dart';

class TestAuthNotifier extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

class FakePlaylistApi implements PlaylistApi {
  FakePlaylistApi({required this.page, required this.detail});

  final PlaylistPage page;
  final PlaylistDetail detail;

  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async => page;

  @override
  Future<PlaylistDetail> get(
    String id, {
    int entryLimit = 200,
    String? entryCursor,
  }) async => detail;
}

class FakePlaylistEditApi implements PlaylistEditApi {
  FakePlaylistEditApi({PlaylistEditView? view, this.messages = const []})
    : view = view ?? _editView();

  PlaylistEditView view;
  List<PlaylistEditMessage> messages;
  Object? sendError;
  int starts = 0;
  int prepares = 0;
  int confirms = 0;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<PlaylistEditView> createOrResume(String playlistId) async {
    starts++;
    return view;
  }

  @override
  Future<PlaylistEditThread> getThread(String draftId) async =>
      PlaylistEditThread(
        draft: view.draft,
        entries: view.entries,
        diff: view.diff,
        review: view.review,
        capability: view.capability,
        messages: messages,
      );

  @override
  Future<PlaylistEditTurnResult> sendMessage(
    String draftId,
    String content,
    int expectedVersion,
  ) async => throw sendError ?? UnimplementedError();

  @override
  Future<PlaylistApplyPlan> prepareApply(
    String draftId, {
    required int expectedVersion,
    required String currentSourceFingerprint,
  }) async {
    prepares++;
    return PlaylistApplyPlan(
      operationId: '00000000-0000-4000-8000-000000000060',
      mode: 'revised_copy',
      draftVersion: expectedVersion,
      expiresAt: DateTime(2026, 9, 6, 12, 10),
      name: 'Night Bus Notes (mixtape revision)',
      description: 'revised with mixtape',
      appleCatalogIds: const ['apple-1', 'apple-2'],
      desiredFingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      sourceWillRemainUntouched: true,
    );
  }

  @override
  Future<PlaylistApplyConfirmation> confirmApply(
    String draftId, {
    required String operationId,
    required int expectedVersion,
    required String applePlaylistLibraryId,
    required String resultingFingerprint,
  }) async {
    confirms++;
    return PlaylistApplyConfirmation(
      draftId: draftId,
      status: 'applied',
      mode: 'revised_copy',
      applePlaylistLibraryId: applePlaylistLibraryId,
      resultingFingerprint: resultingFingerprint,
      sourceWillRemainUntouched: true,
    );
  }

  @override
  void close() {}
}

class FakePlaylistApplyBridge implements PlaylistApplyBridge {
  FakePlaylistApplyBridge({this.outcome = PlaylistApplyOutcome.success});

  final PlaylistApplyOutcome outcome;
  int creates = 0;
  int fingerprints = 0;

  @override
  Future<String> fetchPlaylistFingerprint(String appleLibraryId) async {
    fingerprints++;
    return 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  }

  @override
  Future<PlaylistApplyReceipt> createRevisedPlaylist({
    required String operationId,
    required String name,
    required String description,
    required List<String> appleCatalogIds,
    required String desiredFingerprint,
  }) async {
    creates++;
    return PlaylistApplyReceipt(
      operationId: operationId,
      outcome: outcome,
      appleLibraryId: 'p.revised',
      added: outcome == PlaylistApplyOutcome.success
          ? appleCatalogIds.length
          : 1,
      failed: outcome == PlaylistApplyOutcome.partial ? 1 : 0,
      resultingFingerprint: outcome == PlaylistApplyOutcome.unknown
          ? null
          : outcome == PlaylistApplyOutcome.success
          ? desiredFingerprint
          : 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    );
  }
}

PlaylistSummary _summary({String source = 'apple', int count = 4}) =>
    PlaylistSummary(
      id: '00000000-0000-4000-8000-000000000001',
      source: source,
      name: 'Night Bus Notes',
      kind: 'user',
      origin: 'user_confirmed',
      entryCount: count,
      knownDurationMs: 540000,
      inLibrary: true,
      capability: source == 'apple' ? 'append_only' : 'copy_only',
    );

PlaylistEntry _entry(int position, String title, {bool resolved = true}) =>
    PlaylistEntry(
      id: 'entry-$position',
      position: position,
      trackId: resolved ? 'track-$position' : null,
      appleCatalogId: resolved ? 'apple-$position' : null,
      title: title,
      artist: resolved ? 'Artist' : 'Local file',
      durationMs: resolved ? 180000 : null,
      resolved: resolved,
    );

Map<String, dynamic> _reviewEntry(String key, int position, String title) => {
  'entryKey': key,
  'position': position,
  'title': title,
  'artist': 'Daniel Caesar',
  'album': null,
  'durationMs': 200000,
  'artworkUrlTemplate': null,
  'artworkWidth': null,
  'artworkHeight': null,
  'artworkBgColor': '544451',
  'resolved': true,
};

PlaylistEditView _editView({
  String source = 'apple',
  bool changed = true,
}) => PlaylistEditView.fromJson({
  'draft': {
    'id': '00000000-0000-4000-8000-000000000010',
    'sourcePlaylistId': '00000000-0000-4000-8000-000000000001',
    'sourceProviderLibraryId': source == 'apple'
        ? 'p.source'
        : 'spotify-source',
    'status': 'active',
    'version': changed ? 1 : 0,
    'baseSourceFingerprint':
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'baseName': 'Night Bus Notes',
    'sourceType': source,
    'createdAt': '2026-09-05T10:00:00.000Z',
    'updatedAt': '2026-09-05T11:00:00.000Z',
  },
  'entries': [
    {
      'entryKey': '00000000-0000-4000-8000-000000000020',
      'origin': 'source',
      'sourceEntryId': 'source-1',
      'trackId': 'track-1',
      'appleLibraryTrackId': null,
      'appleCatalogId': 'apple-1',
      'spotifyId': null,
      'title': 'After the Last Train',
      'artist': 'North Parade',
      'album': null,
      'durationMs': 200000,
      'artworkUrlTemplate': null,
      'artworkWidth': null,
      'artworkHeight': null,
      'artworkBgColor': null,
      'position': 0,
      'resolved': true,
    },
    {
      'entryKey': '00000000-0000-4000-8000-000000000021',
      'origin': 'catalog_addition',
      'sourceEntryId': null,
      'trackId': 'track-2',
      'appleLibraryTrackId': null,
      'appleCatalogId': 'apple-2',
      'spotifyId': null,
      'title': 'Streetcar',
      'artist': 'Daniel Caesar',
      'album': null,
      'durationMs': 200000,
      'artworkUrlTemplate': null,
      'artworkWidth': null,
      'artworkHeight': null,
      'artworkBgColor': '544451',
      'position': 1,
      'resolved': true,
    },
  ],
  'diff': {
    'added': changed
        ? [
            {
              'entryKey': '00000000-0000-4000-8000-000000000021',
              'toPosition': 1,
            },
          ]
        : [],
    'removed': [],
    'moved': [],
    'replaced': [],
  },
  'review': {
    'added': changed
        ? [_reviewEntry('00000000-0000-4000-8000-000000000021', 1, 'Streetcar')]
        : [],
    'removed': [],
    'moved': [],
    'replaced': [],
  },
  'capability': {
    'possibleModes': ['revised_copy'],
    'sourceWillRemainUntouched': true,
    'applyAvailable': changed,
  },
});

PlaylistEditMessage _message(String role, String content, {int? version}) =>
    PlaylistEditMessage(
      id: '$role-$content',
      role: role,
      content: content,
      seq: role == 'user' ? 1 : 2,
      createdAt: DateTime(2026, 9, 5),
      draftVersion: version,
    );

ProviderContainer _container(
  FakePlaylistApi playlists,
  FakePlaylistEditApi edit, {
  FakePlaylistApplyBridge? apply,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(TestAuthNotifier.new),
      playlistApiProvider.overrideWithValue(playlists),
      playlistEditApiProvider.overrideWithValue(edit),
      playlistApplyBridgeProvider.overrideWithValue(
        apply ?? FakePlaylistApplyBridge(),
      ),
      playlistApplySupportedProvider.overrideWithValue(true),
      playlistRefreshAfterApplyProvider.overrideWithValue(() async {}),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: ThemeData(useMaterial3: true), home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('playlist collection is browseable with source and count', (
    tester,
  ) async {
    final summary = _summary();
    final playlists = FakePlaylistApi(
      page: PlaylistPage(playlists: [summary]),
      detail: PlaylistDetail(playlist: summary, entries: const []),
    );
    final edit = FakePlaylistEditApi()..view = _editView();
    await _pump(
      tester,
      _container(playlists, edit),
      const PlaylistBrowserScreen(),
    );

    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Night Bus Notes'), findsOneWidget);
    expect(find.textContaining('Apple Music'), findsOneWidget);
    expect(find.textContaining('4 songs'), findsOneWidget);
    expect(
      find.byKey(
        const Key('playlist-row-00000000-0000-4000-8000-000000000001'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'detail preserves duplicate and unresolved occurrences and starts a draft',
    (tester) async {
      final summary = _summary(count: 3);
      final playlists = FakePlaylistApi(
        page: PlaylistPage(playlists: [summary]),
        detail: PlaylistDetail(
          playlist: summary,
          entries: [
            _entry(0, 'Window Seat'),
            _entry(1, 'Window Seat'),
            _entry(2, 'Home recording 7', resolved: false),
          ],
        ),
      );
      final edit = FakePlaylistEditApi()
        ..view = _editView(changed: false)
        ..messages = [
          _message('dj', 'Tell me what you want to change.', version: 0),
        ];
      await _pump(
        tester,
        _container(playlists, edit),
        const PlaylistDetailScreen(
          playlistId: '00000000-0000-4000-8000-000000000001',
        ),
      );

      expect(find.text('Window Seat'), findsNWidgets(2));
      expect(find.text('Local or unmatched'), findsOneWidget);
      expect(find.byKey(const Key('edit-with-dj')), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-with-dj')));
      await tester.pumpAndSettle();

      expect(edit.starts, 1);
      expect(find.byType(PlaylistEditScreen), findsOneWidget);
      expect(find.text('Tell me what you want to change.'), findsOneWidget);
    },
  );

  testWidgets(
    'conversation keeps source and draft separate and opens exact review',
    (tester) async {
      final summary = _summary();
      final playlists = FakePlaylistApi(
        page: PlaylistPage(playlists: [summary]),
        detail: PlaylistDetail(playlist: summary, entries: const []),
      );
      final edit = FakePlaylistEditApi()
        ..view = _editView()
        ..messages = [
          _message('user', 'Add a couple more Daniel Caesar songs.'),
          _message('dj', 'I placed them where they fit best.', version: 1),
        ];
      await _pump(
        tester,
        _container(playlists, edit),
        const PlaylistEditScreen(
          draftId: '00000000-0000-4000-8000-000000000010',
        ),
      );

      expect(find.text('Source'), findsOneWidget);
      expect(find.text('Private draft'), findsOneWidget);
      expect(find.text('1 change'), findsWidgets);
      expect(find.text('I placed them where they fit best.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-draft')));
      await tester.pumpAndSettle();

      expect(find.text('Create a revised copy'), findsOneWidget);
      expect(
        find.textContaining('leave “Night Bus Notes” untouched'),
        findsOneWidget,
      );
      expect(find.text('Streetcar'), findsOneWidget);
      expect(
        find.textContaining('After “After the Last Train”'),
        findsOneWidget,
      );
      final apply = tester.widget<FilledButton>(
        find.byKey(const Key('apply-draft')),
      );
      expect(apply.onPressed, isNotNull);
      expect(find.text('Create revised playlist'), findsOneWidget);
    },
  );

  testWidgets('exact native success confirms and shows the created copy', (
    tester,
  ) async {
    final summary = _summary();
    final playlists = FakePlaylistApi(
      page: PlaylistPage(playlists: [summary]),
      detail: PlaylistDetail(playlist: summary, entries: const []),
    );
    final edit = FakePlaylistEditApi();
    final apply = FakePlaylistApplyBridge();
    await _pump(
      tester,
      _container(playlists, edit, apply: apply),
      const PlaylistEditScreen(draftId: '00000000-0000-4000-8000-000000000010'),
    );

    await tester.tap(find.byKey(const Key('review-draft')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-draft')));
    await tester.pumpAndSettle();

    expect(apply.fingerprints, 1);
    expect(apply.creates, 1);
    expect(edit.prepares, 1);
    expect(edit.confirms, 1);
    expect(find.text('Created in Apple Music'), findsWidgets);
    expect(find.textContaining('source is untouched'), findsOneWidget);
  });

  testWidgets(
    'unknown native result never confirms and offers reconciliation',
    (tester) async {
      final summary = _summary();
      final playlists = FakePlaylistApi(
        page: PlaylistPage(playlists: [summary]),
        detail: PlaylistDetail(playlist: summary, entries: const []),
      );
      final edit = FakePlaylistEditApi();
      final apply = FakePlaylistApplyBridge(
        outcome: PlaylistApplyOutcome.unknown,
      );
      await _pump(
        tester,
        _container(playlists, edit, apply: apply),
        const PlaylistEditScreen(
          draftId: '00000000-0000-4000-8000-000000000010',
        ),
      );

      await tester.tap(find.byKey(const Key('review-draft')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apply-draft')));
      await tester.pumpAndSettle();

      expect(edit.confirms, 0);
      expect(find.text('Result needs checking'), findsOneWidget);
      expect(find.text('Reconcile result'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('playlist-edit-composer')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets('Spotify draft never offers write-back to Spotify', (
    tester,
  ) async {
    final summary = _summary(source: 'spotify_export');
    final playlists = FakePlaylistApi(
      page: PlaylistPage(playlists: [summary]),
      detail: PlaylistDetail(playlist: summary, entries: const []),
    );
    final edit = FakePlaylistEditApi()
      ..view = _editView(source: 'spotify_export')
      ..messages = [_message('dj', 'Your private draft is ready.', version: 1)];
    await _pump(
      tester,
      _container(playlists, edit),
      const PlaylistEditScreen(draftId: '00000000-0000-4000-8000-000000000010'),
    );

    await tester.tap(find.byKey(const Key('review-draft')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Spotify export stays untouched'),
      findsOneWidget,
    );
    expect(find.text('Update Spotify playlist'), findsNothing);
  });

  testWidgets('a failed DJ turn offers the exact request again', (
    tester,
  ) async {
    final summary = _summary();
    final playlists = FakePlaylistApi(
      page: PlaylistPage(playlists: [summary]),
      detail: PlaylistDetail(playlist: summary, entries: const []),
    );
    final edit = FakePlaylistEditApi(view: _editView(changed: false))
      ..sendError = NetworkException(StateError('offline'));
    final container = _container(playlists, edit);
    await _pump(
      tester,
      container,
      const PlaylistEditScreen(draftId: '00000000-0000-4000-8000-000000000010'),
    );

    await tester.enterText(
      find.byKey(const Key('playlist-edit-composer')),
      'move the closer later',
    );
    await tester.tap(find.byKey(const Key('playlist-edit-send')));
    await tester.pumpAndSettle();
    final thread = container
        .read(
          playlistEditThreadProvider('00000000-0000-4000-8000-000000000010'),
        )
        .requireValue;
    expect(thread.messages.last.retryContent, 'move the closer later');
    await tester.drag(find.byType(ListView), const Offset(0, -280));
    await tester.pumpAndSettle();

    expect(find.text('Try that request again'), findsOneWidget);
  });
}
