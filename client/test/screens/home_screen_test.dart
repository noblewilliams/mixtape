import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import '../helpers/fake_bridge.dart';

/// Mirrors chat_screen_test.dart's FakeDjApi: implements DjApi's public
/// surface (not `extends`, since DjApi's constructor builds a real
/// ApiClient), each method delegating to a settable callback that throws
/// loudly when unset rather than hanging.
class FakeDjApi implements DjApi {
  Future<SessionDetail> Function(String prompt)? onCreateSession;
  Future<List<DjSession>> Function()? onListSessions;
  Future<SessionDetail> Function(String id)? onGetSession;
  Future<TurnResult> Function(String id, String text)? onSendMessage;
  Future<QueueOpsResult> Function(String id, List<QueueOp> ops, int? expectedVersion)?
  onApplyQueueOps;
  Future<DjSession> Function(String id, String status)? onSetStatus;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> createSession(String prompt) {
    final impl = onCreateSession;
    if (impl == null) throw UnimplementedError('onCreateSession not wired');
    return impl(prompt);
  }

  @override
  Future<List<DjSession>> listSessions() {
    final impl = onListSessions;
    if (impl == null) throw UnimplementedError('onListSessions not wired');
    return impl();
  }

  @override
  Future<SessionDetail> getSession(String id) {
    final impl = onGetSession;
    if (impl == null) throw UnimplementedError('onGetSession not wired');
    return impl(id);
  }

  @override
  Future<TurnResult> sendMessage(String id, String text) {
    final impl = onSendMessage;
    if (impl == null) throw UnimplementedError('onSendMessage not wired');
    return impl(id, text);
  }

  @override
  Future<QueueOpsResult> applyQueueOps(String id, List<QueueOp> ops, int? expectedVersion) {
    final impl = onApplyQueueOps;
    if (impl == null) throw UnimplementedError('onApplyQueueOps not wired');
    return impl(id, ops, expectedVersion);
  }

  @override
  Future<DjSession> setStatus(String id, String status) {
    final impl = onSetStatus;
    if (impl == null) throw UnimplementedError('onSetStatus not wired');
    return impl(id, status);
  }

  @override
  void close() {}
}

/// authProvider override settled at a stable signedIn status — no real
/// keychain restore, no async transition mid-test (same pattern as
/// dj_providers_test.dart's TestAuthNotifier).
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

ProviderContainer _makeContainer(FakeDjApi api, {LibrarySyncService? syncService}) {
  final overrides = [
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    djApiProvider.overrideWithValue(api),
    authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
    if (syncService != null) librarySyncServiceProvider.overrideWithValue(syncService),
  ];
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('prompt-first session start', () {
    testWidgets('submitting the prompt calls sessionStarter with the trimmed text '
        'and navigates to ChatScreen on success', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      String? capturedPrompt;
      api.onCreateSession = (prompt) async {
        capturedPrompt = prompt;
        return SessionDetail(session: _session(id: 'new-1'), messages: [], queue: []);
      };
      api.onGetSession = (id) async => SessionDetail(session: _session(id: id), messages: [], queue: []);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), '  chill sunset drive  ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(capturedPrompt, 'chill sunset drive');
      expect(find.byType(ChatScreen), findsOneWidget);
      final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(pushed.sessionId, 'new-1');
    });

    testWidgets('the start button is disabled while a create is in flight, and a second '
        'tap does not mint a second session', (tester) async {
      final completer = Completer<SessionDetail>();
      var createCalls = 0;
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) {
        createCalls++;
        return completer.future;
      };
      api.onGetSession = (id) async => SessionDetail(session: _session(id: id), messages: [], queue: []);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'a prompt');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      final button = tester.widget<FilledButton>(find.byKey(const Key('start-session')));
      expect(button.onPressed, isNull);
      final field = tester.widget<TextField>(find.byKey(const Key('prompt-field')));
      expect(field.enabled, isFalse);

      // Tapping the (structurally disabled) button again is a no-op.
      await tester.tap(find.byKey(const Key('start-session')), warnIfMissed: false);
      await tester.pump();
      expect(createCalls, 1);

      completer.complete(SessionDetail(session: _session(id: 'new-2'), messages: [], queue: []));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('a create failure that carries a sessionId still navigates to ChatScreen', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async => throw DjApiException(
        kind: 'conflict',
        message: 'the DJ hiccupped',
        sessionId: 'partial-1',
      );
      api.onGetSession = (id) async => SessionDetail(session: _session(id: id), messages: [], queue: []);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(pushed.sessionId, 'partial-1');
    });

    testWidgets('a create failure without a sessionId shows an inline error and '
        'preserves the prompt draft', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async =>
          throw DjApiException(kind: 'invalid', message: 'try a shorter prompt');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'a very long prompt');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsNothing);
      expect(find.text('try a shorter prompt'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('prompt-field')));
      expect(field.controller!.text, 'a very long prompt');
      final button = tester.widget<FilledButton>(find.byKey(const Key('start-session')));
      expect(button.onPressed, isNotNull); // usable again, not stuck disabled
    });

    testWidgets('a create failure with a sessionId passes the server message through as '
        "ChatScreen's initialError", (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async => throw DjApiException(
        kind: 'conflict',
        message: 'the DJ hiccupped',
        sessionId: 'partial-1',
      );
      api.onGetSession = (id) async => SessionDetail(session: _session(id: id), messages: [], queue: []);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(pushed.initialError, 'the DJ hiccupped');
    });

    testWidgets('a NetworkException on submit shows the offline message and preserves the draft',
        (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async => throw NetworkException('boom');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'a network-flaky prompt');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsNothing);
      expect(
        find.text("couldn't reach the DJ — check your connection and try again"),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byKey(const Key('prompt-field')));
      expect(field.controller!.text, 'a network-flaky prompt');
    });

    testWidgets('a plain ApiException on submit shows the generic message and preserves the draft',
        (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async => throw ApiException(500, 'internal server error');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'a 500 prompt');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsNothing);
      expect(find.text('something went wrong on our end — try again'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('prompt-field')));
      expect(field.controller!.text, 'a 500 prompt');
    });
  });

  group('sessions list', () {
    testWidgets('renders session titles; tapping a row navigates to its ChatScreen', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Sunset Drive'),
        _session(id: 's2', title: 'Rainy Focus'),
      ];
      api.onGetSession = (id) async => SessionDetail(session: _session(id: id), messages: [], queue: []);
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('Sunset Drive'), findsOneWidget);
      expect(find.text('Rainy Focus'), findsOneWidget);

      await tester.tap(find.text('Sunset Drive'));
      await tester.pumpAndSettle();

      final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(pushed.sessionId, 's1');
    });

    testWidgets('archived sessions are excluded by default', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Active One', status: 'active'),
        _session(id: 's2', title: 'Old One', status: 'archived'),
      ];
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
    });

    testWidgets('archiving a session calls the API and removes it from the list', (tester) async {
      var isArchived = false;
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Sunset Drive', status: isArchived ? 'archived' : 'active'),
      ];
      api.onSetStatus = (id, status) async {
        isArchived = status == 'archived';
        return _session(id: id, title: 'Sunset Drive', status: status);
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('Sunset Drive'), findsOneWidget);

      await tester.tap(find.byKey(const Key('archive-s1')));
      await tester.pumpAndSettle();

      expect(find.text('Sunset Drive'), findsNothing);
    });

    testWidgets('an empty sessions list (no archived either) renders the empty state', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('No sessions yet — tell the DJ what you want to hear.'), findsOneWidget);
      expect(find.byKey(const Key('sessions-list')), findsNothing);
      expect(find.byKey(const Key('toggle-archived')), findsNothing);
    });

    testWidgets('toggling "Show archived" reveals archived rows, correctly offsetting past the '
        'toggle button itself', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Active One', status: 'active'),
        _session(id: 's2', title: 'Old One', status: 'archived'),
      ];
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsNothing);
      expect(find.text('Show archived (1)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-archived')));
      await tester.pumpAndSettle();

      expect(find.text('Active One'), findsOneWidget);
      expect(find.text('Old One'), findsOneWidget);
      expect(find.text('Hide archived'), findsOneWidget);
      // The archived row is a real, distinct list item (the +1 toggle-button
      // offset at itemBuilder didn't collide it with the active row above).
      expect(find.byKey(const Key('session-s1')), findsOneWidget);
      expect(find.byKey(const Key('session-s2')), findsOneWidget);
      expect(find.byKey(const Key('unarchive-s2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-archived')));
      await tester.pumpAndSettle();

      expect(find.text('Old One'), findsNothing);
    });

    testWidgets('a failed archive shows a snackbar and the row stays', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Sunset Drive', status: 'active'),
      ];
      api.onSetStatus = (id, status) async => throw ApiException(500, 'boom');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('archive-s1')));
      await tester.pumpAndSettle();

      expect(find.text("couldn't archive — try again"), findsOneWidget);
      expect(find.text('Sunset Drive'), findsOneWidget);
      expect(find.byKey(const Key('archive-s1')), findsOneWidget); // still active, not archived
    });

    testWidgets('a failed unarchive shows a snackbar and the row stays archived', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [
        _session(id: 's1', title: 'Old One', status: 'archived'),
      ];
      api.onSetStatus = (id, status) async => throw ApiException(500, 'boom');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('toggle-archived')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unarchive-s1')));
      await tester.pumpAndSettle();

      expect(find.text("couldn't unarchive — try again"), findsOneWidget);
      expect(find.byKey(const Key('unarchive-s1')), findsOneWidget); // still archived
    });

    testWidgets('unarchiving a session calls setStatus(active) and the row moves back to the '
        'default (non-archived) view', (tester) async {
      var status = 'archived';
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(id: 's1', title: 'Old One', status: status)];
      api.onSetStatus = (id, newStatus) async {
        status = newStatus;
        return _session(id: id, title: 'Old One', status: newStatus);
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('toggle-archived')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unarchive-s1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('unarchive-s1')));
      await tester.pumpAndSettle();

      // Now active again — no archived toggle at all, and it renders as a
      // normal (non-dimmed) row with an archive action.
      expect(find.text('Old One'), findsOneWidget);
      expect(find.byKey(const Key('toggle-archived')), findsNothing);
      expect(find.byKey(const Key('archive-s1')), findsOneWidget);
    });
  });

  group('sessions load failure', () {
    testWidgets('shows an error state with a retry button; retry recovers the list', (tester) async {
      var shouldFail = true;
      final api = FakeDjApi();
      api.onListSessions = () async {
        if (shouldFail) throw ApiException(500, 'listSessions boom');
        return [_session(id: 's1', title: 'Recovered Session')];
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.byKey(const Key('sessions-retry')), findsOneWidget);
      expect(find.byKey(const Key('sessions-list')), findsNothing);

      shouldFail = false;
      await tester.tap(find.byKey(const Key('sessions-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sessions-retry')), findsNothing);
      expect(find.text('Recovered Session'), findsOneWidget);
    });

    testWidgets('a background refresh failure keeps showing the previously-good list, never the '
        'full-screen error', (tester) async {
      var shouldFail = false;
      final api = FakeDjApi();
      api.onListSessions = () async {
        if (shouldFail) throw ApiException(500, 'refresh boom');
        return [_session(id: 's1', title: 'Still Here')];
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('Still Here'), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsNothing);

      shouldFail = true;
      container.invalidate(sessionsProvider);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Still Here'), findsOneWidget);
      expect(find.byKey(const Key('sessions-retry')), findsNothing);

      container.dispose();
    });
  });

  group('library sync relocation', () {
    testWidgets('the sync control lives in the AppBar and still triggers a working sync', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      final service = LibrarySyncService(
        bridge: FakeBridge([song(1), song(2), song(3)]),
        api: await apiWith(MockClient((_) async => http.Response('{"ingested": 0}', 200))),
      );
      final container = _makeContainer(api, syncService: service);
      await _pump(tester, container);

      expect(find.byKey(const Key('sync-action')), findsOneWidget);
      expect(find.byKey(const Key('sync-library')), findsNothing);

      await tester.tap(find.byKey(const Key('sync-action')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-library')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sync-library')));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate((w) => w is Text && (w.data?.contains('Synced 3 songs') ?? false)),
        findsOneWidget,
      );
    });
  });
}
