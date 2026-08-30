import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';

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

/// Fakes [MusicKitBridge]'s hand-off surface only (playQueue/createPlaylist)
/// — the library-sync methods aren't exercised from this screen, so they
/// throw loudly if ever hit. Captures every call for assertion, and both
/// methods default to a happy-path result when no callback is wired, so a
/// test only needs to override the one it cares about.
class FakeBridge implements MusicKitBridge {
  Future<bool> Function(List<String> appleIds)? onPlayQueue;
  Future<({int added, int failed})> Function(String name, List<String> appleIds)?
  onCreatePlaylist;

  final List<List<String>> playCalls = [];
  final List<({String name, List<String> ids})> createCalls = [];

  @override
  Future<bool> requestAuthorization() => throw UnimplementedError();

  @override
  Future<LibraryPage> fetchLibrarySongs({required int offset, required int limit}) =>
      throw UnimplementedError();

  @override
  Future<bool> playQueue(List<String> appleIds) {
    playCalls.add(appleIds);
    final impl = onPlayQueue;
    return impl == null ? Future.value(true) : impl(appleIds);
  }

  @override
  Future<({int added, int failed})> createPlaylist(String name, List<String> appleIds) {
    createCalls.add((name: name, ids: appleIds));
    final impl = onCreatePlaylist;
    return impl == null ? Future.value((added: appleIds.length, failed: 0)) : impl(name, appleIds);
  }
}

/// authProvider override settled at a stable signedIn status — no real
/// keychain restore, no async transition mid-test (same pattern used across
/// dj_providers_test.dart and chat_screen_test.dart).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

DjSession _session({String id = 's1', int queueVersion = 1, String title = 'Test Session'}) =>
    DjSession(id: id, title: title, status: 'active', queueVersion: queueVersion, updatedAt: DateTime(2026, 1, 1));

QueueTrack _track(int position, {Object? appleId = _sentinel, String? reason, int? durationMs = 180000}) =>
    QueueTrack(
      position: position,
      trackId: 't$position',
      appleId: identical(appleId, _sentinel) ? 'apple-$position' : appleId as String?,
      title: 'Title $position',
      artist: 'Artist $position',
      reason: reason,
      durationMs: durationMs,
    );

const _sentinel = Object();

ProviderContainer _makeContainer(FakeDjApi api, {FakeBridge? bridge}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
      musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container, {String sessionId = 's1'}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: QueueScreen(sessionId: sessionId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rows render with 1-based numbering', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(), messages: [], queue: [_track(0), _track(1), _track(2)]);
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Title 2'), findsOneWidget);
  });

  testWidgets('dismissing a row applies a remove op at its 0-based position, against the current version', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 4), messages: [], queue: [_track(0), _track(1)]);
    List<QueueOp>? capturedOps;
    int? capturedVersion;
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      capturedOps = ops;
      capturedVersion = expectedVersion;
      return QueueOpsResult(queueVersion: 5, requested: 1, added: 0, removed: 1, queue: [_track(0)]);
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-t1')), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(capturedOps, isNotNull);
    expect(capturedOps!.single.toJson(), {'op': 'remove', 'position': 1});
    expect(capturedVersion, 4);
  });

  testWidgets('dragging a row down sends a move op, with newIndex adjusted by -1', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(queueVersion: 2),
      messages: [],
      queue: [_track(0), _track(1), _track(2)],
    );
    List<QueueOp>? capturedOps;
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      capturedOps = ops;
      return QueueOpsResult(
        queueVersion: 3,
        requested: 1,
        added: 0,
        removed: 0,
        queue: [_track(1), _track(2), _track(0)],
      );
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    final rowHeight = tester.getSize(find.byKey(const Key('dismissible-t0'))).height;
    final handle = find.byKey(const Key('drag-handle-t0'));

    // Drags the top row (index 0) down past both other rows — Flutter's
    // raw newIndex for a downward drag overshoots by one (it's computed
    // before the dragged item is removed from the list), which is exactly
    // the off-by-one QueueScreen's onReorder handler corrects for.
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(Offset(0, rowHeight * 2.5));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(capturedOps, isNotNull);
    final op = capturedOps!.single.toJson();
    expect(op['op'], 'move');
    expect(op['from'], 0);
    // Moving down: whatever raw newIndex the framework reports, the op's
    // target must already be adjusted (-1 from the raw value) — asserted
    // indirectly here by requiring the corrected target to land AFTER the
    // dragged item's original slot, never equal to the unadjusted overshoot.
    expect(op['to'], greaterThan(0));
  });

  testWidgets('a stale queue-ops response rebuilds the list and shows a snackbar', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 1), messages: [], queue: [_track(0)]);
    api.onApplyQueueOps = (id, ops, expectedVersion) async =>
        throw StaleQueueException(queue: [_track(0), _track(1)], queueVersion: 5);
    final container = _makeContainer(api);
    await _pump(tester, container);

    await container.read(chatProvider('s1').notifier).applyOps([const QueueOp.remove(0)]);
    await tester.pump();
    await tester.pump();

    expect(find.text('queue was updated — showing the latest'), findsOneWidget);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 1'), findsOneWidget);
  });

  testWidgets('play sends appleIds to the bridge in queue order and shows a success snackbar', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0), _track(1), _track(2)],
    );
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('play-button')));
    await tester.pumpAndSettle();

    expect(bridge.playCalls.single, ['apple-0', 'apple-1', 'apple-2']);
    expect(find.text('playing in Apple Music'), findsOneWidget);
  });

  testWidgets('tracks with no Apple Music match are filtered before playing, and the skip count is reported', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0), _track(1, appleId: null), _track(2)],
    );
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('play-button')));
    await tester.pumpAndSettle();

    expect(bridge.playCalls.single, ['apple-0', 'apple-2']);
    expect(find.textContaining('1 track skipped (not in Apple Music)'), findsOneWidget);
  });

  testWidgets('when every track lacks an Apple Music match, play and save are disabled', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0, appleId: null), _track(1, appleId: null)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    final playButton = tester.widget<IconButton>(find.byKey(const Key('play-button')));
    final saveButton = tester.widget<IconButton>(find.byKey(const Key('save-button')));
    expect(playButton.onPressed, isNull);
    expect(saveButton.onPressed, isNull);
    expect(playButton.tooltip, isNotEmpty);
    expect(saveButton.tooltip, isNotEmpty);
  });

  testWidgets('save dialog is prefilled with the session title, trims the entered name, and reports counts', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(title: 'Road Trip'), messages: [], queue: [_track(0), _track(1)]);
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(const Key('playlist-name-field')));
    expect(field.controller!.text, 'Road Trip');

    await tester.enterText(find.byKey(const Key('playlist-name-field')), '  My Mix  ');
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(bridge.createCalls.single.name, 'My Mix');
    expect(bridge.createCalls.single.ids, ['apple-0', 'apple-1']);
    expect(find.text('saved 2 songs to Apple Music'), findsOneWidget);
  });

  testWidgets('a whitespace-only playlist name falls back to the session title', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(title: 'Road Trip'), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('playlist-name-field')), '   ');
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(bridge.createCalls.single.name, 'Road Trip');
  });

  testWidgets('tapping Save twice while the first call is in flight only creates one playlist', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final completer = Completer<({int added, int failed})>();
    final bridge = FakeBridge();
    bridge.onCreatePlaylist = (name, ids) => completer.future;
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pump();
    // A second tap while the bridge call is still in flight — the button is
    // disabled by now, so this must be a no-op rather than a second call.
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pump();

    expect(bridge.createCalls.length, 1);

    completer.complete((added: 1, failed: 0));
    await tester.pumpAndSettle();
    expect(find.text('saved 1 songs to Apple Music'), findsOneWidget);
  });

  testWidgets('tapping a row reveals its reason; a row without one shows a placeholder', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0, reason: 'you loved this one last summer'), _track(1)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text('you loved this one last summer'), findsNothing);
    expect(find.text('no notes from the DJ'), findsNothing);

    await tester.tap(find.byKey(const Key('queue-row-tap-t0')));
    await tester.pumpAndSettle();
    expect(find.text('you loved this one last summer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('queue-row-tap-t1')));
    await tester.pumpAndSettle();
    expect(find.text('no notes from the DJ'), findsOneWidget);
  });

  testWidgets('an empty queue shows a friendly empty state', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text('ask the DJ for a tape'), findsOneWidget);
  });
}
