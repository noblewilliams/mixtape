// The Mixes tab (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 2.3): the session list moved off Home onto its own
// tab, with the native segmented control beside the large title.
//
// The fakes mirror home_screen_test.dart's, so the list cases that move here
// in task 2.2 read the same way they did on Home.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
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
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
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

/// authProvider settled at signedIn — no keychain restore, no async auth
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

ProviderContainer _makeContainer(FakeDjApi api) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
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
      expect(
        find.byType(CupertinoSlidingSegmentedControl<bool>),
        findsOneWidget,
      );
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

      expect(find.text("couldn't load your sessions"), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('sessions-retry')),
          matching: find.byType(TapeButton),
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
      expect(
        find.text("couldn't refresh — showing what we had"),
        findsOneWidget,
      );
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
}
