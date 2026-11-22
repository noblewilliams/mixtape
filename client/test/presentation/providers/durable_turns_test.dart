// Durable mix turns on the client (spec 2026-11-21 durable-mix-turns, "iOS
// client" and "Who notifies"; plan 2026-11-22 tasks C1 and C4): `seen`,
// attaching to a running turn, and coming back to one after a relaunch.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/mix_background_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';
import 'package:mixtape/presentation/providers/turn_seen_provider.dart';

import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart' show TestAuthNotifier;

const _t1 = '11111111-1111-4111-8111-111111111111';
const _t2 = '22222222-2222-4222-8222-222222222222';

DjMessage _msg(String id, String role, String content) => DjMessage(
  id: id,
  role: role,
  content: content,
  createdAt: DateTime(2026, 1, 1),
);

DjSession _session({String id = 's1', int version = 1, DjSessionTurn? turn}) =>
    DjSession(
      id: id,
      title: 'Night drive',
      status: 'active',
      queueVersion: version,
      updatedAt: DateTime(2026, 1, 1),
      turn: turn,
    );

const _running = DjSessionTurn(id: _t1, status: 'running', step: 'picking');

TurnResult _reply() => TurnResult(
  djMessage: _msg('m2', 'dj', 'here is your mix'),
  queue: const [],
  queueVersion: 2,
);

/// Only the calls these tests make; anything else fails loudly.
class _Dj implements DjApi, DjTurnProgressSender, DjTurnAttacher {
  SessionDetail Function(String id) detail = (id) => SessionDetail(
    session: _session(id: id),
    messages: [_msg('m1', 'user', 'night drive')],
    queue: const [],
  );
  List<DjSession> Function() list = () => [_session()];
  Future<TurnResult> Function(void Function(TurnProgress)? onProgress)? onSend;
  Future<SessionDetail> Function(void Function(TurnProgress)? onProgress)?
  onCreate;
  Future<TurnAttachEnd> Function(
    String id,
    void Function(TurnProgress)? onProgress,
  )
  onAttach = (_, _) async => TurnAttachEnd.notRunning;

  final seen = <(String, String)>[];
  final attached = <String>[];
  int gets = 0;
  int lists = 0;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> getSession(String id) async {
    gets++;
    return detail(id);
  }

  @override
  Future<List<DjSession>> listSessions() async {
    lists++;
    return list();
  }

  @override
  Future<SessionDetail> createSessionWithProgress(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  }) => onCreate!(onProgress);

  @override
  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) => onSend!(onProgress);

  @override
  Future<TurnResult> sendRemakeWithProgress(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  }) => onSend!(onProgress);

  @override
  Future<TurnAttachEnd> attachTurn(
    String sessionId, {
    void Function(TurnProgress progress)? onProgress,
  }) {
    attached.add(sessionId);
    return onAttach(sessionId, onProgress);
  }

  @override
  Future<void> markTurnSeen(String sessionId, String turnId) async =>
      seen.add((sessionId, turnId));

  @override
  Future<void> postSessionEvent(String sessionId, String type) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Future<void> _flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Dj api;
  late ProviderContainer container;
  var foreground = true;

  void build() {
    api = _Dj();
    foreground = true;
    container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        djApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        listeningApiProvider.overrideWithValue(FakeListeningApi()),
        servicePreferenceStoreProvider.overrideWithValue(
          InMemoryServicePreferenceStore(),
        ),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        appInForegroundProvider.overrideWithValue(() => foreground),
      ],
    );
    addTearDown(container.dispose);
  }

  /// The conversation on [id], built and on screen.
  Future<void> open(String id, {bool visible = true}) async {
    final sub = container.listen(chatProvider(id), (_, _) {});
    addTearDown(sub.close);
    await container.read(chatProvider(id).future);
    if (visible) container.read(visibleMixProvider.notifier).show(Object(), id);
  }

  /// A send whose stream names durable turn [turnId] (or none) and lands.
  void landing({String? turnId, bool push = false}) {
    api.onSend = (onProgress) async {
      onProgress!(const TurnStreamOpened());
      if (turnId != null) onProgress(TurnStarted(turnId, push: push));
      onProgress(const TurnStep('picking'));
      return _reply();
    };
  }

  group('seen', () {
    setUp(build);

    test('sent once when the result lands with the mix on screen in the '
        'foreground', () async {
      await open('s1');
      landing(turnId: _t1);
      await container.read(chatProvider('s1').notifier).send('more');
      await _flush();
      expect(api.seen, [('s1', _t1)]);

      // Asked again (a resume, a repeat): still once.
      container.read(turnSeenProvider)
        ..landed('s1', _t1)
        ..resumed();
      await _flush();
      expect(api.seen, [('s1', _t1)]);
    });

    test(
      'the turn rides ChatState while out, and goes when it lands',
      () async {
        await open('s1');
        final reply = Completer<TurnResult>();
        api.onSend = (onProgress) {
          onProgress!(const TurnStreamOpened());
          onProgress(const TurnStarted(_t1, push: true));
          return reply.future;
        };
        final sent = container.read(chatProvider('s1').notifier).send('more');
        await _flush();
        expect(
          container.read(chatProvider('s1')).value!.workingTurn,
          const TurnStarted(_t1, push: true),
        );
        expect(
          container.read(mixActivityProvider).workingTurn('s1'),
          const TurnStarted(_t1, push: true),
        );
        reply.complete(_reply());
        await sent;
        expect(container.read(chatProvider('s1')).value!.workingTurn, isNull);
      },
    );

    test('not sent while the app is away; sent when it comes back onto that '
        'mix', () async {
      await open('s1');
      landing(turnId: _t1);
      foreground = false;
      await container.read(chatProvider('s1').notifier).send('more');
      await _flush();
      expect(api.seen, isEmpty);

      foreground = true;
      container.read(turnSeenProvider).resumed();
      await _flush();
      expect(api.seen, [('s1', _t1)]);
    });

    test(
      'not sent when another screen is up, nor on coming back to it',
      () async {
        await open('s1', visible: false);
        container.read(visibleMixProvider.notifier).show(Object(), 'other');
        landing(turnId: _t1);
        await container.read(chatProvider('s1').notifier).send('more');
        container.read(turnSeenProvider).resumed();
        await _flush();
        expect(api.seen, isEmpty);
      },
    );

    test('no turn event (an older server): nothing to acknowledge', () async {
      await open('s1');
      landing();
      await container.read(chatProvider('s1').notifier).send('more');
      await _flush();
      expect(api.seen, isEmpty);
    });

    test('a failed turn (its error event) is seen too', () async {
      await open('s1');
      api.onSend = (onProgress) async {
        onProgress!(const TurnStreamOpened());
        onProgress(const TurnStarted(_t1));
        throw DjApiException(kind: 'upstream', message: 'try that again');
      };
      await container.read(chatProvider('s1').notifier).send('more');
      await _flush();
      expect(api.seen, [('s1', _t1)]);
    });

    test(
      'a new mix landing in the foreground is seen: the create opens it',
      () async {
        api.onCreate = (onProgress) async {
          onProgress!(const TurnStreamOpened());
          onProgress(const TurnSessionStarted('new-1'));
          onProgress(const TurnStarted(_t2));
          return SessionDetail(
            session: _session(id: 'new-1'),
            messages: [_msg('m1', 'dj', 'hi')],
            queue: const [],
          );
        };
        await container.read(onboardingProvider.future);
        await container.read(sessionStarterProvider)('night drive');
        await _flush();
        expect(api.seen, [('new-1', _t2)]);
      },
    );
  });

  group('a dropped durable stream', () {
    setUp(build);

    test('attaches before any failure shows, and lands what it left', () async {
      await open('s1');
      var landed = false;
      api.detail = (id) => SessionDetail(
        session: _session(version: landed ? 2 : 1),
        messages: [
          _msg('m1', 'user', 'more'),
          if (landed) _msg('m2', 'dj', 'here is your mix'),
        ],
        queue: const [],
      );
      api.onSend = (onProgress) async {
        onProgress!(const TurnStreamOpened());
        onProgress(const TurnStarted(_t1));
        throw NetworkException('the turn stream ended early');
      };
      api.onAttach = (id, onProgress) async {
        onProgress!(const TurnStep('checking'));
        landed = true;
        return TurnAttachEnd.result;
      };

      await container.read(chatProvider('s1').notifier).send('more');
      await _flush();

      final state = container.read(chatProvider('s1')).value!;
      expect(api.attached, ['s1']);
      expect(state.messages.any((m) => m.isError), isFalse);
      expect(state.messages.last.message.content, 'here is your mix');
      expect(api.seen, [('s1', _t1)]);
    });
  });

  group('coming back to a running turn', () {
    setUp(build);

    test('opening a mix the server is still running attaches, resumes the '
        'step, and reads the session again once it ends', () async {
      var running = true;
      api.detail = (id) => SessionDetail(
        session: _session(turn: running ? _running : null),
        messages: [
          _msg('m1', 'user', 'night drive'),
          if (!running) _msg('m2', 'dj', 'here is your mix'),
        ],
        queue: const [],
      );
      final end = Completer<TurnAttachEnd>();
      api.onAttach = (id, onProgress) {
        onProgress!(const TurnStreamOpened());
        onProgress(const TurnStarted(_t1));
        onProgress(const TurnStep('picking'));
        return end.future;
      };

      await open('s1');
      await _flush();
      expect(api.attached, ['s1']);
      final activity = container.read(mixActivityProvider);
      expect(activity.isWorking('s1'), isTrue);
      expect(activity.workingStep('s1')?.step?.step, 'picking');
      expect(activity.workingTurn('s1'), const TurnStarted(_t1));
      expect(api.gets, 1);

      running = false;
      end.complete(TurnAttachEnd.result);
      await _flush();
      await container.read(chatProvider('s1').future);
      expect(container.read(mixActivityProvider).isWorking('s1'), isFalse);
      expect(api.gets, 2);
      expect(
        container.read(chatProvider('s1')).value!.messages.last.message.content,
        'here is your mix',
      );
      // It landed on screen, in the foreground.
      expect(api.seen, [('s1', _t1)]);
      // Read again, no longer running: not attached a second time.
      expect(api.attached, ['s1']);
    });

    test('a 204 (it finished meanwhile) reads the session again', () async {
      var reads = 0;
      api.detail = (id) {
        reads++;
        return SessionDetail(
          session: _session(turn: reads == 1 ? _running : null),
          messages: const [],
          queue: const [],
        );
      };
      api.onAttach = (_, _) async => TurnAttachEnd.notRunning;

      await open('s1');
      await _flush();
      await container.read(chatProvider('s1').future);
      expect(api.attached, ['s1']);
      expect(reads, 2);
      expect(container.read(mixActivityProvider).isWorking('s1'), isFalse);
      // No result reached this device: nothing to acknowledge.
      expect(api.seen, isEmpty);
    });

    test('an attach that drops is not retried by the read it causes', () async {
      api.detail = (id) => SessionDetail(
        session: _session(turn: _running),
        messages: const [],
        queue: const [],
      );
      api.onAttach = (_, _) async =>
          throw NetworkException('the attach dropped');

      await open('s1');
      await _flush();
      await container.read(chatProvider('s1').future);
      await _flush();
      expect(api.attached, ['s1']);
    });

    test('a mix with a turn this app sent is not attached to', () async {
      api.detail = (id) => SessionDetail(
        session: _session(turn: _running),
        messages: const [],
        queue: const [],
      );
      final out = container.read(mixActivityProvider.notifier).beginTurn('s1');
      await open('s1');
      await _flush();
      expect(api.attached, isEmpty);
      out(ready: false);
    });

    test('the Mixes list follows a running turn and reads again once it '
        'lands', () async {
      var running = true;
      api.list = () => [
        _session(id: 'a', turn: running ? _running : null),
        _session(id: 'b'),
      ];
      final end = Completer<TurnAttachEnd>();
      api.onAttach = (id, onProgress) {
        onProgress!(const TurnStreamOpened());
        onProgress(const TurnStep('digging', scope: 'library'));
        return end.future;
      };

      final sub = container.listen(sessionsProvider, (_, _) {});
      addTearDown(sub.close);
      final sessions = await container.read(sessionsProvider.future);
      await _flush();
      expect(sessions.first.turn, _running);
      expect(api.attached, ['a']);
      expect(container.read(mixActivityProvider).isWorking('a'), isTrue);
      expect(
        container.read(mixActivityProvider).workingStep('a')?.step?.step,
        'digging',
      );

      running = false;
      end.complete(TurnAttachEnd.result);
      await _flush();
      expect(api.lists, 2);
      expect(container.read(sessionsProvider).value!.first.turn, isNull);
      expect(container.read(mixActivityProvider).isWorking('a'), isFalse);
      expect(container.read(mixActivityProvider).isReady('a'), isTrue);
    });
  });
}
