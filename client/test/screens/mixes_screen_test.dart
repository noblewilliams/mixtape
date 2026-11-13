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
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/home_mode_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/archived_mixes_screen.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart'
    show QueueScreen;
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/foundation/swipe_actions.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/listen_later_row.dart';
import 'package:mixtape/presentation/widgets/mix_home_row.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mixtape/presentation/screens/shared_mix_screen.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart'
    show MixMenuIcons, mixtapeMenuKey;
import 'package:mixtape/presentation/widgets/shared_mix_row.dart';

/// Implements DjApi's public surface (not `extends`, since DjApi's constructor
/// builds a real ApiClient); only the session-list calls are wired.
class FakeDjApi implements DjApi, DjSharedMixes {
  Future<List<DjSession>> Function()? onListSessions;

  /// The listener's saved shares; none unless a test says otherwise.
  Future<List<SharedMixRow>> Function() onListSharedMixes = () async =>
      const [];
  Future<void> Function(String token) onRemoveSharedMix = (_) async {};
  final removedShares = <String>[];

  @override
  Future<List<SharedMixRow>> listSharedMixes() => onListSharedMixes();

  @override
  Future<void> removeSharedMix(String token) {
    removedShares.add(token);
    return onRemoveSharedMix(token);
  }

  @override
  Future<SharedMix> getSharedMix(String token) => Completer<SharedMix>().future;

  @override
  Future<void> saveSharedMix(String token) async {}

  @override
  Future<ShareLinkResult> shareSession(String sessionId) =>
      throw UnimplementedError();

  @override
  Future<void> stopSharing(String sessionId) => throw UnimplementedError();
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
  Future<TurnResult> sendMessage(
    String id,
    String text, {
    bool remake = false,
  }) => throw UnimplementedError();

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

/// A short pull down past the top: enough to bring the Archived row out,
/// short of the refresh control's trigger.
Future<void> _revealArchived(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, 140));
  await tester.pumpAndSettle();
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
  group('the DJ at work (device smoke 2026-11-13)', () {
    CassetteTile tileOf(WidgetTester tester, String id) => tester.widget<CassetteTile>(
      find.descendant(
        of: find.byKey(Key('session-$id')),
        matching: find.byType(CassetteTile),
      ),
    );

    testWidgets('a mix with a turn out turns, then wears a dot when it lands', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(id: 'a', title: 'Run club'),
          _session(id: 'b', title: 'Sunday'),
        ];
      final container = _makeContainer(api);
      await _pump(tester, container);

      final end = container.read(mixActivityProvider.notifier).beginTurn('a');
      await tester.pump();
      expect(tileOf(tester, 'a').spinning, isTrue);
      expect(tileOf(tester, 'b').spinning, isFalse);
      expect(find.text(MixHomeRow.workingSubtitle), findsOneWidget);

      end(ready: true);
      await tester.pumpAndSettle();
      expect(tileOf(tester, 'a').spinning, isFalse);
      expect(find.byKey(MixHomeRow.readyKey('a')), findsOneWidget);
      expect(find.byKey(MixHomeRow.readyKey('b')), findsNothing);
    });

    testWidgets('a turn landing re-reads the list, so its row moves up', (
      tester,
    ) async {
      var reads = 0;
      final api = FakeDjApi()
        ..onListSessions = () async {
          reads++;
          return [_session(id: 'a')];
        };
      final container = _makeContainer(api);
      await _pump(tester, container);
      expect(reads, 1);

      final end = container.read(mixActivityProvider.notifier).beginTurn('a');
      await tester.pump();
      end(ready: true);
      await tester.pumpAndSettle();
      expect(reads, 2);
    });

    testWidgets('a new mix being made sits at the top until it is named', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(id: 'a', title: 'Run club')];
      final container = _makeContainer(api);
      var startMix = 0;
      await _pump(tester, container, onStartMix: () => startMix++);

      final end = container
          .read(mixActivityProvider.notifier)
          .beginNewMix('a rainy drive home', knownIds: {'a'});
      await tester.pump();
      expect(find.byKey(MixesScreen.pendingKey), findsOneWidget);
      expect(find.text('a rainy drive home'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(MixesScreen.pendingKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('session-a'))).dy),
      );
      expect(
        tester
            .widget<CassetteTile>(
              find.descendant(
                of: find.byKey(MixesScreen.pendingKey),
                matching: find.byType(CassetteTile),
              ),
            )
            .spinning,
        isTrue,
      );
      // It is being made on Home: that is where a tap goes.
      await tester.tap(find.byKey(MixesScreen.pendingKey));
      expect(startMix, 1);

      end();
      await tester.pumpAndSettle();
      expect(find.byKey(MixesScreen.pendingKey), findsNothing);
    });

    testWidgets('once the list lists it, the new mix turns in its own row', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(id: 'new', title: 'A rainy drive home'),
          _session(id: 'a', title: 'Run club'),
        ];
      final container = _makeContainer(api);
      container
          .read(mixActivityProvider.notifier)
          .beginNewMix('a rainy drive home', knownIds: {'a'});
      // Not settled: a turning tape never settles.
      await _pump(tester, container, settle: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(MixesScreen.pendingKey), findsNothing);
      expect(tileOf(tester, 'new').spinning, isTrue);
      expect(tileOf(tester, 'a').spinning, isFalse);
    });
  });

  group('chrome', () {
    testWidgets('title and segmented control are up while sessions load, '
        'over three skeleton rows', (tester) async {
      final handle = tester.ensureSemantics();
      final gate = Completer<List<DjSession>>();
      final api = FakeDjApi()
        ..onListSessions = (() => gate.future)
        ..onListListenLater = (() async => const []);
      await _pump(tester, _makeContainer(api, albums: true), settle: false);
      await tester.pump();

      expect(find.text('Mixes'), findsOneWidget);
      expect(find.byType(SegmentedToggle<MixesSegment>), findsOneWidget);
      expect(find.byKey(const Key('active-mixes')), findsOneWidget);
      expect(find.byKey(const Key('listen-later-mixes')), findsOneWidget);
      // Archived is a row now, not a segment.
      expect(find.byKey(const Key('archived-mixes')), findsNothing);
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
        ..onListSessions = (() async => [_session(title: 'Active One')])
        ..onListListenLater = (() async => const []);
      await _pump(tester, _makeContainer(api, albums: true));

      SemanticsData data(String key) =>
          tester.getSemantics(find.byKey(Key(key))).getSemanticsData();
      expect(data('active-mixes').flagsCollection.isSelected, isTrue);
      expect(data('listen-later-mixes').flagsCollection.isSelected, isFalse);

      await tester.tap(find.byKey(const Key('listen-later-mixes')));
      await tester.pumpAndSettle();
      expect(data('active-mixes').flagsCollection.isSelected, isFalse);
      expect(data('listen-later-mixes').flagsCollection.isSelected, isTrue);
      handle.dispose();
    });

    testWidgets('without album picks there is nothing to toggle', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Active One')];
      await _pump(tester, _makeContainer(api));
      expect(find.byType(SegmentedToggle<MixesSegment>), findsNothing);
      expect(find.text('Active One'), findsOneWidget);
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
    testWidgets('active rows carry a cassette; archived mixes wait behind '
        'the Archived row at the top, which opens their own screen', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(title: 'Active One'),
          _session(id: 's2', title: 'Old One', status: 'archived'),
          _session(id: 's3', title: 'Older One', status: 'archived'),
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

      // Out of sight until a pull down; then it leads the list, with the
      // count, and the first mix draws its hairline under it.
      final archivedRow = find.byKey(MixesScreen.archivedRowKey);
      expect(archivedRow, findsNothing);
      await _revealArchived(tester);
      expect(archivedRow, findsOneWidget);
      expect(
        tester.getSize(archivedRow).height,
        lessThan(MixHomeRow.artSize),
        reason: 'a slim line, much shorter than a mix row',
      );
      expect(
        tester.getRect(archivedRow).bottom,
        lessThanOrEqualTo(tester.getRect(find.text('Active One')).top),
      );
      expect(
        find.descendant(of: archivedRow, matching: find.text('2')),
        findsOneWidget,
      );

      await tester.tap(archivedRow);
      await tester.pumpAndSettle();
      expect(find.byType(ArchivedMixesScreen), findsOneWidget);
      expect(find.text('Old One'), findsOneWidget);
      expect(find.text('Older One'), findsOneWidget);
      expect(find.text('Active One'), findsNothing);

      await tester.tap(find.byKey(ArchivedMixesScreen.backKey));
      await tester.pumpAndSettle();
      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
    });

    testWidgets('a row keeps its state when the rows above it move', (
      tester,
    ) async {
      var sessions = [
        _session(title: 'First'),
        _session(id: 's2', title: 'Second'),
      ];
      final api = FakeDjApi()..onListSessions = () async => sessions;
      final container = _makeContainer(api);
      await _pump(tester, container);
      final before = tester.state(find.byType(SwipeActions).last);

      // A mix lands above both, so the second moves down a place.
      sessions = [_session(id: 's0', title: 'Newest'), ...sessions];
      await container.read(sessionsProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        tester.state(
          find.descendant(
            of: find.byKey(const Key('session-s2')),
            matching: find.byType(SwipeActions),
          ),
        ),
        same(before),
      );
    });

    testWidgets('the revealed row hides again once scrolled out of sight, '
        'without moving the list', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          for (var i = 0; i < 14; i++) _session(id: 'a$i', title: 'Mix $i'),
          _session(id: 'z', title: 'Old One', status: 'archived'),
        ];
      await _pump(tester, _makeContainer(api));
      await _revealArchived(tester);
      expect(find.byKey(MixesScreen.archivedRowKey), findsOneWidget);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('Mix 6'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(MixesScreen.archivedRowKey), findsNothing);
      expect(tester.getTopLeft(find.text('Mix 6')), before);

      // Back near the top it stays hidden; only a pull past the top brings
      // it out again.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 440));
      await tester.pumpAndSettle();
      expect(find.text('Mix 0'), findsOneWidget);
      expect(find.byKey(MixesScreen.archivedRowKey), findsNothing);
      await _revealArchived(tester);
      expect(find.byKey(MixesScreen.archivedRowKey), findsOneWidget);
    });

    testWidgets('with VoiceOver on the row is there without a pull', (
      tester,
    ) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(title: 'Active One'),
          _session(id: 's2', title: 'Old One', status: 'archived'),
        ];
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pump(tester, _makeContainer(api));
      expect(find.byKey(MixesScreen.archivedRowKey), findsOneWidget);
    });

    testWidgets('mix rows carry no chevron', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Active One')];
      await _pump(tester, _makeContainer(api));
      expect(
        find.descendant(
          of: find.byType(MixHomeRow),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
      );
    });

    testWidgets('no Archived row while nothing is archived', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(title: 'Active One')];
      await _pump(tester, _makeContainer(api));
      expect(find.byKey(MixesScreen.archivedRowKey), findsNothing);
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

    testWidgets('swipe left, tap Archive: archived with Undo, and Undo '
        'restores the row', (tester) async {
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

      // The swipe opens the row and waits; Archive is a tap.
      await tester.drag(find.text('Sunset Drive'), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.byKey(MixHomeRow.archiveActionKey('s1')));
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

      // A full swipe archives on its own.
      await tester.drag(find.byType(SwipeActions), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
      expect(find.text("couldn't archive — try again"), findsOneWidget);
      expect(writes, 1);
      // The row came back to rest, its title where it was.
      expect(
        tester.getTopLeft(find.text('Sunset Drive')).dx,
        greaterThan(MixHomeRow.artSize),
      );
    });

    testWidgets('unarchive failure keeps the row in Archived', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(title: 'Old One', status: 'archived'),
      ];
      api.onSetStatus = (id, status) async => throw ApiException(500, 'boom');
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(MixesScreen.archivedRowKey));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Old One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unarchive'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
      expect(find.text("couldn't unarchive — try again"), findsOneWidget);
    });

    testWidgets('in Archived a swipe unarchives, with Undo', (tester) async {
      var status = 'archived';
      final writes = <String>[];
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(title: 'Old One', status: status),
      ];
      api.onSetStatus = (id, next) async {
        writes.add(next);
        status = next;
        return _session(title: 'Old One', status: status);
      };
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(MixesScreen.archivedRowKey));
      await tester.pumpAndSettle();

      await tester.drag(find.text('Old One'), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(find.text('Unarchive'), findsOneWidget);
      await tester.tap(find.byKey(MixHomeRow.archiveActionKey('s1')));
      await tester.pumpAndSettle();
      expect(writes, ['active']);
      expect(find.text('Mix unarchived'), findsOneWidget);
      expect(find.byKey(ArchivedMixesScreen.emptyKey), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(writes, ['active', 'archived']);
      expect(find.text('Old One'), findsOneWidget);
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
      // The shared load-error state's tape button, as Library has.
      expect(
        tester.widget(find.byKey(const Key('sessions-retry'))),
        isA<TapeButton>(),
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
      expect(find.byKey(MixesScreen.archivedRowKey), findsNothing);
    });

    testWidgets('nothing active but some archived: the Archived row over '
        'an empty state that says where they went', (tester) async {
      final api = FakeDjApi()
        ..onListSessions = () async => [
          _session(title: 'Old One', status: 'archived'),
        ];
      await _pump(tester, _makeContainer(api), onStartMix: () {});

      expect(find.byKey(MixesScreen.archivedRowKey), findsOneWidget);
      expect(find.text('Nothing active'), findsOneWidget);
      expect(find.text('Start a mix'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
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

    testWidgets('Active and Listen later with album picks on', (tester) async {
      await _pump(tester, _makeContainer(albumApi(), albums: true));
      expect(find.byKey(const Key('active-mixes')), findsOneWidget);
      expect(find.byKey(const Key('listen-later-mixes')), findsOneWidget);
      expect(find.text('Listen later'), findsOneWidget);
    });

    testWidgets('albums off draws no toggle', (tester) async {
      await _pump(tester, _makeContainer(albumApi()));
      expect(find.byKey(const Key('active-mixes')), findsNothing);
      expect(find.byKey(const Key('listen-later-mixes')), findsNothing);
    });

    // The test font draws every glyph a full em wide, about twice SF's
    // width for these words, so a 0.45 text scale stands in for 1x on a
    // device.
    Future<(Rect, Rect)> layoutAt(
      WidgetTester tester,
      double width, {
      double textScale = 0.45,
    }) async {
      await _pump(
        tester,
        _makeContainer(albumApi(), albums: true),
        size: Size(width, 800),
        textScale: textScale,
      );
      expect(tester.takeException(), isNull);
      return (
        tester.getRect(find.text('Mixes')),
        tester.getRect(find.byType(SegmentedToggle<MixesSegment>)),
      );
    }

    testWidgets('at 390 pt the two segments sit beside the title', (
      tester,
    ) async {
      final (title, control) = await layoutAt(tester, 390);
      expect(title.right, lessThanOrEqualTo(control.left));
      expect(control.right, closeTo(370, 0.5));
      expect(control.bottom, closeTo(title.bottom, 12));
      expect(
        tester
            .widget<LargeTitleScaffold>(find.byType(LargeTitleScaffold))
            .accessoriesBelowTitle,
        isFalse,
      );
    });

    testWidgets('where they would squeeze the title they drop below it, '
        'leading', (tester) async {
      final (title, control) = await layoutAt(tester, 320, textScale: 1);
      expect(control.top, greaterThanOrEqualTo(title.bottom));
      expect(control.left, 20);
      expect(control.right, lessThanOrEqualTo(300));
      expect(
        tester
            .widget<LargeTitleScaffold>(find.byType(LargeTitleScaffold))
            .accessoriesBelowTitle,
        isTrue,
      );
    });

    testWidgets('the control may take the content width', (tester) async {
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

    testWidgets('the segments fit a 320 pt screen at 200% text', (
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

  group('shared mixes in Mixes (spec 2026-11-13 shared-mixes)', () {
    SharedMixRow share({
      String token = 'AbCdEfGhIjKlMnOpQrStUv',
      String title = 'Late drive, windows down',
      String? name = 'Ada',
      required DateTime savedAt,
    }) => SharedMixRow(
      token: token,
      title: title,
      caseColor: '#bc5734',
      sharerName: name,
      savedAt: savedAt,
      trackCount: 10,
      durationMs: 2460000,
    );

    double top(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    testWidgets('a shared row sits among own mixes by its saved time, '
        '"From Ada · <time>", in its tape colour', (tester) async {
      final now = DateTime.now();
      final api = FakeDjApi();
      api.onListSessions = () async => [
          _session(id: 'a', title: 'Sunday Reset', updatedAt: now),
          _session(
            id: 'b',
            title: 'Smooth Cruise',
            updatedAt: now.subtract(const Duration(days: 1)),
          ),
        ];
      api.onListSharedMixes = () async => [
          share(savedAt: now.subtract(const Duration(hours: 2))),
        ];
      await _pump(tester, _makeContainer(api));

      expect(top(tester, 'Sunday Reset'), lessThan(top(tester, 'Late drive, windows down')));
      expect(
        top(tester, 'Late drive, windows down'),
        lessThan(top(tester, 'Smooth Cruise')),
      );
      final row = find.byKey(SharedMixHomeRow.rowKey('AbCdEfGhIjKlMnOpQrStUv'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.textContaining('From Ada · 2h ago', findRichText: true)),
        findsOneWidget,
      );
      final tile = tester.widget<CassetteTile>(
        find.descendant(of: row, matching: find.byType(CassetteTile)),
      );
      expect(tile.caseColor, const Color(0xFFBC5734));
    });

    testWidgets('a sender who cleared their name reads "From a friend"', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => [
          share(name: null, savedAt: DateTime.now()),
        ];
      await _pump(tester, _makeContainer(api));
      expect(
        find.textContaining('From a friend', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('shared rows show with no mixes of their own', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      await _pump(tester, _makeContainer(api));
      expect(find.byKey(const Key('sessions-empty')), findsNothing);
      expect(find.text('Late drive, windows down'), findsOneWidget);
    });

    testWidgets('the swipe reveals only Remove, which removes the save', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      await _pump(tester, _makeContainer(api));

      await tester.drag(
        find.text('Late drive, windows down'),
        const Offset(-140, 0),
      );
      await tester.pumpAndSettle();
      const token = 'AbCdEfGhIjKlMnOpQrStUv';
      expect(find.byKey(SharedMixHomeRow.removeActionKey(token)), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Archive'), findsNothing);
      expect(find.text('More'), findsNothing);
      expect(api.removedShares, isEmpty);

      await tester.tap(find.byKey(SharedMixHomeRow.removeActionKey(token)));
      await tester.pumpAndSettle();
      expect(api.removedShares, [token]);
      expect(find.text('Late drive, windows down'), findsNothing);
      expect(find.text('Mine'), findsOneWidget);
    });

    testWidgets('a failed Remove puts the row back and says so', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      api.onRemoveSharedMix = (_) async => throw ApiException(500, 'boom');
      await _pump(tester, _makeContainer(api));

      await tester.drag(
        find.text('Late drive, windows down'),
        const Offset(-140, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(SharedMixHomeRow.removeActionKey('AbCdEfGhIjKlMnOpQrStUv')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Late drive, windows down'), findsOneWidget);
      expect(find.text(SharedMixScreen.removeFailedMessage), findsOneWidget);
    });

    testWidgets('long-press offers the same single Remove', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      await _pump(tester, _makeContainer(api));

      await tester.longPress(find.text('Late drive, windows down'));
      await tester.pumpAndSettle();
      final menu = find.byKey(mixtapeMenuKey);
      expect(find.descendant(of: menu, matching: find.text('Remove')), findsOneWidget);
      expect(
        find.descendant(of: menu, matching: find.byIcon(MixMenuIcons.eject)),
        findsOneWidget,
      );
      expect(find.descendant(of: menu, matching: find.text('Rename')), findsNothing);
      expect(find.descendant(of: menu, matching: find.text('Archive')), findsNothing);
      await tester.tap(find.descendant(of: menu, matching: find.text('Remove')));
      await tester.pumpAndSettle();
      expect(api.removedShares, ['AbCdEfGhIjKlMnOpQrStUv']);
    });

    testWidgets('tapping a shared row opens SharedMixScreen from Mixes', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.text('Late drive, windows down'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final screen = tester.widget<SharedMixScreen>(
        find.byType(SharedMixScreen),
      );
      expect(screen.token, 'AbCdEfGhIjKlMnOpQrStUv');
      expect(screen.fromMixes, isTrue);
    });

    testWidgets('a failed shared read keeps the listener\'s own mixes', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => throw ApiException(500, 'boom');
      await _pump(tester, _makeContainer(api));
      expect(find.text('Mine'), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pull-to-refresh reads the shares again; a stopped one goes', (
      tester,
    ) async {
      var rows = [share(savedAt: DateTime.now())];
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async => rows;
      await _pump(tester, _makeContainer(api));
      expect(find.text('Late drive, windows down'), findsOneWidget);

      rows = [];
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text('Late drive, windows down'), findsNothing);
      expect(find.text('Mine'), findsOneWidget);
    });

    testWidgets('showing the Mixes tab reads the shares again', (
      tester,
    ) async {
      var reads = 0;
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Mine')];
      api.onListSharedMixes = () async {
        reads++;
        return const [];
      };
      final container = _makeContainer(api);
      await _pump(tester, container);
      expect(reads, 1);

      container.read(selectedTabProvider.notifier).select(AppTab.mixes.index);
      await tester.pumpAndSettle();
      expect(reads, 2);
      container.read(selectedTabProvider.notifier).select(AppTab.home.index);
      await tester.pumpAndSettle();
      expect(reads, 2);
    });

    testWidgets('shared rows are not in Archived', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
          _session(id: 'a', title: 'Mine'),
          _session(id: 'z', title: 'Old', status: 'archived'),
        ];
      api.onListSharedMixes = () async => [share(savedAt: DateTime.now())];
      await _pump(tester, _makeContainer(api));
      await _revealArchived(tester);
      await tester.tap(find.byKey(MixesScreen.archivedRowKey));
      await tester.pumpAndSettle();
      expect(find.byType(ArchivedMixesScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ArchivedMixesScreen),
          matching: find.text('Late drive, windows down'),
        ),
        findsNothing,
      );
    });
  });
}
