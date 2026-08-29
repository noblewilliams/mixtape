import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';

/// Implements DjApi's public surface (not `extends` — DjApi's constructor
/// builds a real ApiClient, which a fake has no use for; Dart lets any class
/// stand in as an interface). Each method delegates to a settable callback so
/// individual tests only wire up what they need; unset callbacks throw so a
/// test exercising an unexpected call fails loudly rather than hanging.
class FakeDjApi implements DjApi {
  Future<SessionDetail> Function(String prompt)? onCreateSession;
  Future<List<DjSession>> Function()? onListSessions;
  Future<SessionDetail> Function(String id)? onGetSession;
  Future<TurnResult> Function(String id, String text)? onSendMessage;
  Future<QueueOpsResult> Function(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  )?
  onApplyQueueOps;
  Future<DjSession> Function(String id, String status)? onSetStatus;

  int listSessionsCallCount = 0;
  int getSessionCallCount = 0;
  int sendMessageCallCount = 0;
  List<QueueOp>? lastOps;
  int? lastExpectedVersion;
  ({String id, String status})? lastStatusCall;

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
    listSessionsCallCount++;
    final impl = onListSessions;
    if (impl == null) throw UnimplementedError('onListSessions not wired');
    return impl();
  }

  @override
  Future<SessionDetail> getSession(String id) {
    getSessionCallCount++;
    final impl = onGetSession;
    if (impl == null) throw UnimplementedError('onGetSession not wired');
    return impl(id);
  }

  @override
  Future<TurnResult> sendMessage(String id, String text) {
    sendMessageCallCount++;
    final impl = onSendMessage;
    if (impl == null) throw UnimplementedError('onSendMessage not wired');
    return impl(id, text);
  }

  @override
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) {
    lastOps = ops;
    lastExpectedVersion = expectedVersion;
    final impl = onApplyQueueOps;
    if (impl == null) throw UnimplementedError('onApplyQueueOps not wired');
    return impl(id, ops, expectedVersion);
  }

  @override
  Future<DjSession> setStatus(String id, String status) {
    lastStatusCall = (id: id, status: status);
    final impl = onSetStatus;
    if (impl == null) throw UnimplementedError('onSetStatus not wired');
    return impl(id, status);
  }

  @override
  void close() {}
}

/// authProvider override for the one test that needs to flip auth status
/// deterministically (no keychain restore race). Fully replaces build() —
/// no need to reach AuthNotifier's private `_restore`.
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) => state = status;
}

DjSession _session({
  String id = 's1',
  String status = 'active',
  int queueVersion = 1,
}) => DjSession(
  id: id,
  title: 'Test Session',
  status: status,
  queueVersion: queueVersion,
  updatedAt: DateTime(2026, 1, 1),
);

DjMessage _msg(String id, String role, String content) => DjMessage(
  id: id,
  role: role,
  content: content,
  createdAt: DateTime(2026, 1, 1),
);

QueueTrack _track(int position) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: 'apple-$position',
  title: 'Title $position',
  artist: 'Artist',
  durationMs: 180000,
);

/// Fixes auth at a stable, already-settled status (no real keychain restore,
/// no async transition) so tests that call a notifier method after the
/// initial build don't race a real AuthNotifier's background `_restore()`
/// flipping auth mid-test and triggering an unrelated rebuild. The dedicated
/// auth-transition test below builds its own container instead, so it can
/// flip status deliberately.
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

void main() {
  group('archived filter helpers', () {
    test('nonArchivedSessions/archivedSessions split by status', () {
      final sessions = [
        _session(id: 'a', status: 'active'),
        _session(id: 'b', status: 'archived'),
        _session(id: 'c', status: 'active'),
      ];
      expect(nonArchivedSessions(sessions).map((s) => s.id), ['a', 'c']);
      expect(archivedSessions(sessions).map((s) => s.id), ['b']);
    });
  });

  group('sessionsProvider', () {
    test('loads on build', () async {
      final api = FakeDjApi()
        ..onListSessions = () async => [_session(id: 's1'), _session(id: 's2')];
      final container = _makeContainer(api);

      final sessions = await container.read(sessionsProvider.future);

      expect(sessions.map((s) => s.id), ['s1', 's2']);
    });

    test('archive calls setStatus then refreshes the list', () async {
      var listCall = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        listCall++;
        return [
          _session(id: 's1', status: listCall == 1 ? 'active' : 'archived'),
        ];
      };
      api.onSetStatus = (id, status) async => _session(id: id, status: status);
      final container = _makeContainer(api);
      await container.read(sessionsProvider.future);

      await container.read(sessionsProvider.notifier).archive('s1');

      expect(api.lastStatusCall, (id: 's1', status: 'archived'));
      expect(container.read(sessionsProvider).value!.single.status, 'archived');
      expect(listCall, 2);
    });

    test('unarchive calls setStatus(active) then refreshes the list', () async {
      var listCall = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        listCall++;
        return [
          _session(id: 's1', status: listCall == 1 ? 'archived' : 'active'),
        ];
      };
      api.onSetStatus = (id, status) async => _session(id: id, status: status);
      final container = _makeContainer(api);
      await container.read(sessionsProvider.future);

      await container.read(sessionsProvider.notifier).unarchive('s1');

      expect(api.lastStatusCall, (id: 's1', status: 'active'));
      expect(container.read(sessionsProvider).value!.single.status, 'active');
    });

    test('auth transition rebuilds and reloads the sessions list', () async {
      final testAuth = TestAuthNotifier(AuthStatus.signedIn);
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(id: 's1')];
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          djApiProvider.overrideWithValue(api),
          authProvider.overrideWith(() => testAuth),
        ],
      );
      addTearDown(container.dispose);

      await container.read(sessionsProvider.future);
      expect(api.listSessionsCallCount, 1);

      testAuth.set(AuthStatus.signedOut);
      await container.read(sessionsProvider.future);

      expect(api.listSessionsCallCount, 2);
    });
  });

  group('chatProvider', () {
    test('initial load populates messages/queue from getSession', () async {
      final api = FakeDjApi();
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id, queueVersion: 1),
        messages: [_msg('m1', 'user', 'play some jazz')],
        queue: [_track(0)],
      );
      final container = _makeContainer(api);

      final state = await container.read(chatProvider('s1').future);

      expect(state.messages, hasLength(1));
      expect(state.messages.single.message.content, 'play some jazz');
      expect(state.messages.single.isError, isFalse);
      expect(state.queue, hasLength(1));
      expect(state.queueVersion, 1);
      expect(state.sending, isFalse);
    });

    test(
      'send happy path orders user then dj bubble and replaces queue/version',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [],
        );
        api.onSendMessage = (id, text) async => TurnResult(
          djMessage: _msg('m2', 'dj', 'here you go'),
          queue: [_track(0)],
          queueVersion: 2,
        );
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages, hasLength(2));
        expect(state.messages[0].message.role, 'user');
        expect(state.messages[0].message.content, 'play jazz');
        expect(state.messages[0].isError, isFalse);
        expect(state.messages[1].message.role, 'dj');
        expect(state.messages[1].message.content, 'here you go');
        expect(state.messages[1].isError, isFalse);
        expect(state.queue, hasLength(1));
        expect(state.queueVersion, 2);
        expect(state.sending, isFalse);
      },
    );

    test('send() while already sending is a no-op', () async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) => completer.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      // send() sets sending=true synchronously before its first await, so a
      // second call made before the first resolves observes the guard.
      final first = notifier.send('one');
      final second = notifier.send('two');
      await second; // resolves immediately (no-op)
      completer.complete(
        TurnResult(
          djMessage: _msg('m2', 'dj', 'ok'),
          queue: [],
          queueVersion: 1,
        ),
      );
      await first;

      expect(api.sendMessageCallCount, 1);
      final state = container.read(chatProvider('s1')).value!;
      expect(state.messages, hasLength(2)); // 'one' + its dj reply only
      expect(state.messages[0].message.content, 'one');
    });

    test(
      'send failure keeps the user bubble, appends an error bubble, adopts the exception queue',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [],
        );
        api.onSendMessage = (id, text) async => throw DjApiException(
          kind: 'conflict',
          message: 'the DJ is stuck, try again',
          queue: [_track(0)],
          queueVersion: 5,
        );
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages, hasLength(2));
        expect(state.messages[0].message.role, 'user');
        expect(state.messages[0].isError, isFalse);
        expect(state.messages[1].isError, isTrue);
        expect(state.messages[1].message.role, 'dj');
        expect(state.messages[1].message.content, 'the DJ is stuck, try again');
        expect(state.queue, hasLength(1));
        expect(state.queueVersion, 5);
        expect(state.sending, isFalse);
      },
    );

    test(
      'send failure with kind "stale" refetches instead of showing an error bubble',
      () async {
        var getSessionCall = 0;
        final api = FakeDjApi();
        api.onGetSession = (_) async {
          getSessionCall++;
          if (getSessionCall == 1) {
            return SessionDetail(
              session: _session(queueVersion: 1),
              messages: [],
              queue: [],
            );
          }
          // Refetch: the server persisted the user's message despite the
          // failed turn, and the queue moved under us.
          return SessionDetail(
            session: _session(queueVersion: 3),
            messages: [_msg('m1', 'user', 'play jazz')],
            queue: [_track(0)],
          );
        };
        api.onSendMessage = (id, text) async =>
            throw DjApiException(kind: 'stale', message: 'unused');
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        expect(
          getSessionCall,
          2,
        ); // initial build + refetch after the stale kind
        final state = container.read(chatProvider('s1')).value!;
        expect(
          state.messages,
          hasLength(1),
        ); // from the refetch, no local error bubble
        expect(state.messages.single.isError, isFalse);
        expect(state.queueVersion, 3);
        expect(state.sending, isFalse);
      },
    );

    test(
      'NetworkException during send shows a fixed offline error bubble; user bubble persists',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async =>
            SessionDetail(session: _session(), messages: [], queue: []);
        api.onSendMessage = (id, text) async =>
            throw NetworkException('no route to host');
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages, hasLength(2));
        expect(state.messages[0].message.role, 'user');
        expect(state.messages[0].isError, isFalse);
        expect(state.messages[1].isError, isTrue);
        expect(
          state.messages[1].message.content,
          contains('check your connection'),
        );
        expect(state.sending, isFalse);
      },
    );

    test(
      'applyOps success replaces queue and version using the current version',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0)],
        );
        api.onApplyQueueOps = (id, ops, expectedVersion) async =>
            QueueOpsResult(
              queueVersion: 2,
              requested: 1,
              added: 0,
              removed: 1,
              queue: [],
            );
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).applyOps([
          const QueueOp.remove(0),
        ]);

        final state = container.read(chatProvider('s1')).value!;
        expect(state.queue, isEmpty);
        expect(state.queueVersion, 2);
        expect(api.lastExpectedVersion, 1);
      },
    );

    test(
      'applyOps stale replaces queue/version from the exception and sets transientError',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0)],
        );
        api.onApplyQueueOps = (id, ops, expectedVersion) async =>
            throw StaleQueueException(
              queue: [_track(0), _track(1)],
              queueVersion: 5,
            );
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).applyOps([
          const QueueOp.move(0, 1),
        ]);

        final state = container.read(chatProvider('s1')).value!;
        expect(state.queue, hasLength(2));
        expect(state.queueVersion, 5);
        expect(state.transientError, isNotNull);
      },
    );

    test(
      'applyOps dj_required sets transientError with the server message, queue unchanged',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0)],
        );
        api.onApplyQueueOps = (id, ops, expectedVersion) async =>
            throw DjApiException(
              kind: 'dj_required',
              message: 'ask the DJ for a swap',
            );
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).applyOps([
          const QueueOp.remove(0),
        ]);

        final state = container.read(chatProvider('s1')).value!;
        expect(state.transientError, 'ask the DJ for a swap');
        expect(state.queue, hasLength(1));
        expect(state.queueVersion, 1);
      },
    );

    test(
      'clearTransientError clears the one-shot transientError only',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0)],
        );
        api.onApplyQueueOps = (id, ops, expectedVersion) async =>
            throw StaleQueueException(queue: [_track(0)], queueVersion: 2);
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);
        await container.read(chatProvider('s1').notifier).applyOps([
          const QueueOp.remove(0),
        ]);
        expect(
          container.read(chatProvider('s1')).value!.transientError,
          isNotNull,
        );

        container.read(chatProvider('s1').notifier).clearTransientError();

        final state = container.read(chatProvider('s1')).value!;
        expect(state.transientError, isNull);
        expect(state.queueVersion, 2); // untouched by the clear
      },
    );
  });

  group('sessionStarterProvider', () {
    test(
      'returns the new session id and refreshes the sessions list',
      () async {
        final api = FakeDjApi();
        api.onCreateSession = (prompt) async => SessionDetail(
          session: _session(id: 'new-1'),
          messages: [_msg('m1', 'user', prompt)],
          queue: [],
        );
        api.onListSessions = () async => [_session(id: 'new-1')];
        final container = _makeContainer(api);

        final id = await container.read(sessionStarterProvider)(
          'play something upbeat',
        );

        expect(id, 'new-1');
        // sessionsProvider.notifier's first read triggers its own initial
        // build() (one listSessions() call), then refresh() makes a second.
        expect(api.listSessionsCallCount, 2);
      },
    );

    test(
      'rethrows DjApiException on failure but still refreshes the sessions list',
      () async {
        final api = FakeDjApi();
        api.onCreateSession = (prompt) async => throw DjApiException(
          kind: 'unknown',
          message: 'the DJ is out sick',
          sessionId: 'partial-1',
        );
        api.onListSessions = () async => [_session(id: 'partial-1')];
        final container = _makeContainer(api);

        await expectLater(
          () => container.read(sessionStarterProvider)('play something upbeat'),
          throwsA(
            isA<DjApiException>().having(
              (e) => e.sessionId,
              'sessionId',
              'partial-1',
            ),
          ),
        );
        // Same accounting as the success case: initial build() + refresh().
        expect(api.listSessionsCallCount, 2);
      },
    );
  });
}
