// The Mixes tab (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 2.3): the session list moved off Home onto its own
// tab, with the native segmented control beside the large title.
//
// The fakes mirror home_screen_test.dart's, so the list cases that move here
// in task 2.2 read the same way they did on Home.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/home_mode_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart'
    show QueueScreen;
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/listen_later_row.dart';
import 'package:mixtape/presentation/widgets/mix_home_row.dart';

/// Implements DjApi's public surface (not `extends`, since DjApi's constructor
/// builds a real ApiClient); only the session-list calls are wired.
class FakeDjApi implements DjApi {
  Future<List<DjSession>> Function()? onListSessions;
  Future<DjSession> Function(String id, String status)? onSetStatus;
  Future<DjSession> Function(String id, String title)? onRenameSession;
  Future<SessionDetail> Function(String id)? onGetSession;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjSession>> listSessions() {
    final impl = onListSessions;
    if (impl == null) throw UnimplementedError('onListSessions not wired');
    return impl();
  }

  @override
  Future<DjSession> setStatus(String id, String status) {
    final impl = onSetStatus;
    if (impl == null) throw UnimplementedError('onSetStatus not wired');
    return impl(id, status);
  }

  @override
  Future<DjSession> setCaseColor(String id, String caseColor) =>
      throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) {
    final impl = onRenameSession;
    if (impl == null) throw UnimplementedError('onRenameSession not wired');
    return impl(id, title);
  }

  @override
  Future<SessionDetail> getSession(String id) {
    final impl = onGetSession;
    if (impl == null) throw UnimplementedError('onGetSession not wired');
    return impl(id);
  }

  @override
  Future<AlbumPickState> choosePick(
    String sessionId, {
    required String albumId,
    int? expectedVersion,
  }) => throw UnimplementedError();

  @override
  Future<AlbumPickState> goBackToPick(
    String sessionId, {
    required int version,
    int? expectedVersion,
  }) => throw UnimplementedError();

  Future<List<ListenLaterEntry>> Function()? onListListenLater;
  Future<ListenLaterEntry> Function(String albumId)? onSaveForLater;
  Future<void> Function(String albumId)? onUnsaveForLater;
  Future<ListenLaterEntry> Function(String albumId)? onMarkListened;

  @override
  Future<List<ListenLaterEntry>> listListenLater() {
    final impl = onListListenLater;
    if (impl == null) throw UnimplementedError('onListListenLater not wired');
    return impl();
  }

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) {
    final impl = onSaveForLater;
    if (impl == null) throw UnimplementedError('onSaveForLater not wired');
    return impl(albumId);
  }

  @override
  Future<void> unsaveForLater(String albumId) {
    final impl = onUnsaveForLater;
    if (impl == null) throw UnimplementedError('onUnsaveForLater not wired');
    return impl(albumId);
  }

  @override
  Future<ListenLaterEntry> markListened(String albumId) {
    final impl = onMarkListened;
    if (impl == null) throw UnimplementedError('onMarkListened not wired');
    return impl(albumId);
  }

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) =>
      throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) => throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) =>
      throw UnimplementedError();

  @override
  Future<List<DjMemory>> listMemories() => throw UnimplementedError();

  @override
  Future<void> deleteMemory(String id) => throw UnimplementedError();

  @override
  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) async {}

  @override
  void close() {}
}

/// authProvider settled at session — no keychain restore, no async auth
/// transition mid-test (home_screen_test.dart's pattern).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

DjSession _session({
  String id = 's1',
  String title = 'Test Session',
  String status = 'active',
  int queueVersion = 1,
  DateTime? updatedAt,
}) => DjSession(
  id: id,
  title: title,
  status: status,
  queueVersion: queueVersion,
  updatedAt: updatedAt ?? DateTime.now(),
);

ListenLaterEntry _entry({
  String id = 'a1',
  String title = 'Low Tide Hours',
  String artist = 'Mara Ilesanmi',
  String type = 'album',
  int? releaseYear = 2019,
  String? sessionId = 's1',
  DateTime? savedAt,
  DateTime? listenedAt,
  String? reason = 'A live record, warm and unhurried.',
}) => ListenLaterEntry(
  id: id,
  title: title,
  artist: artist,
  type: type,
  releaseYear: releaseYear,
  sessionId: sessionId,
  savedAt: savedAt ?? DateTime(2026, 10, 1),
  listenedAt: listenedAt,
  reason: reason,
);

ProviderContainer _makeContainer(FakeDjApi api, {bool albums = false}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
      albumPicksEnabledProvider.overrideWithValue(albums),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  VoidCallback? onStartMix,
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
            child: MixesScreen(onStartMix: onStartMix),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void main() {
  group('chrome', () {
    testWidgets('title and segmented control are up while sessions load, '
        'over three skeleton rows', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<List<DjSession>>();
      final api = FakeDjApi()..onListSessions = () => gate.future;
      await _pump(tester, _makeContainer(api), settle: false);
      await tester.pump();

      expect(find.text('Mixes'), findsOneWidget);
      expect(find.byType(SegmentedToggle<MixesSegment>), findsOneWidget);
      expect(find.byKey(const Key('active-mixes')), findsOneWidget);
      expect(find.byKey(const Key('archived-mixes')), findsOneWidget);
      for (var index = 0; index < MixesScreen.skeletonRows; index++) {
        expect(find.byKey(MixesScreen.skeletonRowKey(index)), findsOneWidget);
      }
      expect(find.bySemanticsLabel(MixesScreen.loadingLabel), findsOneWidget);

      gate.complete([_session(title: 'Landed')]);
      await tester.pumpAndSettle();
      expect(find.byKey(MixesScreen.skeletonRowKey(0)), findsNothing);
      expect(find.text('Landed'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the segments carry their selected state', (tester) async {
      final handle = tester.ensureSemantics();
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Active One')];
      await _pump(tester, _makeContainer(api));

      SemanticsData data(String key) =>
          tester.getSemantics(find.byKey(Key(key))).getSemanticsData();
      expect(data('active-mixes').flagsCollection.isSelected, isTrue);
      expect(data('archived-mixes').flagsCollection.isSelected, isFalse);

      await tester.tap(find.byKey(const Key('archived-mixes')));
      await tester.pumpAndSettle();
      expect(data('active-mixes').flagsCollection.isSelected, isFalse);
      expect(data('archived-mixes').flagsCollection.isSelected, isTrue);
      handle.dispose();
    });

    testWidgets('dark theme renders the list', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Night bus notes')];
      await _pump(tester, _makeContainer(api), brightness: Brightness.dark);
      expect(find.text('Night bus notes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('200% text at 320 width does not overflow', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(title: 'Something like my Late nights playlist, but slower'),
          _session(id: 's2', title: 'Deadline sprint, no lyrics'),
        ];
      await _pump(
        tester,
        _makeContainer(api),
        size: const Size(320, 800),
        textScale: 2,
      );
      expect(
        find.text('Something like my Late nights playlist, but slower'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // The second row is below the fold at this scale; scrolling to it also
      // exercises the title collapse and the hairline between rows.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('Deadline sprint, no lyrics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('list', () {
    testWidgets('active rows carry a cassette; the control switches to '
        'archived and back', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(title: 'Active One'),
          _session(id: 's2', title: 'Old One', status: 'archived'),
        ];
      await _pump(tester, _makeContainer(api));

      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(MixHomeRow),
          matching: find.byType(CassetteTile),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('archived-mixes')));
      await tester.pumpAndSettle();
      expect(find.text('Active One'), findsNothing);
      expect(find.text('Old One'), findsOneWidget);

      await tester.tap(find.byKey(const Key('active-mixes')));
      await tester.pumpAndSettle();
      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
    });

    testWidgets('tapping a row pushes its conversation', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Sunset Drive')];
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.text('Sunset Drive'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionId,
        's1',
      );
    });

    testWidgets('swipe left archives with Undo, and Undo restores the row', (
      tester,
    ) async {
      var status = 'active';
      final writes = <String>[];
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(title: 'Sunset Drive', status: status),
      ];
      api.onSetStatus = (id, next) async {
        expect(id, 's1');
        writes.add(next);
        status = next;
        return _session(title: 'Sunset Drive', status: status);
      };
      await _pump(tester, _makeContainer(api));

      await tester.drag(find.byType(Dismissible), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-s1')), findsNothing);
      expect(find.text('Mix archived'), findsOneWidget);

      // The dock floats over the bottom of the screen, so the Undo SnackBar
      // has to sit above it to be reachable at all. The SnackBar widget's own
      // rect includes its margin, so measure the painted bar inside it.
      final bar = find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first;
      expect(
        tester.getRect(bar).bottom,
        lessThanOrEqualTo(844 - MixesScreen.defaultBottomInset + 0.5),
      );

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(writes, ['archived', 'active']);
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
    });

    testWidgets('archive failure keeps the row and says so', (tester) async {
      var writes = 0;
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Sunset Drive')];
      api.onSetStatus = (id, status) async {
        writes++;
        throw ApiException(500, 'boom');
      };
      await _pump(tester, _makeContainer(api));

      await tester.drag(find.byType(Dismissible), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
      expect(find.text("couldn't archive — try again"), findsOneWidget);
      expect(writes, 1);
    });

    testWidgets('restore failure keeps the row in archived', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(title: 'Old One', status: 'archived'),
      ];
      api.onSetStatus = (id, status) async => throw ApiException(500, 'boom');
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(const Key('archived-mixes')));
      await tester.pumpAndSettle();

      // Archived rows do not swipe; the long-press menu restores them.
      await tester.longPress(find.text('Old One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
      expect(find.text("couldn't unarchive — try again"), findsOneWidget);
    });

    testWidgets('the long-press menu offers Rename and Version history', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Sunset Drive')];
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const ValueKey('mix-actions-s1')), findsNothing);
      await tester.longPress(find.text('Sunset Drive'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Version history'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
    });

    testWidgets('returning from a conversation refreshes the list', (
      tester,
    ) async {
      var reads = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        reads++;
        return [_session(title: 'Sunset Drive')];
      };
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));
      final before = reads;

      await tester.tap(find.text('Sunset Drive'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-back')));
      await tester.pumpAndSettle();
      expect(reads, greaterThan(before));
    });
  });

  group('error and empty', () {
    testWidgets('nothing to show offers Try again, which recovers the list', (
      tester,
    ) async {
      var shouldFail = true;
      final api = FakeDjApi()
        ..onListSessions = () async {
          if (shouldFail) throw ApiException(500, 'listSessions boom');
          return [_session(title: 'Recovered Session')];
        };
      await _pump(tester, _makeContainer(api));

      expect(find.text("Couldn’t load your mixes"), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('sessions-retry')),
          matching: find.byType(OutlinedButton),
        ),
        findsOneWidget,
      );

      shouldFail = false;
      await tester.tap(find.byKey(const Key('sessions-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions-retry')), findsNothing);
      expect(find.text('Recovered Session'), findsOneWidget);
    });

    testWidgets('a failed pull-to-refresh keeps the list and says so', (
      tester,
    ) async {
      var calls = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        calls += 1;
        if (calls > 1) throw NetworkException('refresh boom');
        return [_session(title: 'Test Session')];
      };
      await _pump(tester, _makeContainer(api));
      expect(find.text('Test Session'), findsOneWidget);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(calls, 2, reason: 'the pull must actually refetch');
      expect(find.text('Test Session'), findsOneWidget);
      expect(find.text("Couldn’t refresh your mixes."), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsNothing);
    });

    testWidgets('pull-to-refresh works from the empty state', (tester) async {
      var calls = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        calls += 1;
        return calls > 1 ? [_session(title: 'Fresh Session')] : <DjSession>[];
      };
      await _pump(tester, _makeContainer(api));
      expect(find.byKey(const Key('sessions-empty')), findsOneWidget);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(calls, 2, reason: 'the empty state must still pull to refresh');
      expect(find.text('Fresh Session'), findsOneWidget);
    });

    testWidgets('empty active carries the cassette and starts a mix', (
      tester,
    ) async {
      var starts = 0;
      final api = FakeDjApi()..onListSessions = () async => <DjSession>[];
      await _pump(tester, _makeContainer(api), onStartMix: () => starts++);

      expect(find.text('No tapes yet'), findsOneWidget);
      expect(
        find.text('Your first mix will appear here. Start one from Home.'),
        findsOneWidget,
      );
      expect(find.byType(CassetteTile), findsOneWidget);

      await tester.tap(find.text('Start a mix'));
      await tester.pumpAndSettle();
      expect(starts, 1);

      await tester.tap(find.byKey(const Key('archived-mixes')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing archived'), findsOneWidget);
      expect(find.text('Swipe a mix left to archive it.'), findsOneWidget);
      expect(find.text('Start a mix'), findsNothing);
    });
  });

  group('listen later', () {
    final shelf = [
      _entry(),
      _entry(
        id: 'a2',
        title: 'Kitchen Radio Sessions',
        artist: 'Odun & the Weather',
        type: 'live',
        releaseYear: 2021,
        sessionId: 's2',
        savedAt: DateTime(2026, 9, 20),
      ),
      _entry(
        id: 'a3',
        title: 'Nightshift Radio',
        artist: 'The Quiet Parade',
        type: 'ep',
        sessionId: 's3',
        listenedAt: DateTime(2026, 10, 12),
      ),
    ];

    FakeDjApi albumApi({List<ListenLaterEntry>? entries}) {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(title: 'Mara, but newer'),
        _session(id: 's2', title: 'Something new, warm'),
      ];
      api.onListListenLater = () async => entries ?? shelf;
      return api;
    }

    Future<void> openShelf(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('listen-later-mixes')));
      await tester.pumpAndSettle();
    }

    testWidgets('three segments with album picks on, two otherwise', (
      tester,
    ) async {
      await _pump(tester, _makeContainer(albumApi(), albums: true));
      expect(find.byKey(const Key('listen-later-mixes')), findsOneWidget);
      expect(find.text('Listen later'), findsOneWidget);
    });

    testWidgets('albums off shows Active and Archived only', (tester) async {
      await _pump(tester, _makeContainer(albumApi()));
      expect(find.byKey(const Key('active-mixes')), findsOneWidget);
      expect(find.byKey(const Key('archived-mixes')), findsOneWidget);
      expect(find.byKey(const Key('listen-later-mixes')), findsNothing);
    });

    // The test font draws every glyph a full em wide, about twice SF's
    // width for these words, so a 0.45 text scale stands in for 1x on a
    // device: three segments then need about 302 pt and the title about 63.
    Future<(Rect, Rect)> layoutAt(WidgetTester tester, double width) async {
      await _pump(
        tester,
        _makeContainer(albumApi(), albums: true),
        size: Size(width, 800),
        textScale: 0.45,
      );
      expect(tester.takeException(), isNull);
      return (
        tester.getRect(find.text('Mixes')),
        tester.getRect(find.byType(SegmentedToggle<MixesSegment>)),
      );
    }

    testWidgets('at 390 pt the three segments drop below the title, leading', (
      tester,
    ) async {
      final (title, control) = await layoutAt(tester, 390);
      expect(control.top, greaterThanOrEqualTo(title.bottom));
      expect(control.left, 20);
      expect(control.right, lessThanOrEqualTo(370));
      expect(
        tester
            .widget<LargeTitleScaffold>(find.byType(LargeTitleScaffold))
            .accessoriesBelowTitle,
        isTrue,
      );
    });

    testWidgets('at 430 pt the three segments sit beside the title', (
      tester,
    ) async {
      final (title, control) = await layoutAt(tester, 430);
      expect(title.right, lessThanOrEqualTo(control.left));
      expect(control.right, closeTo(410, 0.5));
      expect(control.bottom, closeTo(title.bottom, 12));
    });

    testWidgets('below the title, the control may take the content width', (
      tester,
    ) async {
      await _pump(
        tester,
        _makeContainer(albumApi(), albums: true),
        size: const Size(390, 800),
      );
      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(SegmentedToggle<MixesSegment>),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxWidth, 350);
    });

    testWidgets('two segments keep the title row as it was', (tester) async {
      await _pump(tester, _makeContainer(albumApi()));
      expect(
        tester
            .widget<LargeTitleScaffold>(find.byType(LargeTitleScaffold))
            .accessoriesBelowTitle,
        isFalse,
      );
      final title = tester.getRect(find.text('Mixes'));
      final control = tester.getRect(
        find.byType(SegmentedToggle<MixesSegment>),
      );
      expect(title.right, lessThanOrEqualTo(control.left));
      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(SegmentedToggle<MixesSegment>),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxWidth, 240);
    });

    testWidgets('the three segments fit a 320 pt screen at 200% text', (
      tester,
    ) async {
      await _pump(
        tester,
        _makeContainer(albumApi(), albums: true),
        size: const Size(320, 800),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      final control = tester.getRect(
        find.byType(SegmentedToggle<MixesSegment>),
      );
      expect(control.right, lessThanOrEqualTo(320));
    });

    testWidgets('losing the segment falls back to Active', (tester) async {
      final container = _makeContainer(albumApi(), albums: true);
      await _pump(tester, container);
      await openShelf(tester);
      expect(find.text('Low Tide Hours'), findsOneWidget);

      container.updateOverrides([
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        djApiProvider.overrideWithValue(albumApi()),
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        albumPicksEnabledProvider.overrideWithValue(false),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('listen-later-mixes')), findsNothing);
      expect(find.text('Mara, but newer'), findsOneWidget);
    });

    testWidgets('the shelf lists entries with Listened between the groups '
        'and the plum status word', (tester) async {
      await _pump(tester, _makeContainer(albumApi(), albums: true));
      await openShelf(tester);

      expect(find.text('Mara, but newer'), findsNothing);
      expect(find.text('Mara Ilesanmi · Album · 2019'), findsOneWidget);
      expect(find.text('Odun & the Weather · Live · 2021'), findsOneWidget);
      final heading = tester.getTopLeft(find.text('Listened'));
      expect(
        tester.getTopLeft(find.text('Kitchen Radio Sessions')).dy,
        lessThan(heading.dy),
      );
      expect(
        tester.getTopLeft(find.text('Nightshift Radio')).dy,
        greaterThan(heading.dy),
      );
      final word = tester.widget<StatusWord>(find.byType(StatusWord));
      expect(word.label, 'Listened 12 Oct');
      expect(word.kind, StatusKind.accent);
    });

    testWidgets('long-press expands with why, Saved from and Mark listened', (
      tester,
    ) async {
      await _pump(tester, _makeContainer(albumApi(), albums: true));
      await openShelf(tester);

      await tester.longPress(find.text('Kitchen Radio Sessions'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'A live record, warm and unhurried. '
          'Saved from "Something new, warm".',
        ),
        findsOneWidget,
      );
      expect(find.text('Mark listened'), findsOneWidget);
    });

    testWidgets('Mark listened moves the row under Listened', (tester) async {
      final api = albumApi();
      api.onMarkListened = (id) async {
        expect(id, 'a1');
        return _entry(listenedAt: DateTime(2026, 10, 20));
      };
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);

      await tester.longPress(find.text('Low Tide Hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark listened'));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Low Tide Hours')).dy,
        greaterThan(tester.getTopLeft(find.text('Listened')).dy),
      );
      expect(find.text('Listened 20 Oct'), findsOneWidget);
    });

    testWidgets('swipe left removes with the Undo toast; Undo restores', (
      tester,
    ) async {
      var saved = true;
      final writes = <String>[];
      final api = FakeDjApi();
      api.onListSessions = () async => [_session()];
      api.onListListenLater = () async => saved ? [_entry()] : [];
      api.onUnsaveForLater = (id) async {
        writes.add('unsave $id');
        saved = false;
      };
      api.onSaveForLater = (id) async {
        writes.add('save $id');
        saved = true;
        return _entry();
      };
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);

      await tester.drag(
        find.byKey(const ValueKey('listen-later-swipe-a1')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Low Tide Hours'), findsNothing);
      expect(find.text('Removed from Listen later.'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(writes, ['unsave a1', 'save a1']);
      expect(find.text('Low Tide Hours'), findsOneWidget);
    });

    testWidgets('a failed remove keeps the row and says so', (tester) async {
      final api = albumApi(entries: [_entry()])
        ..onUnsaveForLater = (id) async => throw ApiException(500, 'boom');
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);

      await tester.drag(
        find.byKey(const ValueKey('listen-later-swipe-a1')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Low Tide Hours'), findsOneWidget);
      expect(
        find.text('Couldn’t remove it from Listen later. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Removed from Listen later.'), findsNothing);
    });

    testWidgets('empty: the copy, and Find an album asks Home for Album '
        'then switches tabs', (tester) async {
      var starts = 0;
      SessionKind? requested;
      final container = _makeContainer(
        albumApi(entries: const []),
        albums: true,
      );
      await _pump(
        tester,
        container,
        onStartMix: () {
          requested = container.read(homeModeRequestProvider);
          starts++;
        },
      );
      await openShelf(tester);

      expect(find.text('Nothing saved for later'), findsOneWidget);
      expect(
        find.text('Ask for an album, then tap Listen later to keep it here.'),
        findsOneWidget,
      );
      expect(find.byType(CassetteTile), findsOneWidget);
      expect(find.byType(SegmentedToggle<MixesSegment>), findsOneWidget);

      await tester.tap(find.text('Find an album'));
      await tester.pumpAndSettle();
      expect(requested, SessionKind.album);
      expect(starts, 1);
    });

    testWidgets('tapping a row opens its album session', (tester) async {
      final api = albumApi();
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);

      await tester.tap(find.text('Kitchen Radio Sessions'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionId,
        's2',
      );
    });

    testWidgets('each row carries its rotor actions', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _makeContainer(albumApi(), albums: true));
      await openShelf(tester);

      List<String> rotor(String id) => [
        for (final actionId
            in tester
                    .getSemantics(find.byKey(ListenLaterRow.semanticsKey(id)))
                    .getSemanticsData()
                    .customSemanticsActionIds ??
                const <int>[])
          CustomSemanticsAction.getAction(actionId)!.label!,
      ];
      expect(rotor('a1'), ['Open', 'Show why', 'Mark listened', 'Remove']);
      expect(rotor('a3'), ['Open', 'Show why', 'Remove']);
      handle.dispose();
    });

    testWidgets('skeleton rows while the shelf loads', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<List<ListenLaterEntry>>();
      final api = albumApi()..onListListenLater = () => gate.future;
      await _pump(tester, _makeContainer(api, albums: true));
      await tester.tap(find.byKey(const Key('listen-later-mixes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(MixesScreen.skeletonRowKey(0)), findsOneWidget);
      expect(
        find.bySemanticsLabel(MixesScreen.listenLaterLoadingLabel),
        findsOneWidget,
      );
      gate.complete([_entry()]);
      await tester.pumpAndSettle();
      expect(find.text('Low Tide Hours'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a failed shelf read offers Try again', (tester) async {
      var fail = true;
      final api = albumApi()
        ..onListListenLater = () async {
          if (fail) throw ApiException(500, 'boom');
          return [_entry()];
        };
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);
      expect(
        find.text('Couldn’t load your Listen later shelf'),
        findsOneWidget,
      );

      fail = false;
      await tester.tap(find.byKey(const Key('listen-later-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Low Tide Hours'), findsOneWidget);
    });

    testWidgets('pull-to-refresh on the shelf refreshes it', (tester) async {
      var reads = 0;
      final api = albumApi()
        ..onListListenLater = () async {
          reads++;
          return reads > 1
              ? [_entry(), _entry(id: 'a9', title: 'Fresh')]
              : [_entry()];
        };
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);
      final before = reads;

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(reads, greaterThan(before));
      expect(find.text('Fresh'), findsOneWidget);
    });

    testWidgets('the Undo toast stays up as long as the arrangement '
        'screen\'s', (tester) async {
      final api = albumApi(entries: [_entry()])
        ..onUnsaveForLater = (id) async {};
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);
      await tester.drag(
        find.byKey(const ValueKey('listen-later-swipe-a1')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        QueueScreen.undoDuration,
      );
    });

    testWidgets('returning from an opened entry refreshes the shelf', (
      tester,
    ) async {
      var reads = 0;
      final api = albumApi()
        ..onListListenLater = () async {
          reads++;
          return [_entry()];
        }
        ..onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);
      final before = reads;

      await tester.tap(find.text('Low Tide Hours'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-back')));
      await tester.pumpAndSettle();
      expect(reads, greaterThan(before));
    });

    testWidgets('a failed pull-to-refresh keeps the shelf and says so', (
      tester,
    ) async {
      var reads = 0;
      final api = albumApi()
        ..onListListenLater = () async {
          reads++;
          if (reads > 1) throw NetworkException('refresh boom');
          return [_entry()];
        };
      await _pump(tester, _makeContainer(api, albums: true));
      await openShelf(tester);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('Low Tide Hours'), findsOneWidget);
      expect(
        find.text('Couldn’t refresh your Listen later shelf.'),
        findsOneWidget,
      );
      expect(find.text('Showing your last loaded shelf.'), findsOneWidget);
      expect(find.text('Couldn’t refresh your mixes.'), findsNothing);
    });

    testWidgets('dark theme renders the shelf', (tester) async {
      await _pump(
        tester,
        _makeContainer(albumApi(), albums: true),
        brightness: Brightness.dark,
      );
      await openShelf(tester);
      expect(find.text('Nightshift Radio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
