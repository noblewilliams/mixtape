import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';

/// Implements DjApi's public surface (not `extends` — DjApi's constructor
/// builds a real ApiClient, which a fake has no use for). Mirrors the
/// pattern in dj_providers_test.dart: each method delegates to a settable
/// callback, and an unset callback throws so an unexpected call fails
/// loudly rather than hanging.
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

DjSession _session({String id = 's1', int queueVersion = 1, String title = 'Test Session'}) =>
    DjSession(id: id, title: title, status: 'active', queueVersion: queueVersion, updatedAt: DateTime(2026, 1, 1));

DjMessage _msg(String id, String role, String content, {int? queueVersion}) =>
    DjMessage(id: id, role: role, content: content, queueVersion: queueVersion, createdAt: DateTime(2026, 1, 1));

QueueTrack _track(int position, {int? durationMs = 180000}) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: 'apple-$position',
  title: 'Title $position',
  artist: 'Artist',
  durationMs: durationMs,
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

Future<void> _pump(WidgetTester tester, ProviderContainer container, {String sessionId = 's1'}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatScreen(sessionId: sessionId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders user bubbles right-ish and dj bubbles left-ish by role', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [_msg('m1', 'user', 'play some jazz'), _msg('m2', 'dj', 'here you go')],
      queue: [],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text('play some jazz'), findsOneWidget);
    expect(find.text('here you go'), findsOneWidget);

    final userAlign = tester.widget<Align>(
      find.ancestor(of: find.text('play some jazz'), matching: find.byType(Align)).first,
    );
    expect(userAlign.alignment, Alignment.centerRight);

    final djAlign = tester.widget<Align>(
      find.ancestor(of: find.text('here you go'), matching: find.byType(Align)).first,
    );
    expect(djAlign.alignment, Alignment.centerLeft);
    expect(find.byKey(const Key('error-bubble')), findsNothing);
  });

  testWidgets('send shows a typing indicator while in flight, then the dj reply', (tester) async {
    final completer = Completer<TurnResult>();
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
    api.onSendMessage = (id, text) => completer.future;
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.enterText(find.byKey(const Key('composer-field')), 'play jazz');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pump();

    expect(find.text('play jazz'), findsOneWidget);
    expect(find.byKey(const Key('typing-indicator')), findsOneWidget);
    // composer disabled while sending
    final field = tester.widget<TextField>(find.byKey(const Key('composer-field')));
    expect(field.enabled, isFalse);

    completer.complete(TurnResult(djMessage: _msg('m2', 'dj', 'here you go'), queue: [], queueVersion: 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('typing-indicator')), findsNothing);
    expect(find.text('here you go'), findsOneWidget);
    final fieldAfter = tester.widget<TextField>(find.byKey(const Key('composer-field')));
    expect(fieldAfter.enabled, isTrue);
  });

  testWidgets('a failed turn renders an error bubble; the user bubble is retained; retry resends', (tester) async {
    var sendCall = 0;
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
    api.onSendMessage = (id, text) async {
      sendCall++;
      if (sendCall == 1) {
        throw DjApiException(kind: 'conflict', message: 'the DJ is stuck, try again');
      }
      return TurnResult(djMessage: _msg('m2', 'dj', 'sorted, here you go'), queue: [], queueVersion: 1);
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.enterText(find.byKey(const Key('composer-field')), 'play jazz');
    await tester.tap(find.byKey(const Key('send-button')));
    await tester.pumpAndSettle();

    expect(find.text('play jazz'), findsOneWidget);
    expect(find.byKey(const Key('error-bubble')), findsOneWidget);
    expect(find.text('the DJ is stuck, try again'), findsOneWidget);

    await tester.tap(find.byKey(const Key('retry-message')));
    await tester.pumpAndSettle();

    expect(sendCall, 2);
    expect(find.text('play jazz'), findsNWidgets(2)); // original + resend, no dedup
    expect(find.text('sorted, here you go'), findsOneWidget);
    // The original failed turn stays in history as-is; only the retry's own
    // (new) turn succeeded — no retroactive removal of the old error bubble.
    expect(find.byKey(const Key('error-bubble')), findsOneWidget);
  });

  testWidgets('the queue card renders only under the latest message matching the current '
      'queue version; older queue-bearing messages show a chip instead', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(queueVersion: 2),
      messages: [
        _msg('m1', 'dj', 'first cut', queueVersion: 1),
        _msg('m2', 'dj', 'second cut', queueVersion: 2),
      ],
      queue: [_track(0), _track(1)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.byKey(const Key('queue-card')), findsOneWidget);
    expect(find.byKey(const Key('queue-updated-chip')), findsOneWidget);
    expect(find.text('queue updated · v1'), findsOneWidget);

    final chipAlign = tester.widget<Align>(
      find.ancestor(of: find.byKey(const Key('queue-updated-chip')), matching: find.byType(Align)).first,
    );
    expect(chipAlign.alignment, Alignment.centerLeft);
  });

  testWidgets('a standalone queue card is pinned at the bottom when no message matches the '
      'current version but the queue is non-empty', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(queueVersion: 5),
      messages: [_msg('m1', 'dj', 'first cut', queueVersion: 1)],
      queue: [_track(0)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.byKey(const Key('queue-card')), findsOneWidget);
    expect(find.byKey(const Key('queue-updated-chip')), findsOneWidget); // the stale message's own chip
  });

  testWidgets('no queue card at all when the queue is empty and nothing matches', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 5), messages: [_msg('m1', 'dj', 'hi')], queue: []);
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.byKey(const Key('queue-card')), findsNothing);
  });

  testWidgets('tapping the queue card navigates to QueueScreen for this session', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(queueVersion: 1, id: 'session-42'),
      messages: [_msg('m1', 'dj', 'here you go', queueVersion: 1)],
      queue: [_track(0)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container, sessionId: 'session-42');

    await tester.tap(find.byKey(const Key('queue-card')));
    await tester.pumpAndSettle();

    final pushed = tester.widget<QueueScreen>(find.byType(QueueScreen));
    expect(pushed.sessionId, 'session-42');
  });

  testWidgets('an initial load failure shows the error screen; the retry button '
      'invalidates and refetches successfully', (tester) async {
    var shouldFail = true;
    final api = FakeDjApi();
    api.onGetSession = (_) async {
      if (shouldFail) throw ApiException(500, 'internal server error');
      return SessionDetail(session: _session(), messages: [], queue: []);
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    // Even after settling (which drives Riverpod's own default retry
    // backoff to exhaustion, since shouldFail never flips on its own), the
    // screen shows the error UI — it never silently "fixes itself" and it
    // never gets stuck on a bare spinner either.
    expect(find.byKey(const Key('chat-retry')), findsOneWidget);
    expect(find.byKey(const Key('composer-field')), findsNothing);

    shouldFail = false;
    await tester.tap(find.byKey(const Key('chat-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-retry')), findsNothing);
    expect(find.byKey(const Key('composer-field')), findsOneWidget);
  });

  testWidgets('a transientError from the provider (e.g. a stale queue-ops response) shows '
      'a snackbar and is cleared afterward', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 1), messages: [], queue: [_track(0)]);
    api.onApplyQueueOps = (id, ops, expectedVersion) async =>
        throw StaleQueueException(queue: [_track(0)], queueVersion: 2);
    final container = _makeContainer(api);
    await _pump(tester, container);

    await container.read(chatProvider('s1').notifier).applyOps([const QueueOp.remove(0)]);
    await tester.pump();
    await tester.pump();

    expect(find.text('queue was updated — showing the latest'), findsOneWidget);
    expect(container.read(chatProvider('s1')).value!.transientError, isNull);
  });
}
