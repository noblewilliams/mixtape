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
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/working_step.dart';

import '../../helpers/fake_listening_api.dart';

/// Implements DjApi's public surface (not `extends` — DjApi's constructor
/// builds a real ApiClient, which a fake has no use for; Dart lets any class
/// stand in as an interface). Each method delegates to a settable callback so
/// individual tests only wire up what they need; unset callbacks throw so a
/// test exercising an unexpected call fails loudly rather than hanging.
/// [DjRemakeSender] lets it answer [DjApiRemake.sendRemake] too.
class FakeDjApi implements DjApi, DjRemakeSender {
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
  Future<TurnResult> Function(String id)? onSendRemake;

  /// The session id of every [sendRemake], in call order.
  final List<String> remadeSessions = [];
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
  Future<TurnResult> sendRemake(String id) {
    remadeSessions.add(id);
    final impl = onSendRemake;
    if (impl == null) throw UnimplementedError('onSendRemake not wired');
    return impl(id);
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

/// [FakeDjApi] that answers the streamed turns itself ([DjTurnProgressSender]),
/// so a test can play a turn's progress through the callback the provider
/// passes, and see whether it passed one at all.
class ProgressDjApi extends FakeDjApi implements DjTurnProgressSender {
  Future<TurnResult> Function(
    String id,
    String text,
    void Function(TurnProgress)? onProgress,
  )?
  onSendWithProgress;
  Future<TurnResult> Function(
    String id,
    void Function(TurnProgress)? onProgress,
  )?
  onRemakeWithProgress;
  Future<SessionDetail> Function(
    String prompt,
    SessionKind kind,
    void Function(TurnProgress)? onProgress,
  )?
  onCreateWithProgress;

  /// Whether each streamed call was given a progress callback, in order.
  final List<bool> askedForSteps = [];

  @override
  Future<SessionDetail> createSessionWithProgress(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  }) {
    askedForSteps.add(onProgress != null);
    final impl = onCreateWithProgress;
    if (impl == null) {
      throw UnimplementedError('onCreateWithProgress not wired');
    }
    return impl(prompt, kind, onProgress);
  }

  @override
  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) {
    askedForSteps.add(onProgress != null);
    final impl = onSendWithProgress;
    if (impl == null) throw UnimplementedError('onSendWithProgress not wired');
    return impl(id, text, onProgress);
  }

  @override
  Future<TurnResult> sendRemakeWithProgress(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  }) {
    askedForSteps.add(onProgress != null);
    final impl = onRemakeWithProgress;
    if (impl == null) {
      throw UnimplementedError('onRemakeWithProgress not wired');
    }
    return impl(id, onProgress);
  }
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

  group('what the Mixes list sees (device smoke 2026-11-13)', () {
    test('a turn is working while out and ready once it lands', () async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) => completer.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      final sent = container.read(chatProvider('s1').notifier).send('more');
      expect(container.read(mixActivityProvider).isWorking('s1'), isTrue);
      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'ok'), queue: [], queueVersion: 1),
      );
      await sent;
      final activity = container.read(mixActivityProvider);
      expect(activity.isWorking('s1'), isFalse);
      expect(activity.isReady('s1'), isTrue);
    });

    test('a turn whose screen went away still lands as ready', () async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) => completer.future;
      final container = _makeContainer(api);
      final sub = container.listen(chatProvider('s1'), (_, _) {});
      await container.read(chatProvider('s1').future);
      final sent = container.read(chatProvider('s1').notifier).send('more');

      // The conversation is left mid-turn: its transcript is let go.
      sub.close();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(mixActivityProvider).isWorking('s1'), isTrue);

      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'ok'), queue: [], queueVersion: 1),
      );
      await sent;
      expect(container.read(mixActivityProvider).isWorking('s1'), isFalse);
      expect(container.read(mixActivityProvider).isReady('s1'), isTrue);
    });

    test('a conversation reopened mid-turn re-reads once the turn lands', () async {
      final completer = Completer<TurnResult>();
      var reads = 0;
      final api = FakeDjApi();
      api.onGetSession = (_) async {
        reads++;
        return SessionDetail(
          session: _session(),
          messages: [
            _msg('m1', 'user', 'more'),
            if (completer.isCompleted) _msg('m2', 'dj', 'ok'),
          ],
          queue: [],
        );
      };
      api.onSendMessage = (id, text) => completer.future;
      final container = _makeContainer(api);
      var sub = container.listen(chatProvider('s1'), (_, _) {});
      await container.read(chatProvider('s1').future);
      final sent = container.read(chatProvider('s1').notifier).send('more');
      sub.close();
      await Future<void>.delayed(Duration.zero);

      sub = container.listen(chatProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      await container.read(chatProvider('s1').future);
      expect(reads, 2);
      expect(container.read(chatProvider('s1')).value!.messages, hasLength(1));

      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'ok'), queue: [], queueVersion: 1),
      );
      await sent;
      await container.read(chatProvider('s1').future);
      await Future<void>.delayed(Duration.zero);
      await container.read(chatProvider('s1').future);
      expect(reads, 3);
      expect(container.read(chatProvider('s1')).value!.messages, hasLength(2));
    });

    test('a new mix is pending while it is made, then ready', () async {
      final completer = Completer<SessionDetail>();
      final api = FakeDjApi();
      api.onCreateSession = (_) => completer.future;
      final container = _makeContainer(api);

      final started = container.read(sessionStarterProvider)('rainy drive');
      expect(container.read(mixActivityProvider).pending?.prompt, 'rainy drive');
      completer.complete(
        SessionDetail(session: _session(id: 'new-1'), messages: [], queue: []),
      );
      expect(await started, 'new-1');
      final activity = container.read(mixActivityProvider);
      expect(activity.pending, isNull);
      expect(activity.isReady('new-1'), isTrue);
    });

    test('a new mix that failed with a row is ready; without one, nothing', () async {
      final api = FakeDjApi();
      api.onCreateSession = (_) async => throw DjApiException(
        kind: 'upstream',
        message: 'the DJ dropped the needle',
        sessionId: 'kept',
      );
      final container = _makeContainer(api);
      await expectLater(
        container.read(sessionStarterProvider)('rainy drive'),
        throwsA(isA<DjApiException>()),
      );
      expect(container.read(mixActivityProvider).pending, isNull);
      expect(container.read(mixActivityProvider).isReady('kept'), isTrue);

      api.onCreateSession = (_) async => throw ApiException(503, '');
      await expectLater(
        container.read(sessionStarterProvider)('again'),
        throwsA(isA<ApiException>()),
      );
      expect(container.read(mixActivityProvider).pending, isNull);
      expect(container.read(mixActivityProvider).ready, {'kept'});
    });
  });

  group('the turn\'s own steps (turn steps 2026-11-13)', () {
    const crates = TurnStep('digging', scope: 'catalogue', artists: ['Tems']);

    ProgressDjApi api({SessionKind kind = SessionKind.mix}) {
      final api = ProgressDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: DjSession(
          id: 's1',
          title: 'Test Session',
          status: 'active',
          queueVersion: 1,
          updatedAt: DateTime(2026, 1, 1),
          kind: kind,
        ),
        messages: [],
        queue: [],
      );
      return api;
    }

    test('a mix send keeps the latest step on the chat and the working entry, '
        'then lets it go', () async {
      final fake = api();
      final reply = Completer<TurnResult>();
      late void Function(TurnProgress) report;
      fake.onSendWithProgress = (id, text, onProgress) {
        report = onProgress!;
        return reply.future;
      };
      final container = _makeContainer(fake);
      await container.read(chatProvider('s1').future);
      ChatState chat() => container.read(chatProvider('s1')).value!;
      WorkingStep? working() =>
          container.read(mixActivityProvider).workingStep('s1');

      final sent = container.read(chatProvider('s1').notifier).send('more');
      expect(fake.askedForSteps, [true]);
      expect(chat().workingStep, isNull);

      report(const TurnStreamOpened());
      expect(chat().workingStep?.step, isNull);
      expect(chat().workingStep, isNotNull);
      expect(working(), chat().workingStep);

      report(crates);
      expect(chat().workingStep?.step, crates);
      expect(working(), chat().workingStep);

      // A step this build does not know keeps the one it has.
      final before = chat().workingStep;
      report(const TurnStep('tuning'));
      expect(chat().workingStep, same(before));
      expect(working(), same(before));

      reply.complete(
        TurnResult(
          djMessage: _msg('m2', 'dj', 'ok'),
          queue: [],
          queueVersion: 1,
        ),
      );
      await sent;
      expect(chat().workingStep, isNull);
      expect(working(), isNull);
      expect(chat().sending, isFalse);
    });

    test('a remake streams its steps too', () async {
      final fake = api();
      final reply = Completer<TurnResult>();
      late void Function(TurnProgress) report;
      fake.onRemakeWithProgress = (id, onProgress) {
        report = onProgress!;
        return reply.future;
      };
      final container = _makeContainer(fake);
      await container.read(chatProvider('s1').future);

      final remade = container.read(chatProvider('s1').notifier).remake();
      report(const TurnStreamOpened());
      report(crates);
      expect(
        container.read(chatProvider('s1')).value!.workingStep?.step,
        crates,
      );
      reply.complete(
        TurnResult(
          djMessage: _msg('m2', 'dj', 'ok'),
          queue: [],
          queueVersion: 2,
        ),
      );
      await remade;
      expect(fake.askedForSteps, [true]);
      expect(container.read(chatProvider('s1')).value!.workingStep, isNull);
    });

    test('an album message asks for no steps', () async {
      final fake = api(kind: SessionKind.album);
      fake.onSendWithProgress = (id, text, onProgress) async => TurnResult(
        djMessage: _msg('m2', 'dj', 'ok'),
        queue: [],
        queueVersion: 1,
      );
      final container = _makeContainer(fake);
      await container.read(chatProvider('s1').future);
      await container.read(chatProvider('s1').notifier).send('something warm');
      expect(fake.askedForSteps, [false]);
    });

    test(
      'a conversation left mid-turn leaves its step for the next to resume',
      () async {
        final fake = api();
        final reply = Completer<TurnResult>();
        late void Function(TurnProgress) report;
        fake.onSendWithProgress = (id, text, onProgress) {
          report = onProgress!;
          return reply.future;
        };
        final container = _makeContainer(fake);
        var sub = container.listen(chatProvider('s1'), (_, _) {});
        await container.read(chatProvider('s1').future);
        final sent = container.read(chatProvider('s1').notifier).send('more');
        report(const TurnStreamOpened());
        sub.close();
        await Future<void>.delayed(Duration.zero);

        // The request carries on with no conversation to land in.
        report(crates);
        expect(
          container.read(mixActivityProvider).workingStep('s1')?.step,
          crates,
        );
        sub = container.listen(chatProvider('s1'), (_, _) {});
        addTearDown(sub.close);
        await container.read(chatProvider('s1').future);
        expect(
          container.read(mixActivityProvider).workingStep('s1')?.step,
          crates,
        );

        reply.complete(
          TurnResult(
            djMessage: _msg('m2', 'dj', 'ok'),
            queue: [],
            queueVersion: 1,
          ),
        );
        await sent;
        expect(container.read(mixActivityProvider).workingStep('s1'), isNull);
      },
    );

    test('a new mix keeps its step on the pending row, and its id names it; '
        'an album asks for none', () async {
      final fake = ProgressDjApi();
      final made = Completer<SessionDetail>();
      late void Function(TurnProgress) report;
      fake.onCreateWithProgress = (prompt, kind, onProgress) {
        if (kind == SessionKind.album) {
          return Future.value(
            SessionDetail(
              session: _session(id: 'album-1'),
              messages: [],
              queue: [],
            ),
          );
        }
        report = onProgress!;
        return made.future;
      };
      final container = _makeContainer(fake);

      final started = container.read(sessionStarterProvider)('rainy drive');
      report(const TurnStreamOpened());
      report(const TurnSessionStarted('new-1'));
      report(crates);
      final pending = container.read(mixActivityProvider).pending!;
      expect(pending.sessionId, 'new-1');
      expect(container.read(mixActivityProvider).pendingStep?.step, crates);
      expect(
        pending.adopt([_session(id: 'other'), _session(id: 'new-1')]),
        'new-1',
      );

      made.complete(
        SessionDetail(
          session: _session(id: 'new-1'),
          messages: [],
          queue: [],
        ),
      );
      expect(await started, 'new-1');
      expect(container.read(mixActivityProvider).pending, isNull);

      await container.read(sessionStarterProvider)(
        'a record',
        kind: SessionKind.album,
      );
      expect(fake.askedForSteps, [true, false]);
    });

    test('a create stream that drops after naming the mix opens it with the '
        'failure; before it named one, it is a network failure', () async {
      final fake = ProgressDjApi();
      fake.onCreateWithProgress = (prompt, kind, onProgress) async {
        onProgress!(const TurnStreamOpened());
        onProgress(const TurnSessionStarted('new-1'));
        throw NetworkException('the turn stream ended early');
      };
      final container = _makeContainer(fake);

      await expectLater(
        container.read(sessionStarterProvider)('rainy drive'),
        throwsA(
          isA<DjApiException>()
              .having((e) => e.sessionId, 'sessionId', 'new-1')
              .having(
                (e) => e.message,
                'message',
                'something went wrong on our end — try again',
              ),
        ),
      );
      expect(container.read(mixActivityProvider).pending, isNull);
      expect(container.read(mixActivityProvider).isReady('new-1'), isTrue);

      fake.onCreateWithProgress = (prompt, kind, onProgress) async {
        onProgress!(const TurnStreamOpened());
        throw NetworkException('the turn stream ended early');
      };
      await expectLater(
        container.read(sessionStarterProvider)('again'),
        throwsA(isA<NetworkException>()),
      );
      expect(container.read(mixActivityProvider).ready, {'new-1'});
    });

    test(
      'a step that arrives after the conversation rebuilt is ignored',
      () async {
        final fake = api();
        final reply = Completer<TurnResult>();
        late void Function(TurnProgress) report;
        fake.onSendWithProgress = (id, text, onProgress) {
          report = onProgress!;
          return reply.future;
        };
        final container = _makeContainer(fake);
        final sub = container.listen(chatProvider('s1'), (_, _) {});
        addTearDown(sub.close);
        await container.read(chatProvider('s1').future);
        final sent = container.read(chatProvider('s1').notifier).send('more');
        report(const TurnStreamOpened());

        // The listener changed: the conversation and the activity start over.
        (container.read(authProvider.notifier) as TestAuthNotifier).set(
          AuthStatus.noSession,
        );
        await container.read(chatProvider('s1').future);
        report(crates);
        expect(container.read(chatProvider('s1')).value!.workingStep, isNull);
        expect(container.read(mixActivityProvider).workingStep('s1'), isNull);

        reply.complete(
          TurnResult(
            djMessage: _msg('m2', 'dj', 'ok'),
            queue: [],
            queueVersion: 1,
          ),
        );
        await sent;
      },
    );

    test(
      'a stream dropped before it opened is a turn that never left',
      () async {
        final fake = api();
        fake.onSendWithProgress = (id, text, onProgress) async =>
            throw NetworkException('no route to host');
        final container = _makeContainer(fake);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages.map((m) => m.message.role), ['user', 'dj']);
        expect(state.messages.last.isError, isTrue);
        expect(
          state.messages.last.message.content,
          contains('check your connection'),
        );
        // No re-read: the server never had it.
        expect(fake.getSessionCallCount, 1);
        expect(state.workingStep, isNull);
      },
    );

    test('a stream dropped after it opened: the server had the turn, and a '
        'reply that landed is adopted', () async {
      final fake = api();
      fake.onSendWithProgress = (id, text, onProgress) async {
        onProgress!(const TurnStreamOpened());
        onProgress(crates);
        throw NetworkException('the turn stream ended early');
      };
      final container = _makeContainer(fake);
      await container.read(chatProvider('s1').future);
      fake.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [
          _msg('m1', 'user', 'play jazz'),
          _msg('m2', 'dj', 'here is some jazz'),
        ],
        queue: [_track(0)],
      );

      await container.read(chatProvider('s1').notifier).send('play jazz');

      final state = container.read(chatProvider('s1')).value!;
      // The read that found it, then the flags read any reply brings.
      expect(fake.getSessionCallCount, 3);
      expect(state.messages.map((m) => m.message.content), [
        'play jazz',
        'here is some jazz',
      ]);
      expect(state.messages.any((m) => m.isError), isFalse);
      expect(state.queueVersion, 2);
      expect(state.queue, hasLength(1));
      expect(state.sending, isFalse);
      expect(state.workingStep, isNull);
      expect(container.read(mixActivityProvider).isReady('s1'), isTrue);
    });

    test('a stream dropped after it opened with nothing landed yet keeps the '
        'line and says the turn failed, not that it never left', () async {
      final fake = api();
      fake.onSendWithProgress = (id, text, onProgress) async {
        onProgress!(const TurnStreamOpened());
        throw NetworkException('the turn stream ended early');
      };
      final container = _makeContainer(fake);
      await container.read(chatProvider('s1').future);
      fake.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [_msg('m1', 'user', 'play jazz')],
        queue: [],
      );

      await container.read(chatProvider('s1').notifier).send('play jazz');

      final state = container.read(chatProvider('s1')).value!;
      expect(fake.getSessionCallCount, 2);
      expect(state.messages.map((m) => m.message.role), ['user', 'dj']);
      expect(state.messages.first.message.content, 'play jazz');
      expect(state.messages.last.isError, isTrue);
      expect(
        state.messages.last.message.content,
        'something went wrong on our end — try again',
      );
      expect(state.sending, isFalse);
    });

    test(
      'a session that still ends on a reply the client had is no reply',
      () async {
        final fake = api();
        fake.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [_msg('m0', 'user', 'hi'), _msg('m1', 'dj', 'hello')],
          queue: [],
        );
        fake.onSendWithProgress = (id, text, onProgress) async {
          onProgress!(const TurnStreamOpened());
          throw NetworkException('the turn stream ended early');
        };
        final container = _makeContainer(fake);
        await container.read(chatProvider('s1').future);

        await container.read(chatProvider('s1').notifier).send('play jazz');

        final state = container.read(chatProvider('s1')).value!;
        expect(fake.getSessionCallCount, 2);
        expect(state.messages.map((m) => m.message.content), [
          'hi',
          'hello',
          'play jazz',
          'something went wrong on our end — try again',
        ]);
        expect(state.messages.last.isError, isTrue);
      },
    );

    group('one later read, while the server may still finish', () {
      setUp(() {
        final saved = ChatNotifier.lateReadDelay;
        ChatNotifier.lateReadDelay = const Duration(milliseconds: 20);
        addTearDown(() => ChatNotifier.lateReadDelay = saved);
      });

      Future<void> later() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await _flush();
      }

      ProgressDjApi dropping() {
        final fake = api();
        fake.onSendWithProgress = (id, text, onProgress) async {
          onProgress!(const TurnStreamOpened());
          throw NetworkException('the turn stream ended early');
        };
        return fake;
      }

      SessionDetail read({required bool landed}) => SessionDetail(
        session: DjSession(
          id: 's1',
          title: landed ? 'Late Night Jazz' : 'Test Session',
          status: 'active',
          queueVersion: landed ? 2 : 1,
          updatedAt: DateTime(2026, 1, 1),
        ),
        messages: [
          _msg('m1', 'user', 'play jazz'),
          if (landed) _msg('m2', 'dj', 'here is some jazz'),
        ],
        queue: [if (landed) _track(0)],
      );

      test('adopts a reply that landed meanwhile, as a reply, and the failure '
          'line goes', () async {
        var landed = false;
        final fake = dropping();
        final container = _makeContainer(fake);
        // The conversation stays on screen throughout.
        container.listen(chatProvider('s1'), (_, _) {});
        await container.read(chatProvider('s1').future);
        fake.onGetSession = (_) async => read(landed: landed);
        fake.onListSessions = () async => [_session()];
        container.listen(sessionsProvider, (_, _) {});
        await container.read(sessionsProvider.future);

        await container.read(chatProvider('s1').notifier).send('play jazz');
        expect(
          container.read(chatProvider('s1')).value!.messages.last.isError,
          isTrue,
        );

        landed = true;
        await later();
        final state = container.read(chatProvider('s1')).value!;
        expect(state.messages.map((m) => m.message.content), [
          'play jazz',
          'here is some jazz',
        ]);
        expect(state.messages.any((m) => m.isError), isFalse);
        expect(state.queueVersion, 2);
        expect(state.queue, hasLength(1));
        // The rename the reply carries lands, and the list hears of it.
        expect(state.session.title, 'Late Night Jazz');
        // Build, the first read, the later read, and the flags read.
        expect(fake.getSessionCallCount, 4);
        expect(fake.listSessionsCallCount, 2);
      });

      test('nothing landed: the failure line stays', () async {
        final fake = dropping();
        final container = _makeContainer(fake);
        container.listen(chatProvider('s1'), (_, _) {});
        await container.read(chatProvider('s1').future);
        fake.onGetSession = (_) async => read(landed: false);

        await container.read(chatProvider('s1').notifier).send('play jazz');
        await later();
        final state = container.read(chatProvider('s1')).value!;
        expect(fake.getSessionCallCount, 3);
        expect(state.messages.map((m) => m.message.role), ['user', 'dj']);
        expect(state.messages.last.isError, isTrue);
      });

      test('another turn started meanwhile: no later read', () async {
        final fake = dropping();
        final container = _makeContainer(fake);
        container.listen(chatProvider('s1'), (_, _) {});
        await container.read(chatProvider('s1').future);
        fake.onGetSession = (_) async => read(landed: false);
        await container.read(chatProvider('s1').notifier).send('play jazz');
        expect(fake.getSessionCallCount, 2);

        final resend = Completer<TurnResult>();
        fake.onSendWithProgress = (id, text, onProgress) => resend.future;
        final again = container
            .read(chatProvider('s1').notifier)
            .send('play jazz');
        await later();
        expect(fake.getSessionCallCount, 2);

        resend.complete(
          TurnResult(
            djMessage: _msg('m3', 'dj', 'jazz it is'),
            queue: [],
            queueVersion: 1,
          ),
        );
        await again;
      });

      test('the conversation went away: no later read', () async {
        final fake = dropping();
        final container = _makeContainer(fake);
        final sub = container.listen(chatProvider('s1'), (_, _) {});
        await container.read(chatProvider('s1').future);
        fake.onGetSession = (_) async => read(landed: false);
        await container.read(chatProvider('s1').notifier).send('play jazz');
        sub.close();
        await Future<void>.delayed(Duration.zero);
        final reads = fake.getSessionCallCount;
        await later();
        expect(fake.getSessionCallCount, reads);
      });
    });
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

  group('add your music in the chat', () {
    TurnResult turn(String id, int version, {AddMusicOffer? addMusic}) => TurnResult(
          djMessage: _msg(id, 'dj', 'here you go'),
          queue: [_track(0)],
          queueVersion: version,
          addMusic: addMusic,
        );

    test('remake() posts through sendRemake; a plain send still posts through sendMessage', () async {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []))
        ..onSendRemake = ((id) async => turn('d1', 2))
        ..onSendMessage = ((id, text) async => turn('d2', 3));
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      await notifier.remake();
      expect(api.remadeSessions, ['s1']);
      expect(api.sendMessageCallCount, 0);

      await notifier.send('a bit slower');
      expect(api.remadeSessions, ['s1']);
      expect(api.sendMessageCallCount, 1);

      final state = container.read(chatProvider('s1')).value!;
      expect(state.messages.map((m) => m.message.content), [
        'Remake this with my music',
        'here you go',
        'a bit slower',
        'here you go',
      ]);
      expect(state.queueVersion, 3);
    });

    test('remake() shows remakeText as the listener line and clears addMusic as it starts', () async {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []))
        ..onSendMessage = ((id, text) async => turn('d1', 2, addMusic: AddMusicOffer.history));
      final remade = Completer<TurnResult>();
      api.onSendRemake = (_) => remade.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);
      await notifier.send('play my favourites');
      expect(container.read(chatProvider('s1')).value!.addMusic, AddMusicOffer.history);

      final pending = notifier.remake();
      final during = container.read(chatProvider('s1')).value!;
      expect(during.addMusic, isNull);
      expect(during.sending, isTrue);
      expect(during.messages.last.message.role, 'user');
      expect(during.messages.last.message.content, remakeText);

      remade.complete(turn('d2', 3));
      await pending;
      final after = container.read(chatProvider('s1')).value!;
      expect(after.sending, isFalse);
      expect(after.addMusic, isNull);
      expect(after.queueVersion, 3);
    });

    test('a failed remake is handled as a failed send: the error turn, then the composer back', () async {
      // What DjApi makes of the server's `{error: 'wrong_session_kind'}` 409.
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []))
        ..onSendRemake = ((_) async => throw DjApiException(
              kind: 'wrong_session_kind',
              message: 'The DJ ran into a problem — please try again.',
            ));
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);

      await container.read(chatProvider('s1').notifier).remake();

      final state = container.read(chatProvider('s1')).value!;
      expect(state.sending, isFalse);
      expect(state.messages, hasLength(2));
      expect(state.messages.first.message.content, remakeText);
      expect(state.messages.last.isError, isTrue);
      expect(state.messages.last.message.content, 'The DJ ran into a problem — please try again.');
    });

    test('a failed remake\'s listener line keeps the remake marker; a failed plain send\'s does not',
        () async {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []))
        ..onSendRemake = ((_) async => throw DjApiException(kind: 'conflict', message: 'try that again'))
        ..onSendMessage = ((_, _) async => throw DjApiException(kind: 'conflict', message: 'try that again'));
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      await notifier.remake();
      await notifier.send(remakeText);

      final messages = container.read(chatProvider('s1')).value!.messages;
      expect(messages.map((m) => (m.message.role, m.isError, m.remake)), [
        ('user', false, true),
        ('dj', true, false),
        ('user', false, false),
        ('dj', true, false),
      ]);
    });

    test('a remake whose refetch says the mix is personal now adopts notPersonal false', () async {
      final api = FakeDjApi();
      var loads = 0;
      // Not personal on the first load; the post-turn refetch reads the
      // flag the remake cleared.
      api.onGetSession = (_) async => SessionDetail(
            session: _session(notPersonal: ++loads == 1),
            messages: [],
            queue: [],
          );
      api.onSendRemake = (_) async => turn('d1', 2);
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      expect(container.read(chatProvider('s1')).value!.session.notPersonal, isTrue);

      await container.read(chatProvider('s1').notifier).remake();

      expect(loads, 2);
      final state = container.read(chatProvider('s1')).value!;
      expect(state.session.notPersonal, isFalse);
      expect(state.queueVersion, 2);
    });

    test('remake() is a no-op while a send is still in flight', () async {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []))
        ..onSendRemake = ((_) async => turn('d9', 9));
      final first = Completer<TurnResult>();
      api.onSendMessage = (_, _) => first.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);

      final pending = notifier.send('play jazz');
      await notifier.remake();

      expect(api.remadeSessions, isEmpty);
      expect(
        container.read(chatProvider('s1')).value!.messages.map((m) => m.message.content),
        ['play jazz'],
      );

      first.complete(turn('d1', 2));
      await pending;
      expect(api.remadeSessions, isEmpty);
      expect(container.read(chatProvider('s1')).value!.messages, hasLength(2));
    });

    test('the session load carries addMusic, as it carries suggestions', () async {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(
              session: _session(),
              messages: [],
              queue: [],
              addMusic: AddMusicOffer.history,
            ));
      final container = _makeContainer(api);

      final state = await container.read(chatProvider('s1').future);

      expect(state.addMusic, AddMusicOffer.history);
    });

    test('addMusic lands after a turn, survives the flag refetch, and clears when the next send starts',
        () async {
      // The post-turn refetch answers without the key, as GET /sessions/:id does.
      final api = FakeDjApi()
        ..onGetSession = ((_) async => SessionDetail(session: _session(), messages: [], queue: []));
      final second = Completer<TurnResult>();
      var call = 0;
      api.onSendMessage = (id, text) =>
          ++call == 1 ? Future.value(turn('d1', 2, addMusic: AddMusicOffer.history)) : second.future;
      final container = _makeContainer(api);
      await container.read(chatProvider('s1').future);
      final notifier = container.read(chatProvider('s1').notifier);
      expect(container.read(chatProvider('s1')).value!.addMusic, isNull);

      await notifier.send('play my favourites');
      expect(api.getSessionCallCount, 2, reason: 'the notPersonal refetch ran');
      expect(container.read(chatProvider('s1')).value!.addMusic, AddMusicOffer.history);

      final pending = notifier.send('something else');
      expect(container.read(chatProvider('s1')).value!.addMusic, isNull);
      second.complete(turn('d2', 3));
      await pending;
      expect(container.read(chatProvider('s1')).value!.addMusic, isNull);
    });

    test('copyWith keeps addMusic unless told to clear it', () {
      final state = ChatState(
        session: _session(),
        messages: const [],
        queue: const [],
        addMusic: AddMusicOffer.history,
      );

      expect(state.copyWith(sending: true).addMusic, AddMusicOffer.history);
      expect(state.copyWith(clearAddMusic: true).addMusic, isNull);
    });

    // GET /sessions/:id never carries a turn's addMusic, so the create
    // response's has to be handed to the chat it opens (plan C3).
    SessionDetail opened(String id, {AddMusicOffer? addMusic}) => SessionDetail(
          session: _session(id: id),
          messages: [_msg('m1', 'user', 'play my favourites')],
          queue: [_track(0)],
          addMusic: addMusic,
        );

    test("a create's first-turn addMusic reaches the chat it opens, once", () async {
      final api = FakeDjApi()
        ..onCreateSession = ((_) async => opened('new-1', addMusic: AddMusicOffer.history))
        ..onGetSession = ((id) async => opened(id));
      final container = _makeContainer(api);

      final id = await container.read(sessionStarterProvider)('play my favourites');
      final sub = container.listen(chatProvider(id), (_, _) {});
      addTearDown(sub.close);

      expect((await container.read(chatProvider(id).future)).addMusic, AddMusicOffer.history);

      // Taken by that first load: a later one has only what the read says.
      container.invalidate(chatProvider(id));
      expect((await container.read(chatProvider(id).future)).addMusic, isNull);
    });

    test("another session's load never takes the new mix's offer", () async {
      final api = FakeDjApi()
        ..onCreateSession = ((_) async => opened('new-1', addMusic: AddMusicOffer.history))
        ..onGetSession = ((id) async => opened(id));
      final container = _makeContainer(api);

      final id = await container.read(sessionStarterProvider)('play my favourites');

      expect((await container.read(chatProvider('older').future)).addMusic, isNull);
      expect((await container.read(chatProvider(id).future)).addMusic, AddMusicOffer.history);
    });

    test('a failed create leaves nothing for the mix before it', () async {
      var creates = 0;
      final api = FakeDjApi()
        ..onCreateSession = ((_) async {
          if (++creates == 1) return opened('new-1', addMusic: AddMusicOffer.history);
          throw DjApiException(kind: 'unknown', message: 'the DJ is out sick', sessionId: 'new-2');
        })
        ..onGetSession = ((id) async => opened(id));
      final container = _makeContainer(api);

      final id = await container.read(sessionStarterProvider)('play my favourites');
      await expectLater(
        () => container.read(sessionStarterProvider)('another'),
        throwsA(isA<DjApiException>()),
      );

      expect((await container.read(chatProvider(id).future)).addMusic, isNull);
    });

    test('a newer create replaces the offer, even with none of its own', () async {
      var creates = 0;
      final api = FakeDjApi()
        ..onCreateSession = ((_) async =>
            ++creates == 1 ? opened('new-1', addMusic: AddMusicOffer.history) : opened('new-2'))
        ..onGetSession = ((id) async => opened(id));
      final container = _makeContainer(api);

      final first = await container.read(sessionStarterProvider)('play my favourites');
      final second = await container.read(sessionStarterProvider)('another');

      expect((await container.read(chatProvider(second).future)).addMusic, isNull);
      expect((await container.read(chatProvider(first).future)).addMusic, isNull);
    });

    test("an album create's refinement pills reach the chat it opens", () async {
      SessionDetail album({List<String>? suggestions}) => SessionDetail(
            session: _session(id: 'al').copyWith(kind: SessionKind.album),
            messages: [_msg('m2', 'dj', 'None of them are in Apple Music.')],
            queue: const [],
            pickState: const AlbumPickState(version: 0),
            suggestions: suggestions,
          );
      final api = FakeDjApi()
        ..onCreateSession = ((_) async => album(suggestions: ['Any year']))
        ..onGetSession = ((_) async => album());
      final container = _makeContainer(api);

      final id = await container.read(sessionStarterProvider)('a record', kind: SessionKind.album);

      expect((await container.read(chatProvider(id).future)).suggestions, ['Any year']);
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
