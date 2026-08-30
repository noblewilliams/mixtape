import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
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
  Future<void> Function(String sessionId, String type)? onPostSessionEvent;
  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

  /// Every session event posted, in order — most tests just want the count
  /// and type, so this captures both rather than wiring a callback per test.
  final List<({String sessionId, String type})> postedEvents = [];

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
  Future<DjSession> renameSession(String id, String title) => throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) {
    postedEvents.add((sessionId: sessionId, type: type));
    final impl = onPostSessionEvent;
    return impl == null ? Future.value() : impl(sessionId, type);
  }

  @override
  Future<List<DjMemory>> listMemories() {
    final impl = onListMemories;
    if (impl == null) throw UnimplementedError('onListMemories not wired');
    return impl();
  }

  @override
  Future<void> deleteMemory(String id) {
    final impl = onDeleteMemory;
    if (impl == null) throw UnimplementedError('onDeleteMemory not wired');
    return impl(id);
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
  final List<({String name, List<String> ids, String? author, String? description})> createCalls =
      [];

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
  Future<({int added, int failed})> createPlaylist(
    String name,
    List<String> appleIds, {
    String? author,
    String? description,
  }) {
    createCalls.add((name: name, ids: appleIds, author: author, description: description));
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

QueueTrack _renumbered(QueueTrack track, int position) => QueueTrack(
      position: position,
      trackId: track.trackId,
      appleId: track.appleId,
      title: track.title,
      artist: track.artist,
      reason: track.reason,
      durationMs: track.durationMs,
    );

/// A tiny stand-in for the server's queue table: holds the canonical
/// queue+version, applies remove/move with the SAME semantics the real
/// endpoint uses (0-based positions; move = splice-out then splice-in),
/// enforces the strict version check (409 → [StaleQueueException]), and
/// bumps the version on every successful call. Lets a test assert what a
/// sequence of ops actually does to the queue instead of hand-stubbing
/// each response.
class _QueueSim {
  _QueueSim(this.tracks, this.version);

  List<QueueTrack> tracks;
  int version;

  QueueOpsResult apply(List<QueueOp> ops, int? expectedVersion) {
    if (expectedVersion != null && expectedVersion != version) {
      throw StaleQueueException(queue: tracks, queueVersion: version);
    }
    final next = [...tracks];
    var removed = 0;
    for (final op in ops) {
      final json = op.toJson();
      if (json['op'] == 'remove') {
        next.removeAt(json['position'] as int);
        removed += 1;
      } else {
        final moved = next.removeAt(json['from'] as int);
        next.insert(json['to'] as int, moved);
      }
    }
    tracks = [for (var i = 0; i < next.length; i++) _renumbered(next[i], i)];
    version += 1;
    return QueueOpsResult(
      queueVersion: version,
      requested: ops.length,
      added: 0,
      removed: removed,
      queue: tracks,
    );
  }
}

ProviderContainer _makeContainer(
  FakeDjApi api, {
  FakeBridge? bridge,
  AuthorStore? authorStore,
  String? accountName,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
      musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
      // The real store hits the keychain platform channel, which doesn't
      // exist under testWidgets.
      authorStoreProvider.overrideWithValue(authorStore ?? InMemoryAuthorStore()),
      // The real provider hits GET /me over the network.
      accountNameProvider.overrideWith((ref) async => accountName),
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

  testWidgets('dragging a row down sends a move op whose target is the raw newIndex minus one', (
    tester,
  ) async {
    final api = FakeDjApi();
    final sim = _QueueSim([_track(0), _track(1), _track(2), _track(3)], 2);
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 2), messages: [], queue: [...sim.tracks]);
    List<QueueOp>? capturedOps;
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      capturedOps = ops;
      return sim.apply(ops, expectedVersion);
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    final rowHeight = tester.getSize(find.byKey(const Key('dismissible-t0'))).height;
    final handle = find.byKey(const Key('drag-handle-t0'));

    // Drags the top row (index 0) downward. Flutter's raw newIndex for a
    // downward drag overshoots by one — it's computed before the dragged
    // item is taken out of the list — so this deterministic gesture reports
    // 2 and the op must carry the corrected 1. Four rows, so BOTH the
    // corrected target and the raw one are valid in-range positions and the
    // assertion below can actually tell them apart.
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(Offset(0, rowHeight * 2.5));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(capturedOps, isNotNull);
    // Pinned to the EXACT target, not just "somewhere after 0": dropping the
    // decrement would send move(0, 2) here, which this assertion catches.
    expect(capturedOps!.single.toJson(), {'op': 'move', 'from': 0, 'to': 1});
    expect(sim.tracks.map((t) => t.trackId).toList(), ['t1', 't0', 't2', 't3']);
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
    // Attribution metadata: without an explicit author Apple stamps the
    // playlist with the Xcode product name ("Runner").
    expect(bridge.createCalls.single.author, 'mixtape');
    expect(bridge.createCalls.single.description, 'made by mixtape');
    expect(find.text('saved 2 songs to Apple Music'), findsOneWidget);
  });

  testWidgets('a typed author is stamped on the playlist and remembered for the next save', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(title: 'Road Trip'), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    final store = InMemoryAuthorStore();
    final container = _makeContainer(api, bridge: bridge, authorStore: store);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('playlist-author-field')), '  Noble  ');
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(bridge.createCalls.single.author, 'Noble');
    expect(await store.read(), 'Noble');

    // Reopening the dialog prefills the remembered name.
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    final authorField = tester.widget<TextField>(find.byKey(const Key('playlist-author-field')));
    expect(authorField.controller!.text, 'Noble');
  });

  testWidgets('with nothing typed on this device, the account name is the author default', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge, accountName: 'Noble');
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    final authorField = tester.widget<TextField>(find.byKey(const Key('playlist-author-field')));
    expect(authorField.controller!.text, 'Noble');

    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();
    expect(bridge.createCalls.single.author, 'Noble');
  });

  testWidgets('a device-typed author beats the account name', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    final container = _makeContainer(
      api,
      bridge: bridge,
      authorStore: InMemoryAuthorStore('DJ Noble'),
      accountName: 'Noble',
    );
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    final authorField = tester.widget<TextField>(find.byKey(const Key('playlist-author-field')));
    expect(authorField.controller!.text, 'DJ Noble');
  });

  testWidgets('a stored author prefills the dialog and rides the save unchanged', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    final container = _makeContainer(
      api,
      bridge: bridge,
      authorStore: InMemoryAuthorStore('Noble'),
    );
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(bridge.createCalls.single.author, 'Noble');
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

  testWidgets('a failed (non-stale) removal un-hides the swiped row instead of losing it', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 4), messages: [], queue: [_track(0), _track(1)]);
    final gate = Completer<void>();
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      await gate.future;
      throw NetworkException('offline');
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-t1')), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // Hidden while the op is in flight (Dismissible requires that)...
    expect(find.text('Title 1'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    // ...and back the moment the op settles as a failure. The version never
    // moved here, so nothing but settle-based un-hiding can recover it.
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.textContaining('check your connection'), findsOneWidget);
  });

  testWidgets('two rapid dismissals both land — the second resolves against the fresh queue and version', (
    tester,
  ) async {
    final sim = _QueueSim([_track(0), _track(1), _track(2)], 4);
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 4), messages: [], queue: [...sim.tracks]);
    final calls = <({List<Map<String, dynamic>> ops, int? version})>[];
    final gate = Completer<void>();
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      calls.add((ops: [for (final o in ops) o.toJson()], version: expectedVersion));
      if (calls.length == 1) await gate.future;
      return sim.apply(ops, expectedVersion);
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-t1')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('dismissible-t2')), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // Strictly one in flight at a time — the second swipe is queued, not fired.
    expect(calls.length, 1);

    gate.complete();
    await tester.pumpAndSettle();

    expect(calls.length, 2);
    expect(calls[0].ops.single, {'op': 'remove', 'position': 1});
    expect(calls[0].version, 4);
    // t2 sits at index 1 once t1 is gone, and the op is posted against the
    // version the FIRST op produced — no 409, nothing silently discarded.
    expect(calls[1].ops.single, {'op': 'remove', 'position': 1});
    expect(calls[1].version, 5);
    expect(sim.tracks.map((t) => t.trackId).toList(), ['t0']);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 1'), findsNothing);
    expect(find.text('Title 2'), findsNothing);
  });

  testWidgets('a row pending removal is excluded from the ids handed to Apple Music', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0), _track(1), _track(2)],
    );
    final gate = Completer<void>();
    api.onApplyQueueOps = (id, ops, expectedVersion) async {
      await gate.future;
      throw NetworkException('offline');
    };
    final bridge = FakeBridge();
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-t1')), const Offset(-500, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('play-button')));
    await tester.pumpAndSettle();

    expect(bridge.playCalls.single, ['apple-0', 'apple-2']);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a MusicKit failure while playing shows a snackbar carrying the real reason', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    bridge.onPlayQueue = (_) async => throw MusicKitException('boom');
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('play-button')));
    await tester.pumpAndSettle();

    // The bridge message (Apple's actual failure reason) must reach the
    // user — a generic string made device failures undiagnosable.
    expect(find.text("couldn't play — boom"), findsOneWidget);
  });

  testWidgets('a partially-failed save reports the failure count', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(), messages: [], queue: [_track(0), _track(1)]);
    final bridge = FakeBridge();
    bridge.onCreatePlaylist = (name, ids) async => (added: 1, failed: 1);
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.text('saved 1 songs to Apple Music (1 failed)'), findsOneWidget);
  });

  group('session events (P4 Task 4)', () {
    testWidgets('a successful play posts exactly one "played" event for this session', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [_track(0), _track(1)],
      );
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('play-button')));
      await tester.pumpAndSettle();

      expect(api.postedEvents, [(sessionId: 's1', type: 'played')]);
    });

    testWidgets('a successful save posts exactly one "saved_playlist" event for this session', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(title: 'Road Trip'), messages: [], queue: [_track(0)]);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();

      expect(api.postedEvents, [(sessionId: 's1', type: 'saved_playlist')]);
    });

    testWidgets('a save that added zero tracks posts NO event — a false taste signal', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(title: 'Road Trip'), messages: [], queue: [_track(0)]);
      final bridge = FakeBridge();
      bridge.onCreatePlaylist = (name, ids) async => (added: 0, failed: 1);
      final container = _makeContainer(api, bridge: bridge);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();

      expect(find.text('saved 0 songs to Apple Music (1 failed)'), findsOneWidget);
      expect(api.postedEvents, isEmpty);
    });

    testWidgets('a MusicKit failure while playing posts NO event at all', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final bridge = FakeBridge();
      bridge.onPlayQueue = (_) async => throw MusicKitException('boom');
      final container = _makeContainer(api, bridge: bridge);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('play-button')));
      await tester.pumpAndSettle();

      expect(api.postedEvents, isEmpty);
    });

    testWidgets('a failing event post never surfaces — the success snackbar still shows', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      api.onPostSessionEvent = (id, type) async => throw NetworkException('offline');
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('play-button')));
      await tester.pumpAndSettle();

      // The event post failed (silently — never awaited by the UI), but the
      // bridge succeeded, so the normal success snackbar must still show.
      expect(find.text('playing in Apple Music'), findsOneWidget);
      // Nothing unhandled — pumpAndSettle above would have surfaced a
      // FlutterError from an uncaught async exception otherwise.
    });

    testWidgets('rebuilding the screen (no new play/save) posts no additional events', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('play-button')));
      await tester.pumpAndSettle();
      expect(api.postedEvents, hasLength(1));

      // Force a few rebuilds unrelated to play/save.
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(api.postedEvents, hasLength(1));
    });
  });

  testWidgets('with the queue screen stacked over the chat screen, only the top route shows the snackbar', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(queueVersion: 1), messages: [], queue: [_track(0)]);
    api.onApplyQueueOps = (id, ops, expectedVersion) async =>
        throw StaleQueueException(queue: [_track(0)], queueVersion: 9);
    final container = _makeContainer(api);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ChatScreen(sessionId: 's1')),
      ),
    );
    await tester.pumpAndSettle();

    tester.state<NavigatorState>(find.byType(Navigator)).push(
      MaterialPageRoute<void>(builder: (_) => const QueueScreen(sessionId: 's1')),
    );
    await tester.pumpAndSettle();

    await container.read(chatProvider('s1').notifier).applyOps([const QueueOp.remove(0)]);
    await tester.pumpAndSettle();

    expect(find.text('queue was updated — showing the latest'), findsOneWidget);

    // Both screens' listeners fired; only the top route may show/clear the
    // one-shot error. If the covered ChatScreen showed one too, a SECOND
    // snackbar would be queued behind this one and surface as it expires.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('queue was updated — showing the latest'), findsNothing);
  });
}
