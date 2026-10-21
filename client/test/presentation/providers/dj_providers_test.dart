import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_listening_api.dart';

/// Implements DjApi's public surface (not `extends` — DjApi's constructor
/// builds a real ApiClient, which a fake has no use for; Dart lets any class
/// stand in as an interface). Each method delegates to a settable callback so
/// individual tests only wire up what they need; unset callbacks throw so a
/// test exercising an unexpected call fails loudly rather than hanging.
class FakeDjApi implements DjApi {
  @override
  Future<void> recordPlaylistCreation(String sessionId, String appleLibraryId) async {}

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
  Future<DjSession> Function(String id, String title)? onRenameSession;
  Future<void> Function(String sessionId, String type)? onPostSessionEvent;
  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

  Future<AlbumPickState> Function(String id, String albumId, int? expectedVersion)? onChoosePick;
  Future<AlbumPickState> Function(String id, int version, int? expectedVersion)? onGoBackToPick;
  Future<ListenLaterEntry> Function(String albumId, String? sessionId)? onSaveForLater;
  Future<void> Function(String albumId)? onUnsaveForLater;
  SessionKind? lastCreateKind;
  int choosePickCallCount = 0;
  InitialPlaylistSeed? lastInitialSeed;
  int listSessionsCallCount = 0;
  int listMemoriesCallCount = 0;
  String? lastDeletedMemoryId;
  int getSessionCallCount = 0;
  int sendMessageCallCount = 0;
  List<QueueOp>? lastOps;
  int? lastExpectedVersion;
  ({String id, String status})? lastStatusCall;
  ({String id, String title})? lastRenameCall;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) {
    lastInitialSeed = playlistSeed;
    lastCreateKind = kind;
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
  Future<DjSession> setCaseColor(String id, String caseColor) => throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) {
    lastRenameCall = (id: id, title: title);
    final impl = onRenameSession;
    if (impl == null) throw UnimplementedError('onRenameSession not wired');
    return impl(id, title);
  }

  @override
  Future<void> postSessionEvent(String sessionId, String type) {
    final impl = onPostSessionEvent;
    if (impl == null) throw UnimplementedError('onPostSessionEvent not wired');
    return impl(sessionId, type);
  }

  @override
  Future<List<DjMemory>> listMemories() {
    listMemoriesCallCount++;
    final impl = onListMemories;
    if (impl == null) throw UnimplementedError('onListMemories not wired');
    return impl();
  }

  @override
  Future<void> deleteMemory(String id) {
    lastDeletedMemoryId = id;
    final impl = onDeleteMemory;
    if (impl == null) throw UnimplementedError('onDeleteMemory not wired');
    return impl(id);
  }

  @override
  Future<AlbumPickState> choosePick(String sessionId, {required String albumId, int? expectedVersion}) {
    choosePickCallCount++;
    final impl = onChoosePick;
    if (impl == null) throw UnimplementedError('onChoosePick not wired');
    return impl(sessionId, albumId, expectedVersion);
  }

  @override
  Future<AlbumPickState> goBackToPick(String sessionId, {required int version, int? expectedVersion}) {
    final impl = onGoBackToPick;
    if (impl == null) throw UnimplementedError('onGoBackToPick not wired');
    return impl(sessionId, version, expectedVersion);
  }

  @override
  Future<List<ListenLaterEntry>> listListenLater() => throw UnimplementedError('listListenLater not wired');

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) {
    final impl = onSaveForLater;
    if (impl == null) throw UnimplementedError('onSaveForLater not wired');
    return impl(albumId, sessionId);
  }

  @override
  Future<void> unsaveForLater(String albumId) {
    final impl = onUnsaveForLater;
    if (impl == null) throw UnimplementedError('onUnsaveForLater not wired');
    return impl(albumId);
  }

  @override
  Future<ListenLaterEntry> markListened(String albumId) => throw UnimplementedError('markListened not wired');

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
  bool notPersonal = false,
}) => DjSession(
  id: id,
  title: 'Test Session',
  status: status,
  queueVersion: queueVersion,
  updatedAt: DateTime(2026, 1, 1),
  notPersonal: notPersonal,
);

/// The onboarding read the service gate has already made before any
/// signed-in screen exists: [FunnelMilestones] reads it synchronously, so a
/// container that has never loaded it posts no milestone at all.
Future<ProviderContainer> _onboarded(
  FakeDjApi api, {
  FakeListeningApi? listening,
  FunnelOnceStore? milestones,
}) async {
  final container = _makeContainer(api, listening: listening, milestones: milestones);
  await container.read(onboardingProvider.future);
  return container;
}

/// Lets the fire-and-forget funnel posts (unawaited by design) run out.
Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// An onboarding read for a Spotify listener whose import has landed.
OnboardingState _imported() =>
    onboardingState(chosenService: 'spotify', importCompletedAt: DateTime(2026, 9, 1));

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
ProviderContainer _makeContainer(
  FakeDjApi api, {
  FakeListeningApi? listening,
  FunnelOnceStore? milestones,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
      // The personal-mix milestone reads the listener and the import state
      // from onboarding and remembers itself in the keychain.
      listeningApiProvider.overrideWithValue(listening ?? FakeListeningApi()),
      servicePreferenceStoreProvider.overrideWithValue(InMemoryServicePreferenceStore()),
      funnelOnceStoreProvider.overrideWithValue(milestones ?? InMemoryFunnelOnceStore()),
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

    test('rename calls renameSession then refreshes the list, mirroring archive/unarchive', () async {
      var listCall = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        listCall++;
        return [_session(id: 's1')];
      };
      api.onRenameSession = (id, title) async => _session(id: id);
      final container = _makeContainer(api);
      await container.read(sessionsProvider.future);

      final ok = await container.read(sessionsProvider.notifier).rename('s1', 'Lagos Nights');

      expect(ok, isTrue);
      expect(api.lastRenameCall, (id: 's1', title: 'Lagos Nights'));
      expect(listCall, 2); // build's own load + the post-rename refresh
    });

    test('a failed rename returns false and leaves the list untouched (no refresh)', () async {
      var listCall = 0;
      final api = FakeDjApi();
      api.onListSessions = () async {
        listCall++;
        return [_session(id: 's1')];
      };
      api.onRenameSession = (id, title) async => throw ApiException(500, 'boom');
      final container = _makeContainer(api);
      await container.read(sessionsProvider.future);

      final ok = await container.read(sessionsProvider.notifier).rename('s1', 'Lagos Nights');

      expect(ok, isFalse);
      expect(listCall, 1); // no refresh on failure
    });

    test('auth transition rebuilds and reloads the sessions list', () async {
      final testAuth = TestAuthNotifier(AuthStatus.session);
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

      testAuth.set(AuthStatus.noSession);
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
      // No key on the wire — Undo stays hidden against an older deploy.
      expect(state.supportsInsert, isFalse);
    });

    test('the insert capability rides the session load into the state', () async {
      final api = FakeDjApi();
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id, queueVersion: 1),
        messages: [],
        queue: [_track(0)],
        supportsInsert: true,
      );
      final container = _makeContainer(api);

      final state = await container.read(chatProvider('s1').future);

      expect(state.supportsInsert, isTrue);
    });

    test('a queue edit keeps the capability flag', () async {
      final api = FakeDjApi();
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id, queueVersion: 1),
        messages: [],
        queue: [_track(0), _track(1)],
        supportsInsert: true,
      );
      api.onApplyQueueOps = (id, ops, expectedVersion) async => QueueOpsResult(
        queueVersion: 2,
        requested: 1,
        added: 0,
        removed: 1,
        queue: [_track(0)],
      );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container
          .read(chatProvider('s1').notifier)
          .applyOps([const QueueOp.remove(1)]);

      expect(container.read(chatProvider('s1')).value!.supportsInsert, isTrue);
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

    test(
      'send adopts a same-turn sessionTitle into state.session, carrying BOTH the new title '
      'and the turn\'s fresh queueVersion (copyWith session-XOR-queueVersion contract respected)',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [],
        );
        api.onSendMessage = (id, text) async => TurnResult(
          djMessage: _msg('m2', 'dj', 'there you go, Lagos Nights it is.'),
          queue: [_track(0)],
          queueVersion: 2,
          sessionTitle: 'Lagos Nights',
        );
        api.onListSessions = () async => [_session(id: 's1')];
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('call this tape Lagos Nights');

        final state = container.read(chatProvider('s1')).value!;
        expect(state.session.title, 'Lagos Nights');
        expect(state.session.queueVersion, 2); // both landed together, not just the title
        expect(state.queueVersion, 2);
        expect(state.queue, hasLength(1));
      },
    );

    test(
      'a same-turn rename invalidates the sessions list lazily — no eager refetch before send() returns',
      () async {
        final api = FakeDjApi();
        api.onGetSession = (_) async =>
            SessionDetail(session: _session(queueVersion: 1), messages: [], queue: []);
        api.onSendMessage = (id, text) async => TurnResult(
          djMessage: _msg('m2', 'dj', 'renamed.'),
          queue: [],
          queueVersion: 2,
          sessionTitle: 'Lagos Nights',
        );
        api.onListSessions = () async => [_session(id: 's1')];
        final container = _makeContainer(api);
        // Home already has the sessions list loaded before the rename.
        await container.read(sessionsProvider.future);
        expect(api.listSessionsCallCount, 1);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('call this tape Lagos Nights');

        // invalidate() alone doesn't refetch anything.
        expect(api.listSessionsCallCount, 1);

        final refreshed = await container.read(sessionsProvider.future);
        expect(refreshed.single.id, 's1');
        expect(api.listSessionsCallCount, 2);
      },
    );

    test(
      'a same-turn rename that resolves AFTER the chat screen is navigated away '
      'from (chatProvider disposed mid-turn) does not throw — the invalidate is '
      'skipped, not swallowed by an unrelated catch',
      () async {
        final sendCompleter = Completer<TurnResult>();
        final api = FakeDjApi();
        api.onGetSession = (_) async =>
            SessionDetail(session: _session(queueVersion: 1), messages: [], queue: []);
        api.onSendMessage = (id, text) => sendCompleter.future;
        api.onListSessions = () async => [_session(id: 's1')];
        final container = _makeContainer(api);

        final sub = container.listen(chatProvider('s1'), (_, __) {});
        await container.read(chatProvider('s1').future);
        final sendFuture = container
            .read(chatProvider('s1').notifier)
            .send('call this tape Lagos Nights');

        // Drop the last listener and let autoDispose's post-listener-removal
        // scheduling run BEFORE the turn resolves — the same timing as a user
        // navigating away from the chat screen while a message is in flight.
        sub.close();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        sendCompleter.complete(
          TurnResult(
            djMessage: _msg('m2', 'dj', 'renamed.'),
            queue: [],
            queueVersion: 2,
            sessionTitle: 'Lagos Nights',
          ),
        );

        // Must resolve cleanly with no unhandled exception — before the
        // `ref.mounted` guard, `ref.invalidate` on the now-disposed
        // provider's ref threw a StateError here instead.
        await sendFuture;
      },
    );

    test('send with no sessionTitle in the response leaves the cached title untouched', () async {
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
      expect(state.session.title, 'Test Session'); // unchanged
      expect(state.queueVersion, 2);
    });

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
    test('forwards explicit seed when creating a new mix', () async {
      final api = FakeDjApi();
      api.onCreateSession = (_) async => SessionDetail(session: _session(id: 'new-seeded'), messages: [], queue: []);
      final container = _makeContainer(api);
      const seed = InitialPlaylistSeed(playlistId: 'exact-id', excludeSourceTracks: true);
      expect(await container.read(sessionStarterProvider)('Night drive', playlistSeed: seed), 'new-seeded');
      expect(identical(api.lastInitialSeed, seed), true);
    });

    test('returns the new session id with no extra round-trip; invalidates the '
        'sessions list lazily rather than refetching eagerly', () async {
      final api = FakeDjApi();
      api.onCreateSession = (prompt) async => SessionDetail(
        session: _session(id: 'new-1'),
        messages: [_msg('m1', 'user', prompt)],
        queue: [],
      );
      api.onListSessions = () async => [_session(id: 'new-1')];
      final container = _makeContainer(api);
      // Simulate Home already having the sessions list loaded before the
      // user starts a new session.
      await container.read(sessionsProvider.future);
      expect(api.listSessionsCallCount, 1);

      final id = await container.read(sessionStarterProvider)(
        'play something upbeat',
      );

      expect(id, 'new-1');
      // No eager refetch before returning — invalidate() only marks the
      // list dirty, it doesn't fetch anything itself.
      expect(api.listSessionsCallCount, 1);

      // Only a later read (e.g. Home rebuilding after navigating back)
      // actually triggers the refetch.
      final refreshed = await container.read(sessionsProvider.future);
      expect(refreshed.map((s) => s.id), ['new-1']);
      expect(api.listSessionsCallCount, 2);
    });

    test('rethrows DjApiException on failure; still invalidates the sessions '
        'list lazily (no extra round-trip before the throw)', () async {
      final api = FakeDjApi();
      api.onCreateSession = (prompt) async => throw DjApiException(
        kind: 'unknown',
        message: 'the DJ is out sick',
        sessionId: 'partial-1',
      );
      api.onListSessions = () async => [_session(id: 'partial-1')];
      final container = _makeContainer(api);
      await container.read(sessionsProvider.future);
      expect(api.listSessionsCallCount, 1);

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
      expect(api.listSessionsCallCount, 1);

      final refreshed = await container.read(sessionsProvider.future);
      expect(refreshed.map((s) => s.id), ['partial-1']);
      expect(api.listSessionsCallCount, 2);
    });
  });

  group('chatProvider resilience (review round 2)', () {
    test('ApiException (e.g. 500) during send: composer recovers — sending '
        'false, error bubble shown, and a subsequent send works', () async {
      var sendCall = 0;
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async {
        sendCall++;
        if (sendCall == 1) throw ApiException(500, 'internal server error');
        return TurnResult(
          djMessage: _msg('m2', 'dj', 'sorted, here you go'),
          queue: [],
          queueVersion: 1,
        );
      };
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      await notifier.send('play jazz');

      var state = container.read(chatProvider('s1')).value!;
      expect(state.sending, isFalse);
      expect(state.messages, hasLength(2));
      expect(state.messages[0].isError, isFalse); // user bubble persists
      expect(state.messages[1].isError, isTrue);
      expect(
        state.messages[1].message.content,
        'something went wrong on our end — try again',
      );

      // The composer isn't bricked: sending is false, so a second send
      // actually goes through this time.
      await notifier.send('try again');

      state = container.read(chatProvider('s1')).value!;
      expect(state.sending, isFalse);
      expect(sendCall, 2);
      expect(state.messages, hasLength(4));
      expect(state.messages[3].isError, isFalse);
      expect(state.messages[3].message.content, 'sorted, here you go');
    });

    test('applyOps offline (NetworkException) sets a friendly transientError '
        'with no unhandled error', () async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [],
        queue: [_track(0)],
      );
      api.onApplyQueueOps = (id, ops, expectedVersion) async =>
          throw NetworkException('no route to host');
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      // Would surface as an unhandled async error / test failure if
      // NetworkException weren't caught.
      await container.read(chatProvider('s1').notifier).applyOps([
        const QueueOp.remove(0),
      ]);

      final state = container.read(chatProvider('s1')).value!;
      expect(state.transientError, contains('check your connection'));
      expect(state.queue, hasLength(1)); // unchanged
      expect(state.queueVersion, 1); // unchanged
    });

    test('DjApiException carrying a queueVersion but no queue adopts neither '
        '(atomic snapshot, never split-brain)', () async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [],
        queue: [_track(0)],
      );
      api.onSendMessage = (id, text) async => throw DjApiException(
        kind: 'conflict',
        message: 'try again',
        queueVersion: 9, // no queue attached
      );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).send('play jazz');

      final state = container.read(chatProvider('s1')).value!;
      // Neither field moved — a bare version with no matching queue is
      // worthless (and dangerous: it could silently mismatch the queue
      // the client already has cached).
      expect(state.queue, hasLength(1));
      expect(state.queue.single.trackId, 't0');
      expect(state.queueVersion, 1);
    });

    test(
      'interleaved send() then applyOps() (applyOps resolves last): both '
      'bubbles land, final queue/version reflect applyOps\' response',
      () async {
        final sendCompleter = Completer<TurnResult>();
        final opsCompleter = Completer<QueueOpsResult>();
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0)],
        );
        api.onSendMessage = (id, text) => sendCompleter.future;
        api.onApplyQueueOps = (id, ops, expectedVersion) => opsCompleter.future;
        final container = _makeContainer(api);
        await container.read(chatProvider('s1').future);
        final notifier = container.read(chatProvider('s1').notifier);

        final sendFuture = notifier.send('play jazz');
        final opsFuture = notifier.applyOps([const QueueOp.remove(0)]);

        sendCompleter.complete(
          TurnResult(
            djMessage: _msg('m2', 'dj', 'here you go'),
            queue: [_track(0), _track(1)],
            queueVersion: 2,
          ),
        );
        await sendFuture;
        opsCompleter.complete(
          QueueOpsResult(
            queueVersion: 3,
            requested: 1,
            added: 0,
            removed: 1,
            queue: [_track(5)],
          ),
        );
        await opsFuture;

        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages, hasLength(2)); // user + dj reply, preserved
        expect(state.messages[0].message.role, 'user');
        expect(state.messages[1].message.role, 'dj');
        expect(state.queue.map((t) => t.trackId), ['t5']); // applyOps wins
        expect(state.queueVersion, 3);
      },
    );

    test('interleaved applyOps() then send() (send resolves last): both '
        'bubbles land, final queue/version reflect send\'s response', () async {
      final sendCompleter = Completer<TurnResult>();
      final opsCompleter = Completer<QueueOpsResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [],
        queue: [_track(0)],
      );
      api.onSendMessage = (id, text) => sendCompleter.future;
      api.onApplyQueueOps = (id, ops, expectedVersion) => opsCompleter.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      final opsFuture = notifier.applyOps([const QueueOp.remove(0)]);
      final sendFuture = notifier.send('play jazz');

      opsCompleter.complete(
        QueueOpsResult(
          queueVersion: 2,
          requested: 1,
          added: 0,
          removed: 1,
          queue: [_track(5)],
        ),
      );
      await opsFuture;
      sendCompleter.complete(
        TurnResult(
          djMessage: _msg('m2', 'dj', 'here you go'),
          queue: [_track(0), _track(1)],
          queueVersion: 3,
        ),
      );
      await sendFuture;

      final state = container.read(chatProvider('s1')).value!;
      expect(state.messages, hasLength(2));
      expect(state.messages[0].message.role, 'user');
      expect(state.messages[1].message.role, 'dj');
      expect(state.queue.map((t) => t.trackId), ['t0', 't1']); // send wins
      expect(state.queueVersion, 3);
    });

    test('chatProvider is autoDispose: after the last listener drops, a later '
        're-read rebuilds from scratch', () async {
      final api = FakeDjApi();
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      final container = _makeContainer(api);

      final sub1 = container.listen(chatProvider('s1'), (_, __) {});
      await container.read(chatProvider('s1').future);
      expect(api.getSessionCallCount, 1);
      sub1.close();

      // Let autoDispose's post-listener-removal scheduling run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final sub2 = container.listen(chatProvider('s1'), (_, __) {});
      await container.read(chatProvider('s1').future);
      expect(api.getSessionCallCount, 2); // rebuilt, not cached
      sub2.close();
    });
  });

  group('memoriesProvider', () {
    test('loads on build, newest-first as the server sent them', () async {
      final api = FakeDjApi()
        ..onListMemories = () async => [
              DjMemory(id: 'm2', note: 'always Wizkid on party tapes', createdAt: DateTime(2026, 8, 30)),
              DjMemory(id: 'm1', note: 'no sad songs before noon', createdAt: DateTime(2026, 8, 29)),
            ];
      final container = _makeContainer(api);

      final memories = await container.read(memoriesProvider.future);

      expect(memories.map((m) => m.id), ['m2', 'm1']);
      expect(api.listMemoriesCallCount, 1);
    });

    test('refresh() replaces state and reports success', () async {
      var call = 0;
      final api = FakeDjApi();
      api.onListMemories = () async {
        call++;
        return [DjMemory(id: 'm$call', note: 'note $call', createdAt: DateTime(2026, 1, call))];
      };
      final container = _makeContainer(api);
      await container.read(memoriesProvider.future);

      final ok = await container.read(memoriesProvider.notifier).refresh();

      expect(ok, isTrue);
      expect(container.read(memoriesProvider).value!.single.id, 'm2');
    });

    test('forget() deletes then verifies canonical absence', () async {
      final api = FakeDjApi();
      api.onListMemories = () async => [
            DjMemory(id: 'm1', note: 'note 1', createdAt: DateTime(2026, 1, 1)),
            DjMemory(id: 'm2', note: 'note 2', createdAt: DateTime(2026, 1, 2)),
          ];
      api.onDeleteMemory = (id) async {
        api.onListMemories = () async => [DjMemory(id: 'm2', note: 'note 2', createdAt: DateTime(2026, 1, 2))];
      };
      final container = _makeContainer(api);
      await container.read(memoriesProvider.future);

      final ok = await container.read(memoriesProvider.notifier).forget('m1');

      expect(ok, isTrue);
      expect(api.lastDeletedMemoryId, 'm1');
      expect(container.read(memoriesProvider).value!.map((m) => m.id), ['m2']);
    });

    test('forget() leaves state untouched and returns false on failure', () async {
      final api = FakeDjApi();
      api.onListMemories = () async => [
            DjMemory(id: 'm1', note: 'note 1', createdAt: DateTime(2026, 1, 1)),
          ];
      api.onDeleteMemory = (id) async => throw ApiException(500, 'boom');
      final container = _makeContainer(api);
      await container.read(memoriesProvider.future);

      final ok = await container.read(memoriesProvider.notifier).forget('m1');

      expect(ok, isFalse);
      expect(container.read(memoriesProvider).value!.map((m) => m.id), ['m1']);
    });

    test('forget() verifies canonical absence after a 404', () async {
      final api = FakeDjApi();
      api.onListMemories = () async => [
            DjMemory(id: 'm1', note: 'note 1', createdAt: DateTime(2026, 1, 1)),
          ];
      api.onDeleteMemory = (id) async {
        api.onListMemories = () async => [];
        throw ApiException(404, 'not_found');
      };
      final container = _makeContainer(api);
      await container.read(memoriesProvider.future);

      final ok = await container.read(memoriesProvider.notifier).forget('m1');

      expect(ok, isTrue);
      expect(container.read(memoriesProvider).value, isEmpty);
    });

    test('auth transition rebuilds and reloads the memories list', () async {
      final testAuth = TestAuthNotifier(AuthStatus.session);
      final api = FakeDjApi();
      api.onListMemories = () async => [DjMemory(id: 'm1', note: 'note 1', createdAt: DateTime(2026, 1, 1))];
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          djApiProvider.overrideWithValue(api),
          authProvider.overrideWith(() => testAuth),
        ],
      );
      addTearDown(container.dispose);

      await container.read(memoriesProvider.future);
      expect(api.listMemoriesCallCount, 1);

      testAuth.set(AuthStatus.noSession);
      await container.read(memoriesProvider.future);

      expect(api.listMemoriesCallCount, 2);
    });
  });

  group('session flags after a turn and the first_personal_mix milestone', () {
    test('send refetches the session afterwards and adopts notPersonal, keeping the turn\'s own '
        'version and same-turn title', () async {
      final api = FakeDjApi();
      var getSessionCalls = 0;
      api.onGetSession = (_) async {
        getSessionCalls++;
        // The refetch answers with a later version too: only the flag is taken.
        return SessionDetail(
          session: _session(queueVersion: getSessionCalls == 1 ? 1 : 9, notPersonal: getSessionCalls > 1),
          messages: [],
          queue: [],
        );
      };
      api.onSendMessage = (id, text) async => TurnResult(
        djMessage: _msg('m2', 'dj', 'here you go'),
        queue: [_track(0)],
        queueVersion: 2,
        sessionTitle: 'Renamed',
      );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      expect(container.read(chatProvider('s1')).value!.session.notPersonal, isFalse);

      await container.read(chatProvider('s1').notifier).send('play jazz');

      final state = container.read(chatProvider('s1')).value!;
      expect(getSessionCalls, 2);
      expect(state.session.notPersonal, isTrue);
      expect(state.queueVersion, 2);
      expect(state.session.title, 'Renamed');
      expect(state.queue, hasLength(1));
      expect(state.messages, hasLength(2));
      expect(state.sending, isFalse);
    });

    test('a failed refetch after a turn keeps the turn\'s result and clears sending', () async {
      final api = FakeDjApi();
      var getSessionCalls = 0;
      api.onGetSession = (_) async {
        if (++getSessionCalls > 1) throw StateError('offline');
        return SessionDetail(session: _session(), messages: [], queue: []);
      };
      api.onSendMessage = (id, text) async => TurnResult(
        djMessage: _msg('m2', 'dj', 'here you go'),
        queue: [_track(0)],
        queueVersion: 2,
      );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).send('play jazz');

      final state = container.read(chatProvider('s1')).value!;
      expect(getSessionCalls, 2);
      expect(state.queue, hasLength(1));
      expect(state.queueVersion, 2);
      expect(state.session.notPersonal, isFalse);
      expect(state.messages, hasLength(2));
      expect(state.sending, isFalse);
    });

    test('creating a session whose queue is personal posts first_personal_mix once, after an import',
        () async {
      final listening = FakeListeningApi(onboarding: _imported());
      final milestones = InMemoryFunnelOnceStore();
      final api = FakeDjApi();
      api.onCreateSession = (_) async =>
          SessionDetail(session: _session(id: 's9'), messages: [], queue: [_track(0)]);
      final container = await _onboarded(api, listening: listening, milestones: milestones);

      await container.read(sessionStarterProvider)('late drive');
      await _flush();
      expect(listening.funnelEvents, [FunnelEventType.firstPersonalMix]);
      expect(await milestones.has('user-1', FunnelEventType.firstPersonalMix), isTrue);

      await container.read(sessionStarterProvider)('another');
      await _flush();
      expect(listening.funnelEvents, [FunnelEventType.firstPersonalMix]);
    });

    test('first_personal_mix never posts before an import; a source\'s lastImportedAt counts as one',
        () async {
      final api = FakeDjApi();
      api.onCreateSession = (_) async =>
          SessionDetail(session: _session(id: 's9'), messages: [], queue: [_track(0)]);

      final before = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
      await (await _onboarded(api, listening: before)).read(sessionStarterProvider)('late drive');
      await _flush();
      expect(before.funnelEvents, isEmpty);

      final viaSource = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          sources: [musicSource(lastImportedAt: DateTime(2026, 9, 1))],
        ),
      );
      await (await _onboarded(api, listening: viaSource)).read(sessionStarterProvider)('late drive');
      await _flush();
      expect(viaSource.funnelEvents, [FunnelEventType.firstPersonalMix]);
    });

    test('an apple_live library sync is not a completed import', () async {
      final api = FakeDjApi();
      api.onCreateSession = (_) async =>
          SessionDetail(session: _session(id: 's9'), messages: [], queue: [_track(0)]);
      // The funnel measures the export import: an Apple listener whose live
      // library synced has a lastImportedAt, and it must not open the gate.
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'apple',
          hasLibrary: true,
          sources: [musicSource(source: 'apple_live', lastImportedAt: DateTime(2026, 9, 1))],
        ),
      );

      await (await _onboarded(api, listening: listening)).read(sessionStarterProvider)('late drive');
      await _flush();

      expect(listening.funnelEvents, isEmpty);
    });

    test('first_personal_mix never posts for a corpus-mode queue or an empty one', () async {
      final api = FakeDjApi();
      final listening = FakeListeningApi(onboarding: _imported());
      final container = await _onboarded(api, listening: listening);

      api.onCreateSession = (_) async => SessionDetail(
        session: _session(id: 's9', notPersonal: true),
        messages: [],
        queue: [_track(0)],
      );
      await container.read(sessionStarterProvider)('late drive');
      await _flush();
      expect(listening.funnelEvents, isEmpty);

      api.onCreateSession = (_) async =>
          SessionDetail(session: _session(id: 's9'), messages: [], queue: []);
      await container.read(sessionStarterProvider)('late drive');
      await _flush();
      expect(listening.funnelEvents, isEmpty);
    });

    test('a turn whose refetch flips notPersonal posts nothing — the flag is adopted first',
        () async {
      final listening = FakeListeningApi(onboarding: _imported());
      final api = FakeDjApi();
      var loads = 0;
      // Personal on the first load, corpus-mode on the post-turn refetch:
      // the milestone must read the refetched flag, not the stale one.
      api.onGetSession = (_) async => SessionDetail(
        session: _session(notPersonal: ++loads > 1),
        messages: [],
        queue: [],
      );
      api.onSendMessage = (id, text) async => TurnResult(
        djMessage: _msg('m2', 'dj', 'here you go'),
        queue: [_track(0)],
        queueVersion: 2,
      );
      final container = await _onboarded(api, listening: listening);
      final sub = container.listen(chatProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).send('play jazz');
      await _flush();

      expect(container.read(chatProvider('s1')).value!.session.notPersonal, isTrue);
      expect(listening.funnelEvents, isEmpty);
    });

    test('a turn whose refetched session is personal posts first_personal_mix too', () async {
      final listening = FakeListeningApi(onboarding: _imported());
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async => TurnResult(
        djMessage: _msg('m2', 'dj', 'here you go'),
        queue: [_track(0)],
        queueVersion: 2,
      );
      final container = await _onboarded(api, listening: listening);
      // Held: chatProvider is autoDispose, and the flush below would drop it.
      final sub = container.listen(chatProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      await container.read(chatProvider('s1').future);
      await _flush();
      expect(listening.funnelEvents, isEmpty, reason: 'loading a session is not generating one');

      await container.read(chatProvider('s1').notifier).send('play jazz');
      await _flush();
      expect(listening.funnelEvents, [FunnelEventType.firstPersonalMix]);
    });
  });

  group('album sessions in the chat', () {
    AlbumPick album(String id, {int version = 1, bool saved = false}) => AlbumPick(
          id: id,
          title: 'Album $id',
          artist: 'Artist',
          type: 'album',
          newToThem: false,
          reason: 'why $id',
          savedForLater: saved,
          version: version,
        );

    AlbumPickState pickState(int version, {String pick = 'a', List<String> runnersUp = const ['b'], bool saved = false}) =>
        AlbumPickState(
          version: version,
          pick: album(pick, version: version, saved: saved),
          runnersUp: [for (final id in runnersUp) album(id, version: version)],
          passed: const [],
        );

    DjSession albumSession({int queueVersion = 1}) => _session(queueVersion: queueVersion).copyWith(kind: SessionKind.album);

    SessionDetail albumDetail({int version = 1, bool saved = false}) => SessionDetail(
          session: albumSession(queueVersion: version),
          messages: [_msg('m1', 'user', 'a record for sunday')],
          queue: const [],
          pickState: pickState(version, saved: saved),
        );

    test('the session load carries the kind and the pick state', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      final container = _makeContainer(api);

      final state = await container.read(chatProvider('s1').future);

      expect(state.kind, SessionKind.album);
      expect(state.pickState!.pick!.id, 'a');
      expect(state.queue, isEmpty);
      expect(state.suggestions, isNull);
    });

    test('send adopts an album turn: pick state, version, title and suggestions, with no refetch', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      api.onSendMessage = (id, text) async => TurnResult(
            djMessage: DjMessage(id: 'd1', role: 'dj', content: 'try this', queueVersion: 2, createdAt: DateTime(2026)),
            queue: const [],
            queueVersion: 2,
            sessionTitle: 'Sunday records',
            pickState: pickState(2, pick: 'c'),
          );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).send('older');

      final state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.id, 'c');
      expect(state.queueVersion, 2);
      expect(state.session.title, 'Sunday records');
      expect(state.session.kind, SessionKind.album);
      expect(state.messages.last.message.content, 'try this');
      expect(state.sending, isFalse);
      // The notPersonal refetch is a mix concern.
      expect(api.getSessionCallCount, 1);
    });

    test('a failed album turn keeps its pills until the next send starts', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      final second = Completer<TurnResult>();
      var call = 0;
      api.onSendMessage = (id, text) {
        call++;
        if (call == 1) {
          return Future.value(TurnResult(
            djMessage: DjMessage(id: 'd1', role: 'dj', content: 'nothing fit', createdAt: DateTime(2026)),
            queue: const [],
            queueVersion: 1,
            pickState: pickState(1),
            suggestions: const ['Something older'],
          ));
        }
        return second.future;
      };
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      await notifier.send('obscure');
      expect(container.read(chatProvider('s1')).value!.suggestions, ['Something older']);

      final pending = notifier.send('Something older');
      expect(container.read(chatProvider('s1')).value!.suggestions, isNull);
      second.complete(TurnResult(
        djMessage: DjMessage(id: 'd2', role: 'dj', content: 'ok', queueVersion: 2, createdAt: DateTime(2026)),
        queue: const [],
        queueVersion: 2,
        pickState: pickState(2),
      ));
      await pending;
      expect(container.read(chatProvider('s1')).value!.queueVersion, 2);
    });

    test('a DjApiException carrying a pick state adopts it before the error turn', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      api.onSendMessage = (id, text) async => throw DjApiException(
            kind: 'upstream',
            message: 'The DJ lost the thread.',
            pickState: pickState(3, pick: 'z'),
          );
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).send('again');

      final state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.id, 'z');
      expect(state.queueVersion, 3);
      expect(state.messages.last.isError, isTrue);
      expect(state.messages.last.message.content, 'The DJ lost the thread.');
    });

    test('choosePick fences on the current version and adopts the returned state', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail(version: 2);
      int? fence;
      api.onChoosePick = (id, albumId, expectedVersion) async {
        fence = expectedVersion;
        expect(albumId, 'b');
        return pickState(3, pick: 'b', runnersUp: const []);
      };
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      final ok = await container.read(chatProvider('s1').notifier).choosePick('b');

      expect(ok, isTrue);
      expect(fence, 2);
      final state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.id, 'b');
      expect(state.queueVersion, 3);
    });

    test('goBack fences too and adopts the returned version', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail(version: 3);
      api.onGoBackToPick = (id, version, expectedVersion) async {
        expect(version, 1);
        expect(expectedVersion, 3);
        return pickState(4, pick: 'a');
      };
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      expect(await container.read(chatProvider('s1').notifier).goBack(1), isTrue);
      expect(container.read(chatProvider('s1')).value!.queueVersion, 4);
    });

    test('a stale pick refetches the session', () async {
      var reads = 0;
      final api = FakeDjApi()
        ..onGetSession = (_) async {
          reads++;
          return reads == 1 ? albumDetail(version: 2) : SessionDetail(
                session: albumSession(queueVersion: 5),
                messages: const [],
                queue: const [],
                pickState: pickState(5, pick: 'q'),
              );
        };
      api.onChoosePick = (id, albumId, expectedVersion) async =>
          throw DjApiException(kind: 'stale', message: 'moved');
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      final ok = await container.read(chatProvider('s1').notifier).choosePick('b');

      expect(ok, isFalse);
      final state = container.read(chatProvider('s1')).value!;
      expect(state.queueVersion, 5);
      expect(state.pickState!.pick!.id, 'q');
      expect(state.transientError, isNull);
    });

    test('one pick at a time, and none while a turn is sending', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      final gate = Completer<AlbumPickState>();
      api.onChoosePick = (id, albumId, expectedVersion) => gate.future;
      final turn = Completer<TurnResult>();
      api.onSendMessage = (id, text) => turn.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      final first = notifier.choosePick('b');
      expect(await notifier.choosePick('b'), isFalse);
      expect(api.choosePickCallCount, 1);
      gate.complete(pickState(2, pick: 'b'));
      expect(await first, isTrue);

      final sending = notifier.send('older');
      expect(await notifier.choosePick('a'), isFalse);
      expect(api.choosePickCallCount, 1);
      turn.complete(TurnResult(
        djMessage: DjMessage(id: 'd', role: 'dj', content: 'ok', createdAt: DateTime(2026)),
        queue: const [],
        queueVersion: 2,
        pickState: pickState(2, pick: 'b'),
      ));
      await sending;
    });

    test('a rebuild mid-pick does not leave picks and Listen later locked', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail();
      final stuck = Completer<AlbumPickState>();
      final stuckSave = Completer<ListenLaterEntry>();
      var picks = 0;
      api.onChoosePick = (id, albumId, expectedVersion) {
        picks++;
        return picks == 1 ? stuck.future : Future.value(pickState(2, pick: albumId));
      };
      var saves = 0;
      api.onSaveForLater = (albumId, sessionId) {
        saves++;
        return saves == 1
            ? stuckSave.future
            : Future.value(ListenLaterEntry(id: albumId, title: 't', artist: 'a', type: 'album', savedAt: DateTime(2026)));
      };
      final container = _makeContainer(api);
      container.listen(chatProvider('s1'), (_, _) {});
      await container.read(chatProvider('s1').future);

      final first = container.read(chatProvider('s1').notifier).choosePick('b');
      final firstSave = container.read(chatProvider('s1').notifier).toggleListenLater();
      container.invalidate(chatProvider('s1'));
      await container.read(chatProvider('s1').future);

      expect(await container.read(chatProvider('s1').notifier).choosePick('b'), isTrue);
      expect(container.read(chatProvider('s1')).value!.pickState!.pick!.id, 'b');
      expect(await container.read(chatProvider('s1').notifier).toggleListenLater(), isTrue);

      stuck.complete(pickState(9, pick: 'z'));
      stuckSave.completeError(ApiException(500, 'late'));
      expect(await first, isFalse);
      expect(await firstSave, isFalse);
      // The superseded writes land nowhere.
      expect(container.read(chatProvider('s1')).value!.queueVersion, 2);
      expect(container.read(chatProvider('s1')).value!.pickState!.pick!.savedForLater, isTrue);
    });

    test('toggleListenLater flips the pick (and the same album elsewhere) optimistically, then saves', () async {
      final api = FakeDjApi()
        ..onGetSession = (_) async => SessionDetail(
              session: albumSession(),
              messages: const [],
              queue: const [],
              pickState: AlbumPickState(
                version: 2,
                pick: album('a', version: 2),
                runnersUp: [album('b', version: 2)],
                passed: [album('a', version: 1)],
              ),
            );
      final save = Completer<ListenLaterEntry>();
      String? savedSession;
      api.onSaveForLater = (albumId, sessionId) {
        expect(albumId, 'a');
        savedSession = sessionId;
        return save.future;
      };
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      final pending = container.read(chatProvider('s1').notifier).toggleListenLater();
      var state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.savedForLater, isTrue);
      expect(state.pickState!.passed.single.savedForLater, isTrue);
      expect(state.pickState!.runnersUp.single.savedForLater, isFalse);

      save.complete(ListenLaterEntry(
        id: 'a',
        title: 'Album a',
        artist: 'Artist',
        type: 'album',
        savedAt: DateTime(2026, 10, 21),
        sessionId: 's1',
      ));
      expect(await pending, isTrue);
      expect(savedSession, 's1');
      state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.savedForLater, isTrue);
    });

    test('toggleListenLater reverts with a transient error when the write fails', () async {
      final api = FakeDjApi()..onGetSession = (_) async => albumDetail(saved: true);
      api.onUnsaveForLater = (albumId) async => throw ApiException(500, 'boom');
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      final ok = await container.read(chatProvider('s1').notifier).toggleListenLater();

      expect(ok, isFalse);
      final state = container.read(chatProvider('s1')).value!;
      expect(state.pickState!.pick!.savedForLater, isTrue);
      expect(state.transientError, isNotNull);
    });
  });

  group('sessionStarterProvider kind', () {
    test('passes album through and skips the anonymous mix notes', () async {
      final api = FakeDjApi()
        ..onCreateSession = (_) async => SessionDetail(
              session: _session(id: 'al').copyWith(kind: SessionKind.album),
              messages: const [],
              queue: const [],
              pickState: const AlbumPickState(version: 0, runnersUp: [], passed: []),
            );
      final container = _makeContainer(api);

      final id = await container.read(sessionStarterProvider)('a record', kind: SessionKind.album);

      expect(id, 'al');
      expect(api.lastCreateKind, SessionKind.album);
    });

    test('defaults to mix', () async {
      final api = FakeDjApi()
        ..onCreateSession = (_) async => SessionDetail(session: _session(id: 'm'), messages: const [], queue: const []);
      final container = _makeContainer(api);

      await container.read(sessionStarterProvider)('rainy');

      expect(api.lastCreateKind, SessionKind.mix);
    });
  });
}
