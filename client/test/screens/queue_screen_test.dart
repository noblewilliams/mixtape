import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoTextField, CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/playback/listening_meter.dart' show PlayerSample;
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/widgets/lyric_turn.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';
import 'package:mixtape/presentation/widgets/music_door.dart';
import 'package:mixtape/presentation/widgets/spotify_handoff_sheets.dart';
import 'package:mixtape/presentation/widgets/tape_header.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/track_row.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../helpers/fake_listening_api.dart';
import '../helpers/fake_clipboard_writer.dart';
import '../helpers/onboarding_harness.dart' show FakeLinkOpener;

/// Mirrors chat_screen_test.dart's FakeDjApi: implements DjApi's public
/// surface (not `extends`, since DjApi's constructor builds a real
/// ApiClient), each method delegating to a settable callback that throws
/// loudly when unset rather than hanging. [DjRemakeSender] answers the
/// tape's Remake.
class FakeDjApi implements DjApi, DjRemakeSender {
  final creationReceipts = <({String sessionId, String libraryId})>[];
  @override
  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) async {
    creationReceipts.add((sessionId: sessionId, libraryId: appleLibraryId));
    throw Exception('receipt upload offline');
  }

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
  Future<void> Function(String sessionId, String type)? onPostSessionEvent;
  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

  /// Every session event posted, in order — most tests just want the count
  /// and type, so this captures both rather than wiring a callback per test.
  final List<({String sessionId, String type})> postedEvents = [];

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<AlbumPickState> choosePick(String sessionId, {required String albumId, int? expectedVersion}) =>
      throw UnimplementedError();

  @override
  Future<AlbumPickState> goBackToPick(String sessionId, {required int version, int? expectedVersion}) =>
      throw UnimplementedError();

  @override
  Future<List<ListenLaterEntry>> listListenLater() => throw UnimplementedError();

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) => throw UnimplementedError();

  @override
  Future<void> unsaveForLater(String albumId) => throw UnimplementedError();

  @override
  Future<ListenLaterEntry> markListened(String albumId) => throw UnimplementedError();

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) {
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

  Future<TurnResult> Function(String id)? onSendRemake;

  /// The session id of every [sendRemake], in call order.
  final List<String> remakes = [];

  @override
  Future<TurnResult> sendRemake(String id) {
    remakes.add(id);
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
  Future<DjSession> setCaseColor(String id, String caseColor) =>
      throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) =>
      throw UnimplementedError();

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
  Future<({int added, int failed})> Function(
    String name,
    List<String> appleIds,
  )?
  onCreatePlaylist;

  final List<List<String>> playCalls = [];
  final List<
    ({String name, List<String> ids, String? author, String? description})
  >
  createCalls = [];

  @override
  Future<bool> requestAuthorization() => throw UnimplementedError();

  @override
  Future<LibraryPage> fetchLibrarySongs({
    required int offset,
    required int limit,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistSnapshotHeader> beginPlaylistSnapshot() =>
      throw UnimplementedError();

  @override
  Future<PlaylistSnapshotPage> fetchPlaylistSnapshotPage({
    required String snapshotId,
    required int offset,
    required int limit,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistEntryPage> fetchPlaylistEntryPage({
    required String snapshotId,
    required String playlistAppleId,
    required int offset,
    required int limit,
  }) => throw UnimplementedError();

  @override
  Future<bool> cancelPlaylistSnapshot() => throw UnimplementedError();

  @override
  Future<bool> releasePlaylistSnapshot(String snapshotId) =>
      throw UnimplementedError();

  @override
  Future<bool> playAlbum(String appleAlbumId) => throw UnimplementedError();

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
    void Function(String libraryId)? onCreated,
  }) {
    createCalls.add((
      name: name,
      ids: appleIds,
      author: author,
      description: description,
    ));
    final impl = onCreatePlaylist;
    return (impl == null
            ? Future.value((added: appleIds.length, failed: 0))
            : impl(name, appleIds))
        .then((result) {
          onCreated?.call('p.created');
          return result;
        });
  }
}

/// authProvider override settled at a stable session status — no real
/// keychain restore, no async transition mid-test (same pattern used across
/// dj_providers_test.dart and chat_screen_test.dart).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

DjSession _session({
  String id = 's1',
  int queueVersion = 1,
  String title = 'Test Session',
  bool notPersonal = false,
}) => DjSession(
  id: id,
  title: title,
  status: 'active',
  queueVersion: queueVersion,
  updatedAt: DateTime(2026, 1, 1),
  notPersonal: notPersonal,
);

QueueTrack _track(
  int position, {
  Object? appleId = _sentinel,
  String? spotifyId,
  String? reason,
  int? durationMs = 180000,
}) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: identical(appleId, _sentinel)
      ? 'apple-$position'
      : appleId as String?,
  spotifyId: spotifyId,
  title: 'Title $position',
  artist: 'Artist $position',
  reason: reason,
  durationMs: durationMs,
);

/// A track Apple Music has no match for, but Spotify does.
QueueTrack _spotifyTrack(int position) =>
    _track(position, appleId: null, spotifyId: 'sp$position');

const _sentinel = Object();

QueueTrack _renumbered(QueueTrack track, int position) => QueueTrack(
  position: position,
  trackId: track.trackId,
  appleId: track.appleId,
  spotifyId: track.spotifyId,
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
      } else if (json['op'] == 'insert') {
        final position = (json['position'] as int).clamp(0, next.length);
        next.insert(
          position,
          QueueTrack(
            position: position,
            trackId: json['trackId'] as String,
            appleId: 'apple-restored',
            title: 'Restored',
            artist: 'Restored',
            durationMs: 180000,
          ),
        );
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
  FakeListeningApi? listening,
  FunnelOnceStore? milestones,
  FakeLinkOpener? links,
  LinkProbe? probe,
  FakeClipboardWriter? clipboard,
  MusicPlatformStore? destinations,
  PlaybackController? player,
}) {
  final container = ProviderContainer(
    overrides: [
      musicPlatformStoreProvider.overrideWithValue(
        destinations ?? InMemoryMusicPlatformStore(),
      ),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
      musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
      // The real store hits the keychain platform channel, which doesn't
      // exist under testWidgets.
      authorStoreProvider.overrideWithValue(
        authorStore ?? InMemoryAuthorStore(),
      ),
      // The real provider hits GET /me over the network.
      accountNameProvider.overrideWith((ref) async => accountName),
      // The Spotify outputs: the funnel milestones read the listener from the
      // onboarding state and remember themselves in the keychain; links and
      // the share sheet are platform channels.
      listeningApiProvider.overrideWithValue(listening ?? FakeListeningApi()),
      servicePreferenceStoreProvider.overrideWithValue(
        InMemoryServicePreferenceStore(),
      ),
      funnelOnceStoreProvider.overrideWithValue(
        milestones ?? InMemoryFunnelOnceStore(),
      ),
      linkOpenerProvider.overrideWithValue((links ?? FakeLinkOpener()).call),
      linkProbeProvider.overrideWithValue(probe ?? (_) async => false),
      clipboardWriterProvider.overrideWithValue(
        clipboard ?? FakeClipboardWriter(),
      ),
      // The real controller reaches the player method channel and GET
      // /playback; the screen watches it to know whether THIS mix is playing.
      playbackProvider.overrideWithValue(
        player ?? PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  String sessionId = 's1',
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  // A second container in one test: tear the first tree down first, or the
  // same-typed root is updated in place and the old screen's state lingers.
  if (find.byType(QueueScreen).evaluate().isNotEmpty) {
    await tester.pumpWidget(const SizedBox());
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme ?? MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: QueueScreen(sessionId: sessionId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// An app player that cannot start: Play then sends the mix to the Music
/// app (decision 4 of the one-platform spec), the one path to Apple's own
/// player now that the arrow menu is gone.
PlaybackController _appPlayerRefuses() {
  // The controller persists its pending listening events; without this the
  // keychain channel hangs under testWidgets.
  FlutterSecureStorage.setMockInitialValues({});
  return PlaybackController(
    playback.FakeApi(),
    playback.FakeBridge()..failStart = true,
  );
}

/// Play, on a container built with [_appPlayerRefuses]: the mix lands in the
/// Music app.
Future<void> _playInMusic(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('play-here-button')));
}

/// Whether [a] comes before [b] in reading order (row, then position).
bool _precedes(WidgetTester tester, Finder a, Finder b) {
  final first = tester.getTopLeft(a);
  final second = tester.getTopLeft(b);
  return first.dy < second.dy ||
      (first.dy == second.dy && first.dx < second.dx);
}

void main() {
  testWidgets('rows render with 1-based numbering', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0), _track(1), _track(2)],
    );
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Title 0'), findsOneWidget);
    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Title 2'), findsOneWidget);
  });

  testWidgets(
    'dismissing a row applies a remove op at its 0-based position, against the current version',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 4),
        messages: [],
        queue: [_track(0), _track(1)],
      );
      List<QueueOp>? capturedOps;
      int? capturedVersion;
      api.onApplyQueueOps = (id, ops, expectedVersion) async {
        capturedOps = ops;
        capturedVersion = expectedVersion;
        return QueueOpsResult(
          queueVersion: 5,
          requested: 1,
          added: 0,
          removed: 1,
          queue: [_track(0)],
        );
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.drag(
        find.byKey(const Key('dismissible-t1')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();

      expect(capturedOps, isNotNull);
      expect(capturedOps!.single.toJson(), {'op': 'remove', 'position': 1});
      expect(capturedVersion, 4);
    },
  );

  testWidgets(
    'dragging a row down sends a move op whose target is the raw newIndex minus one',
    (tester) async {
      final api = FakeDjApi();
      final sim = _QueueSim([_track(0), _track(1), _track(2), _track(3)], 2);
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [],
        queue: [...sim.tracks],
      );
      List<QueueOp>? capturedOps;
      api.onApplyQueueOps = (id, ops, expectedVersion) async {
        capturedOps = ops;
        return sim.apply(ops, expectedVersion);
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      final rowHeight = tester
          .getSize(find.byKey(const Key('dismissible-t0')))
          .height;
      final handle = find.byKey(const Key('drag-handle-t0'));

      // Drags the top row (index 0) downward. Flutter's raw newIndex for a
      // downward drag overshoots by one — it's computed before the dragged
      // item is taken out of the list — so this deterministic gesture reports
      // 2 and the op must carry the corrected 1. Four rows, so BOTH the
      // corrected target and the raw one are valid in-range positions and the
      // assertion below can actually tell them apart.
      // The grip lifts on a long press, per the approved record, so the
      // gesture has to hold before it moves.
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(Offset(0, rowHeight * 2.5));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(capturedOps, isNotNull);
      // Pinned to the EXACT target, not just "somewhere after 0": dropping the
      // decrement would send move(0, 2) here, which this assertion catches.
      expect(capturedOps!.single.toJson(), {'op': 'move', 'from': 0, 'to': 1});
      expect(sim.tracks.map((t) => t.trackId).toList(), [
        't1',
        't0',
        't2',
        't3',
      ]);
    },
  );

  testWidgets(
    'a stale queue-ops response rebuilds the list and shows a snackbar',
    (tester) async {
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
      await _pump(tester, container);

      await container.read(chatProvider('s1').notifier).applyOps([
        const QueueOp.remove(0),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text(arrangementConflictMessage), findsOneWidget);
      expect(find.text('Title 0'), findsOneWidget);
      expect(find.text('Title 1'), findsOneWidget);
    },
  );

  testWidgets(
    'play sends appleIds to the bridge in queue order and shows a success snackbar',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [_track(0), _track(1), _track(2)],
      );
      final bridge = FakeBridge();
      final container = _makeContainer(api, player: _appPlayerRefuses(), bridge: bridge);
      await _pump(tester, container);

      await _playInMusic(tester);
      await tester.pumpAndSettle();

      expect(bridge.playCalls.single, ['apple-0', 'apple-1', 'apple-2']);
      expect(find.text('Playing in Apple Music'), findsOneWidget);
    },
  );

  testWidgets(
    'tracks with no Apple Music match are filtered before playing, and the skip count is reported',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [_track(0), _track(1, appleId: null), _track(2)],
      );
      final bridge = FakeBridge();
      final container = _makeContainer(api, player: _appPlayerRefuses(), bridge: bridge);
      await _pump(tester, container);

      await _playInMusic(tester);
      await tester.pumpAndSettle();

      expect(bridge.playCalls.single, ['apple-0', 'apple-2']);
      expect(
        find.text(
          'Playing in Apple Music · 1 song skipped (not in Apple Music)',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'when every track lacks an Apple Music match, play and save are disabled',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [_track(0, appleId: null), _track(1, appleId: null)],
      );
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(
        tester
            .widget<LabelChip>(find.byKey(const Key('save-button')))
            .onPressed,
        isNull,
      );
      // Play does nothing either, and there is no arrow to try instead.
      await tester.tap(find.byKey(const Key('play-here-button')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      expect(find.byType(PlaybackScreen), findsNothing);
      // The reason is written beside the actions, never left to a tooltip.
      expect(find.text("these tracks aren't in Apple Music"), findsOneWidget);
      // Without a Spotify id either, there is nothing to send anywhere.
      expect(find.byKey(const Key('share-button')), findsNothing);
    },
  );

  testWidgets(
    'save dialog is prefilled with the session title, trims the entered name, and reports counts',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(title: 'Road Trip'),
        messages: [],
        queue: [_track(0), _track(1)],
      );
      final bridge = FakeBridge();
      final container = _makeContainer(api, bridge: bridge);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();

      final field = tester.widget<CupertinoTextField>(
        find.byKey(const Key('playlist-name-field')),
      );
      expect(field.controller!.text, 'Road Trip');

      await tester.enterText(
        find.byKey(const Key('playlist-name-field')),
        '  My Mix  ',
      );
      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.name, 'My Mix');
      expect(bridge.createCalls.single.ids, ['apple-0', 'apple-1']);
      // Attribution metadata: without an explicit author Apple stamps the
      // playlist with the Xcode product name ("Runner").
      expect(bridge.createCalls.single.author, 'mixtape');
      expect(bridge.createCalls.single.description, 'made by mixtape');
      expect(find.text('Saved 2 songs to Apple Music'), findsOneWidget);
    },
  );

  testWidgets(
    'a typed author is stamped on the playlist and remembered for the next save',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(title: 'Road Trip'),
        messages: [],
        queue: [_track(0)],
      );
      final bridge = FakeBridge();
      final store = InMemoryAuthorStore();
      final container = _makeContainer(api, bridge: bridge, authorStore: store);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playlist-author-field')),
        '  Noble  ',
      );
      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.author, 'Noble');
      expect(await store.read(), 'Noble');

      // Reopening the dialog prefills the remembered name.
      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      final authorField = tester.widget<CupertinoTextField>(
        find.byKey(const Key('playlist-author-field')),
      );
      expect(authorField.controller!.text, 'Noble');
    },
  );

  testWidgets(
    'with nothing typed on this device, the account name is the author default',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final bridge = FakeBridge();
      final container = _makeContainer(
        api,
        bridge: bridge,
        accountName: 'Noble',
      );
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      final authorField = tester.widget<CupertinoTextField>(
        find.byKey(const Key('playlist-author-field')),
      );
      expect(authorField.controller!.text, 'Noble');

      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();
      expect(bridge.createCalls.single.author, 'Noble');
    },
  );

  testWidgets('a device-typed author beats the account name', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
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
    final authorField = tester.widget<CupertinoTextField>(
      find.byKey(const Key('playlist-author-field')),
    );
    expect(authorField.controller!.text, 'DJ Noble');
  });

  testWidgets(
    'a stored author prefills the dialog and rides the save unchanged',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
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
    },
  );

  testWidgets(
    'a whitespace-only playlist name disables saving',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(title: 'Road Trip'),
        messages: [],
        queue: [_track(0)],
      );
      final bridge = FakeBridge();
      final container = _makeContainer(api, bridge: bridge);
      await _pump(tester, container);

      await tester.tap(find.byKey(const Key('save-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('playlist-name-field')),
        '   ',
      );
      await tester.tap(find.byKey(const Key('save-confirm-button')));
      await tester.pumpAndSettle();

      expect(bridge.createCalls, isEmpty);
      expect(tester.widget<CupertinoDialogAction>(find.byKey(const Key('save-confirm-button'))).onPressed, isNull);
    },
  );

  testWidgets(
    'tapping Save twice while the first call is in flight only creates one playlist',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
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
      expect(find.text('Saved 1 songs to Apple Music'), findsOneWidget);
    },
  );

  testWidgets('a save Apple refuses reports the reason it gave', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
    final bridge = FakeBridge();
    bridge.onCreatePlaylist = (name, ids) async =>
        throw MusicKitException('not authorized');
    await _pump(tester, _makeContainer(api, bridge: bridge));

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('playlist-name-field')), findsOneWidget);
    expect(tester.widget<CupertinoTextField>(find.byKey(const Key('playlist-name-field'))).controller!.text, 'Test Session');
    expect(
      find.text("Couldn't save the playlist — not authorized"),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping a row reveals its reason; a row without one shows a placeholder',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [
          _track(0, reason: 'you loved this one last summer'),
          _track(1),
        ],
      );
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('you loved this one last summer'), findsNothing);
      expect(find.text('no notes from the DJ'), findsNothing);

      await tester.tap(find.byKey(TrackRow.rowKey('t0')));
      await tester.pumpAndSettle();
      expect(find.text('you loved this one last summer'), findsOneWidget);

      await tester.tap(find.byKey(TrackRow.rowKey('t1')));
      await tester.pumpAndSettle();
      expect(find.text('no notes from the DJ'), findsOneWidget);
    },
  );

  testWidgets('an empty queue shows a friendly empty state', (tester) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: _session(), messages: [], queue: []);
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.byKey(const Key('queue-empty')), findsOneWidget);
    expect(find.text('Nothing on the tape yet'), findsOneWidget);
    expect(
      find.text('Ask the DJ for a mix and it will show up here.'),
      findsOneWidget,
    );
    // Actions are hidden rather than disabled: there is nothing to act on.
    expect(find.byKey(const Key('play-here-button')), findsNothing);
    expect(find.byKey(const Key('save-button')), findsNothing);
  });

  testWidgets(
    'a failed (non-stale) removal un-hides the swiped row instead of losing it',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 4),
        messages: [],
        queue: [_track(0), _track(1)],
      );
      final gate = Completer<void>();
      api.onApplyQueueOps = (id, ops, expectedVersion) async {
        await gate.future;
        throw NetworkException('offline');
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.drag(
        find.byKey(const Key('dismissible-t1')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();

      // Hidden while the op is in flight (Dismissible requires that)...
      expect(find.text('Title 1'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      // ...and back the moment the op settles as a failure. The version never
      // moved here, so nothing but settle-based un-hiding can recover it.
      expect(find.text('Title 1'), findsOneWidget);
      expect(find.textContaining('check your connection'), findsOneWidget);
    },
  );

  testWidgets(
    'two rapid dismissals both land — the second resolves against the fresh queue and version',
    (tester) async {
      final sim = _QueueSim([_track(0), _track(1), _track(2)], 4);
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 4),
        messages: [],
        queue: [...sim.tracks],
      );
      final calls = <({List<Map<String, dynamic>> ops, int? version})>[];
      final gate = Completer<void>();
      api.onApplyQueueOps = (id, ops, expectedVersion) async {
        calls.add((
          ops: [for (final o in ops) o.toJson()],
          version: expectedVersion,
        ));
        if (calls.length == 1) await gate.future;
        return sim.apply(ops, expectedVersion);
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.drag(
        find.byKey(const Key('dismissible-t1')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('dismissible-t2')),
        const Offset(-500, 0),
      );
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
    },
  );

  testWidgets(
    'a row pending removal is excluded from the ids handed to Apple Music',
    (tester) async {
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
      final container = _makeContainer(api, player: _appPlayerRefuses(), bridge: bridge);
      await _pump(tester, container);

      await tester.drag(
        find.byKey(const Key('dismissible-t1')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();

      await _playInMusic(tester);
      await tester.pumpAndSettle();

      expect(bridge.playCalls.single, ['apple-0', 'apple-2']);

      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a MusicKit failure while playing says so plainly, without Apple\'s raw text',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final bridge = FakeBridge();
      bridge.onPlayQueue = (_) async => throw MusicKitException('boom');
      final container = _makeContainer(api, player: _appPlayerRefuses(), bridge: bridge);
      await _pump(tester, container);

      await _playInMusic(tester);
      await tester.pumpAndSettle();

      // Play's fallback never shows Apple's raw reason (it goes to the
      // device log instead): 2026-11-09 one-platform spec, decision 4.
      expect(find.text(mixPlayFallbackFailedMessage), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
    },
  );

  testWidgets('a partially-failed save reports the failure count', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onGetSession = (_) async => SessionDetail(
      session: _session(),
      messages: [],
      queue: [_track(0), _track(1)],
    );
    final bridge = FakeBridge();
    bridge.onCreatePlaylist = (name, ids) async => (added: 1, failed: 1);
    final container = _makeContainer(api, bridge: bridge);
    await _pump(tester, container);

    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Saved 1 songs to Apple Music (1 failed)'),
      findsOneWidget,
    );
  });

  group('session events (P4 Task 4)', () {
    testWidgets(
      'a successful play posts exactly one "played" event for this session',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0), _track(1)],
        );
        final container = _makeContainer(api, player: _appPlayerRefuses());
        await _pump(tester, container);

        await _playInMusic(tester);
        await tester.pumpAndSettle();

        expect(api.postedEvents, [(sessionId: 's1', type: 'played')]);
      },
    );

    testWidgets(
      'a successful save posts exactly one "saved_playlist" event for this session',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(title: 'Road Trip'),
          messages: [],
          queue: [_track(0)],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('save-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('save-confirm-button')));
        await tester.pumpAndSettle();

        expect(api.postedEvents, [(sessionId: 's1', type: 'saved_playlist')]);
        expect(api.creationReceipts, [
          (sessionId: 's1', libraryId: 'p.created'),
        ]);
      },
    );

    testWidgets(
      'a save that added zero tracks posts NO event — a false taste signal',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(title: 'Road Trip'),
          messages: [],
          queue: [_track(0)],
        );
        final bridge = FakeBridge();
        bridge.onCreatePlaylist = (name, ids) async => (added: 0, failed: 1);
        final container = _makeContainer(api, bridge: bridge);
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('save-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('save-confirm-button')));
        await tester.pumpAndSettle();

        expect(
          find.text('Saved 0 songs to Apple Music (1 failed)'),
          findsOneWidget,
        );
        expect(api.postedEvents, isEmpty);
      },
    );

    testWidgets('a MusicKit failure while playing posts NO event at all', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final bridge = FakeBridge();
      bridge.onPlayQueue = (_) async => throw MusicKitException('boom');
      final container = _makeContainer(api, player: _appPlayerRefuses(), bridge: bridge);
      await _pump(tester, container);

      await _playInMusic(tester);
      await tester.pumpAndSettle();

      expect(api.postedEvents, isEmpty);
    });

    testWidgets(
      'a failing event post never surfaces — the success snackbar still shows',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0)],
        );
        api.onPostSessionEvent = (id, type) async =>
            throw NetworkException('offline');
        final container = _makeContainer(api, player: _appPlayerRefuses());
        await _pump(tester, container);

        await _playInMusic(tester);
        await tester.pumpAndSettle();

        // The event post failed (silently — never awaited by the UI), but the
        // bridge succeeded, so the normal success snackbar must still show.
        expect(find.text('Playing in Apple Music'), findsOneWidget);
        // Nothing unhandled — pumpAndSettle above would have surfaced a
        // FlutterError from an uncaught async exception otherwise.
      },
    );

    testWidgets(
      'rebuilding the screen (no new play/save) posts no additional events',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0)],
        );
        final container = _makeContainer(api, player: _appPlayerRefuses());
        await _pump(tester, container);

        await _playInMusic(tester);
        await tester.pumpAndSettle();
        expect(api.postedEvents, hasLength(1));

        // Force a few rebuilds unrelated to play/save.
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        expect(api.postedEvents, hasLength(1));
      },
    );
  });

  testWidgets(
    'with the queue screen stacked over the chat screen, only the top route shows the snackbar',
    (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [],
        queue: [_track(0)],
      );
      api.onApplyQueueOps = (id, ops, expectedVersion) async =>
          throw StaleQueueException(queue: [_track(0)], queueVersion: 9);
      final container = _makeContainer(api);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: const ChatScreen(sessionId: 's1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const QueueScreen(sessionId: 's1'),
            ),
          );
      await tester.pumpAndSettle();

      await container.read(chatProvider('s1').notifier).applyOps([
        const QueueOp.remove(0),
      ]);
      await tester.pumpAndSettle();

      expect(find.text(arrangementConflictMessage), findsOneWidget);

      // Both screens' listeners fired; only the top route may show/clear the
      // one-shot error. If the covered ChatScreen showed one too, a SECOND
      // snackbar would be queued behind this one and surface as it expires.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text(arrangementConflictMessage), findsNothing);
    },
  );

  group('Spotify outputs (C4)', () {
    const bannerLine =
        "From Mixtape's catalog for now. With your music, the DJ picks from what you actually play.";

    testWidgets(
      'a row with a Spotify id gets a keyed 44pt "Open in Spotify" action; rows without one get none',
      (tester) async {
        final handle = tester.ensureSemantics();
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0), _track(1)],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        final action = find.byKey(const Key('open-in-spotify-t0'));
        expect(action, findsOneWidget);
        expect(find.byKey(const Key('open-in-spotify-t1')), findsNothing);
        // "Open in Spotify: <title>" — the visible label is a prefix of the
        // accessible name, so voice control matches what a listener reads.
        expect(
          find.bySemanticsLabel('Open in Spotify: Title 0'),
          findsOneWidget,
        );
        final size = tester.getSize(action);
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
        // The row still expands on tap and still reorders from its handle.
        await tester.tap(find.byKey(TrackRow.rowKey('t0')));
        await tester.pumpAndSettle();
        expect(find.byKey(TrackRow.reasonKey('t0')), findsOneWidget);
        // A Spotify row trades its grip for the open action; the Apple row
        // keeps the grip.
        expect(find.byKey(TrackRow.gripKey('t0')), findsNothing);
        expect(find.byKey(TrackRow.gripKey('t1')), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'Open in Spotify asks whether the app can open the scheme and uses it when it can',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        final links = FakeLinkOpener();
        final probed = <Uri>[];
        final container = _makeContainer(
          api,
          links: links,
          probe: (uri) async {
            probed.add(uri);
            return true;
          },
        );
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('open-in-spotify-t0')));
        await tester.pumpAndSettle();

        expect(probed, [Uri.parse('spotify:track:sp0')]);
        expect(links.opened, [Uri.parse('spotify:track:sp0')]);
      },
    );

    testWidgets(
      'Open in Spotify falls back to the https link when the app cannot be opened or the probe fails',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        final links = FakeLinkOpener();
        final container = _makeContainer(
          api,
          links: links,
          probe: (_) async => false,
        );
        await _pump(tester, container);
        await tester.tap(find.byKey(const Key('open-in-spotify-t0')));
        await tester.pumpAndSettle();
        expect(links.opened, [Uri.parse('https://open.spotify.com/track/sp0')]);

        final throwing = FakeLinkOpener();
        final container2 = _makeContainer(
          api,
          links: throwing,
          probe: (_) async => throw StateError('no channel'),
        );
        await _pump(tester, container2);
        await tester.tap(find.byKey(const Key('open-in-spotify-t0')));
        await tester.pumpAndSettle();
        expect(throwing.opened, [
          Uri.parse('https://open.spotify.com/track/sp0'),
        ]);
      },
    );

    testWidgets(
      'an Apple Music device keeps Play and Create playlist on a Spotify-only queue, inert, with why',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0), _spotifyTrack(1)],
        );
        final container = _makeContainer(
          api,
          destinations: InMemoryMusicPlatformStore(MusicPlatform.apple),
        );
        await _pump(tester, container);

        expect(
          tester
              .widget<TapeButton>(find.byKey(const Key('play-here-button')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<LabelChip>(find.byKey(const Key('save-button')))
              .onPressed,
          isNull,
        );
        expect(find.byKey(const Key('share-button')), findsNothing);
        expect(find.text("these tracks aren't in Apple Music"), findsOneWidget);
      },
    );

    testWidgets(
      'a Spotify device gets one Create playlist, no Play, and a search link on every row',
      (tester) async {
        final api = FakeDjApi();
        // A catalogue mix: Apple ids only.
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0), _track(1)],
        );
        final links = FakeLinkOpener();
        final container = _makeContainer(
          api,
          links: links,
          listening: FakeListeningApi(
            onboarding: onboardingState(chosenService: 'spotify'),
          ),
        );
        await _pump(tester, container);

        final share = find.byKey(const Key('share-button'));
        expect(tester.widget<TapeButton>(share).label, 'Create playlist');
        expect(find.byKey(const Key('play-here-button')), findsNothing);
        expect(find.byKey(const Key('save-button')), findsNothing);
        expect(find.text("these tracks aren't in Apple Music"), findsNothing);

        await tester.tap(find.byKey(const Key('open-in-spotify-t0')));
        await tester.pumpAndSettle();
        expect(links.opened, [
          Uri.parse('https://open.spotify.com/search/Artist%200%20Title%200'),
        ]);
      },
    );

    testWidgets(
      'a mixed Apple + Spotify queue on Apple Music: Play then Create playlist, Spotify rows open in Spotify',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0), _spotifyTrack(1)],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        final play = find.byKey(const Key('play-here-button'));
        final save = find.byKey(const Key('save-button'));
        expect(play, findsOneWidget);
        expect(tester.widget<LabelChip>(save).onPressed, isNotNull);
        expect(_precedes(tester, play, save), isTrue);
        expect(find.byKey(const Key('share-button')), findsNothing);
        expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
        expect(find.byKey(const Key('open-in-spotify-t0')), findsNothing);
        expect(find.byKey(const Key('open-in-spotify-t1')), findsOneWidget);
      },
    );

    testWidgets('an Apple Music device offers no transfer handoff', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [],
        queue: [_track(0), _spotifyTrack(1)],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('play-here-button')), findsOneWidget);
      expect(find.byKey(const Key('share-button')), findsNothing);
    });

    testWidgets(
      'Spotify Create playlist explains once, then copies every song and opens TuneMyMusic',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(title: 'Late drive'),
          messages: [],
          // A track with neither id still goes into the list: the tool searches by name.
          queue: [_spotifyTrack(0), _spotifyTrack(1), _track(2, appleId: null)],
        );
        final clipboard = FakeClipboardWriter();
        final links = FakeLinkOpener();
        final store = InMemoryMusicPlatformStore(MusicPlatform.spotify);
        final container = _makeContainer(
          api,
          clipboard: clipboard,
          links: links,
          destinations: store,
        );
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('share-button')));
        await tester.pumpAndSettle();

        // The first time: what is about to happen, before anything does.
        expect(find.text(SpotifyHandoffSheet.headline), findsOneWidget);
        expect(find.text(SpotifyHandoffSheet.lineFor(3)), findsOneWidget);
        expect(clipboard.copies, isEmpty);
        expect(links.opened, isEmpty);

        await tester.tap(find.byKey(SpotifyHandoffSheet.goKey));
        await tester.pumpAndSettle();

        expect(clipboard.copies, [
          'Artist 0 - Title 0\nArtist 1 - Title 1\nArtist 2 - Title 2',
        ]);
        expect(links.opened, [
          Uri.parse('https://www.tunemymusic.com/transfer/freetext-to-spotify'),
        ]);
        expect(
          find.text('Copied 3 songs · paste them in, then rename “My Playlist”'),
          findsOneWidget,
        );
        expect(await store.spotifyIntroSeen(), isTrue);

        // After that, a tap goes straight there.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('share-button')));
        await tester.pumpAndSettle();
        expect(find.text(SpotifyHandoffSheet.headline), findsNothing);
        expect(clipboard.copies, hasLength(2));
        expect(links.opened, hasLength(2));
      },
    );

    testWidgets(
      'closing the explainer copies nothing and counts as no output',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        final clipboard = FakeClipboardWriter();
        final listening = FakeListeningApi();
        final links = FakeLinkOpener();
        final store = InMemoryMusicPlatformStore(MusicPlatform.spotify);
        final container = _makeContainer(
          api,
          clipboard: clipboard,
          listening: listening,
          links: links,
          destinations: store,
        );
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('share-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(SpotifyHandoffSheet.cancelKey));
        await tester.pumpAndSettle();

        expect(find.text(SpotifyHandoffSheet.headline), findsNothing);
        expect(clipboard.copies, isEmpty);
        expect(links.opened, isEmpty, reason: 'no handoff, no transfer tool');
        expect(listening.funnelEvents, isEmpty);
        expect(await store.spotifyIntroSeen(), isFalse);
      },
    );

    testWidgets(
      'the "Not personal yet" banner shows above a corpus-mode queue as a live region, and not otherwise',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(notPersonal: true),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        final banner = find.byKey(const Key('not-personal-banner'));
        expect(banner, findsOneWidget);
        expect(tester.widget<MusicDoor>(banner).layout, MusicDoorLayout.tape);
        final region = find.descendant(
          of: banner,
          matching: find.byKey(MusicDoor.lineKey),
        );
        expect(tester.widget<Semantics>(region).properties.liveRegion, isTrue);
        expect(find.text('Not personal yet'), findsOneWidget);
        expect(find.text(bannerLine), findsOneWidget);
        // The listener's service is Apple Music (the fake's onboarding).
        expect(
          find.descendant(of: banner, matching: find.text('Sync Apple Music')),
          findsOneWidget,
        );
        expect(
          tester.getBottomLeft(banner).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byKey(const Key('queue-row-t0'))).dy,
          ),
        );
        expect(find.byKey(const Key('open-in-spotify-t0')), findsOneWidget);

        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        await _pump(tester, _makeContainer(api));
        expect(find.byKey(const Key('not-personal-banner')), findsNothing);
        expect(find.text('Not personal yet'), findsNothing);
      },
    );

    testWidgets(
      'first_output posts once per listener across Open in Spotify and the share handoff',
      (tester) async {
        final listening = FakeListeningApi();
        final milestones = InMemoryFunnelOnceStore();
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0), _spotifyTrack(1)],
        );
        final container = _makeContainer(
          api,
          listening: listening,
          milestones: milestones,
          player: _appPlayerRefuses(),
        );
        await _pump(tester, container);

        await tester.tap(find.byKey(const Key('open-in-spotify-t1')));
        await tester.pumpAndSettle();
        expect(listening.funnelEvents, [FunnelEventType.firstOutput]);
        expect(
          await milestones.has('user-1', FunnelEventType.firstOutput),
          isTrue,
        );

        // Play is an Apple output, not a Spotify one: it adds nothing here.
        await tester.tap(find.byKey(const Key('play-here-button')));
        await tester.pumpAndSettle();
        expect(listening.funnelEvents, [FunnelEventType.firstOutput]);

        // A later screen on the same device and account: the flag outlives it.
        final api2 = FakeDjApi();
        api2.onGetSession = (_) async => SessionDetail(
          session: _session(id: 's2'),
          messages: [],
          queue: [_spotifyTrack(0)],
        );
        await _pump(
          tester,
          _makeContainer(
            api2,
            listening: listening,
            milestones: milestones,
            destinations: InMemoryMusicPlatformStore(MusicPlatform.spotify),
          ),
          sessionId: 's2',
        );
        await tester.tap(find.byKey(const Key('share-button')));
        await tester.pumpAndSettle();
        expect(listening.funnelEvents, [FunnelEventType.firstOutput]);
      },
    );

    testWidgets(
      'Play is an Apple output, not a Spotify one: it posts no funnel event',
      (tester) async {
        final listening = FakeListeningApi();
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0)],
        );
        final container = _makeContainer(api, player: _appPlayerRefuses(), listening: listening);
        await _pump(tester, container);

        await _playInMusic(tester);
        await tester.pumpAndSettle();

        expect(find.text('Playing in Apple Music'), findsOneWidget);
        // The session event still lands; only the funnel milestone is Spotify's.
        expect(api.postedEvents.map((e) => e.type), ['played']);
        expect(listening.funnelEvents, isEmpty);
      },
    );
  });

  group('chrome, meta and version history', () {
    testWidgets(
      'the header: Back and More only; the title appears once the cassette '
      'scrolls away',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(title: 'Night bus notes'),
          messages: [],
          queue: [for (var i = 0; i < 20; i++) _track(i)],
        );
        await _pump(tester, _makeContainer(api));

        expect(find.byKey(const Key('arrangement-back')), findsOneWidget);
        expect(find.byKey(const Key('arrangement-history')), findsNothing);
        expect(find.byKey(const Key('arrangement-more')), findsOneWidget);
        expect(find.byType(AppBar), findsNothing);
        // The cassette header leads, in the tape colour, tilted.
        expect(find.byKey(TapeHeader.cassetteKey), findsOneWidget);
        expect(
          tester.widget<CassetteTile>(find.byKey(TapeHeader.cassetteKey)).width,
          150,
        );
        expect(find.byKey(TapeHeader.titleKey), findsOneWidget);
        AnimatedOpacity navTitle() => tester.widget<AnimatedOpacity>(
          find.byKey(const Key('arrangement-nav-title')),
        );
        expect(navTitle().opacity, 0);

        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(navTitle().opacity, 1);
        // The bar at the bottom stays put.
        expect(find.byKey(const Key('play-here-button')).hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('save-button')).hitTestable(), findsOneWidget);
      },
    );

    testWidgets('More holds Version history, which pushes the history screen', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.byKey(const Key('arrangement-more')));
      await tester.pumpAndSettle();
      expect(find.text('Tape settings'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      await tester.tap(find.text('Version history'));
      // A single pump, not pumpAndSettle: the history screen's own load is
      // not this screen's business (and reaches a real client here).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(MixHistoryScreen), findsOneWidget);
    });

    testWidgets('every cassette wears the saved tape colour', (tester) async {
      final api = FakeDjApi();
      final saved = DjSession(
        id: 's1',
        title: 'Lagos',
        status: 'active',
        queueVersion: 2,
        updatedAt: DateTime(2026, 1, 1),
        caseColor: '#617f9c',
      );
      api.onListSessions = () async => [saved];
      api.onGetSession = (_) async =>
          SessionDetail(session: saved, messages: [], queue: [_track(0)]);
      await _pump(tester, _makeContainer(api));
      expect(
        tester.widget<CassetteTile>(find.byKey(TapeHeader.cassetteKey)).caseColor,
        const Color(0xFF617F9C),
      );
    });

    testWidgets(
      'the meta line counts songs, sums the durations and names the version',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 2),
          messages: [],
          // 3 x 3 min.
          queue: [_track(0), _track(1), _track(2)],
        );
        await _pump(tester, _makeContainer(api));

        expect(find.text('3 songs · 9 min · version 2'), findsOneWidget);
        // The hint sits under the last song.
        expect(
          tester.getTopLeft(find.text('Tap a song for its note')).dy,
          greaterThan(tester.getBottomLeft(find.text('Title 2')).dy),
        );
      },
    );

    testWidgets('an hour or more reads as "H h MM"', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 5),
        messages: [],
        queue: [for (var i = 0; i < 24; i++) _track(i, durationMs: 180000)],
      );
      await _pump(tester, _makeContainer(api));

      // 24 x 3 min = 72 min.
      expect(find.text('24 songs · 1 h 12 · version 5'), findsOneWidget);
    });

    testWidgets('an unknown duration is omitted rather than reported short', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [],
        queue: [_track(0), _track(1, durationMs: null)],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.text('2 songs · version 1'), findsOneWidget);
    });
  });

  group('Play now', () {
    testWidgets(
      'hands the arrangement to the app player and opens Now Playing',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 3, title: 'Night bus'),
          messages: [],
          queue: [_track(0), _track(1)],
        );
        // The controller persists its pending listening events; without this
        // the keychain channel hangs under testWidgets.
        FlutterSecureStorage.setMockInitialValues({});
        final player = PlaybackController(
          playback.FakeApi(),
          playback.FakeBridge(),
        );
        addTearDown(player.dispose);
        await _pump(tester, _makeContainer(api, player: player));

        await tester.tap(find.byKey(const Key('play-here-button')));
        // Now Playing animates its meter, so a settle would never finish;
        // the controller's own start() awaits a couple of futures first.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(player.sessionId, 's1');
        expect(player.version, 3);
        expect(find.byType(PlaybackScreen), findsOneWidget);
      },
    );

    testWidgets('reads Playing while the app player is on THIS mix', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final player =
          PlaybackController(playback.FakeApi(), playback.FakeBridge())
            ..sessionId = 's1'
            ..sample = const PlayerSample(
              index: 0,
              positionMs: 0,
              status: 'playing',
            );
      addTearDown(player.dispose);
      await _pump(tester, _makeContainer(api, player: player));

      expect(find.text('Playing'), findsOneWidget);
      expect(find.byKey(MixHandoffKeys.meterKey), findsOneWidget);
    });

    testWidgets('another mix playing leaves this button as Play', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final player =
          PlaybackController(playback.FakeApi(), playback.FakeBridge())
            ..sessionId = 'another'
            ..sample = const PlayerSample(
              index: 0,
              positionMs: 0,
              status: 'playing',
            );
      addTearDown(player.dispose);
      await _pump(tester, _makeContainer(api, player: player));

      expect(find.text('Play'), findsOneWidget);
      expect(find.byKey(MixHandoffKeys.meterKey), findsNothing);
    });
  });

  group('remove with Undo', () {
    testWidgets(
      'a removal toasts the song and Undo re-inserts it at its old position',
      (tester) async {
        final api = FakeDjApi();
        final sim = _QueueSim([_track(0), _track(1), _track(2)], 4);
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 4),
          messages: [],
          queue: [...sim.tracks],
          supportsInsert: true,
        );
        final ops = <QueueOp>[];
        final versions = <int?>[];
        api.onApplyQueueOps = (id, posted, expectedVersion) async {
          ops.addAll(posted);
          versions.add(expectedVersion);
          return sim.apply(posted, expectedVersion);
        };
        await _pump(tester, _makeContainer(api));

        await tester.drag(
          find.byKey(const Key('dismissible-t1')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();

        expect(find.text('Removed "Title 1"'), findsOneWidget);
        expect(find.byType(MixtapeFeedback), findsOneWidget);
        expect(ops.single.toJson(), {'op': 'remove', 'position': 1});

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        expect(ops.last.toJson(), {
          'op': 'insert',
          'position': 1,
          'trackId': 't1',
        });
        // Posted against the version the removal produced, not the stale one.
        expect(versions, [4, 5]);
      },
    );

    testWidgets(
      'a second removal replaces the first toast, and Undo restores the latest',
      (tester) async {
        final api = FakeDjApi();
        final sim = _QueueSim([_track(0), _track(1), _track(2)], 1);
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [...sim.tracks],
          supportsInsert: true,
        );
        final ops = <QueueOp>[];
        api.onApplyQueueOps = (id, posted, expectedVersion) async {
          ops.addAll(posted);
          return sim.apply(posted, expectedVersion);
        };
        await _pump(tester, _makeContainer(api));

        await tester.drag(
          find.byKey(const Key('dismissible-t0')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('dismissible-t1')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();

        // One toast, naming the song that just went.
        expect(find.text('Removed "Title 0"'), findsNothing);
        expect(find.text('Removed "Title 1"'), findsOneWidget);
        expect(find.text('Undo'), findsOneWidget);

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        // Resolved against the queue as it stands (only t2 is left), not
        // against the position t1 held before the first removal.
        expect(ops.last.toJson(), {
          'op': 'insert',
          'position': 0,
          'trackId': 't1',
        });
      },
    );

    testWidgets(
      'without server support the toast names the song but offers no Undo',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0), _track(1)],
        );
        api.onApplyQueueOps = (id, ops, expectedVersion) async =>
            QueueOpsResult(
              queueVersion: 2,
              requested: 1,
              added: 0,
              removed: 1,
              queue: [_track(0)],
            );
        await _pump(tester, _makeContainer(api));

        await tester.drag(
          find.byKey(const Key('dismissible-t1')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();

        expect(find.text('Removed "Title 1"'), findsOneWidget);
        expect(find.text('Undo'), findsNothing);
      },
    );

    testWidgets(
      'a stale Undo refreshes to the server arrangement and says so',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 1),
          messages: [],
          queue: [_track(0), _track(1)],
          supportsInsert: true,
        );
        var call = 0;
        api.onApplyQueueOps = (id, ops, expectedVersion) async {
          call += 1;
          if (call == 1) {
            return QueueOpsResult(
              queueVersion: 2,
              requested: 1,
              added: 0,
              removed: 1,
              queue: [_track(0)],
            );
          }
          // Someone else moved the mix on while the toast was up.
          throw StaleQueueException(
            queue: [_track(0), _track(7)],
            queueVersion: 9,
          );
        };
        await _pump(tester, _makeContainer(api));

        await tester.drag(
          find.byKey(const Key('dismissible-t1')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        expect(find.text(arrangementConflictMessage), findsOneWidget);
        // The canonical arrangement is on screen.
        expect(find.text('Title 7'), findsOneWidget);
        expect(find.text('Title 1'), findsNothing);
      },
    );
  });

  group('VoiceOver reordering', () {
    testWidgets('Move up applies a move op against the current version', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final api = FakeDjApi();
      final sim = _QueueSim([_track(0), _track(1), _track(2)], 2);
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [],
        queue: [...sim.tracks],
      );
      List<QueueOp>? captured;
      int? version;
      api.onApplyQueueOps = (id, ops, expectedVersion) async {
        captured = ops;
        version = expectedVersion;
        return sim.apply(ops, expectedVersion);
      };
      await _pump(tester, _makeContainer(api));

      final node = tester.getSemantics(find.byKey(TrackRow.rowKey('t2')));
      // ignore: deprecated_member_use
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(TrackRow.moveUpAction),
      );
      await tester.pumpAndSettle();

      expect(captured!.single.toJson(), {'op': 'move', 'from': 2, 'to': 1});
      expect(version, 2);
      handle.dispose();
    });
  });

  group('states', () {
    testWidgets('a failed load with nothing on screen offers Try again', (
      tester,
    ) async {
      final api = FakeDjApi();
      var offline = true;
      api.onGetSession = (_) async {
        if (offline) throw Exception('offline');
        return SessionDetail(
          session: _session(),
          messages: [],
          queue: [_track(0)],
        );
      };
      await _pump(tester, _makeContainer(api));

      expect(find.text("Couldn't load this tape"), findsOneWidget);
      expect(
        find.text(
          'Check your connection and try again. The mix itself is safe.',
        ),
        findsOneWidget,
      );

      offline = false;
      await tester.tap(find.byKey(const Key('queue-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Title 0'), findsOneWidget);
    });

    testWidgets('the not-personal block sits above the list with a hairline', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(notPersonal: true),
        messages: [],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      final block = find.byKey(const Key('not-personal-banner'));
      expect(block, findsOneWidget);
      expect(find.text('Not personal yet'), findsOneWidget);
      expect(
        tester.getBottomLeft(block).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Title 0')).dy),
      );
    });

    testWidgets('renders at 320 with 200% text without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(notPersonal: true),
        messages: [],
        queue: [_track(0), _spotifyTrack(1)],
      );
      await _pump(
        tester,
        _makeContainer(api),
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      // The header is taller than a 320 x 640 phone at 200%, so the rows sit
      // below the fold — reachable by scrolling, never clipped off the list.
      await tester.dragUntilVisible(
        find.text('Title 0'),
        find.byType(CustomScrollView),
        const Offset(0, -80),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Title 0'), findsOneWidget);
    });

    testWidgets('renders in the dark theme', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      await _pump(tester, _makeContainer(api), theme: MixtapeTheme.dark());

      expect(tester.takeException(), isNull);
      expect(find.text('Title 0'), findsOneWidget);
      expect(find.byKey(const Key('play-here-button')), findsOneWidget);
    });
  });

  // Plan 2026-11-09 C3: the tape's Remake shows the remake happening in the
  // conversation, its line and then the working cassette.
  group('Remake on the tape', () {
    const line = 'Remake this with my music';

    SessionDetail catalogMix() => SessionDetail(
      session: _session(notPersonal: true),
      messages: [
        DjMessage(
          id: 'm1',
          role: 'dj',
          content: 'A steady catalog run.',
          queueVersion: 1,
          createdAt: DateTime(2026, 1, 1),
        ),
      ],
      queue: [_track(0)],
    );

    TurnResult remade() => TurnResult(
      djMessage: DjMessage(
        id: 'm4',
        role: 'dj',
        content: 'Twelve of these are yours now.',
        createdAt: DateTime(2026, 1, 1),
      ),
      queue: [_track(0), _track(1)],
      queueVersion: 2,
    );

    ({FakeDjApi api, FakeListeningApi listening, ProviderContainer container})
    musicIn({Future<TurnResult> Function(String id)? onSendRemake}) {
      final api = FakeDjApi()
        ..onGetSession = ((_) async => catalogMix())
        ..onSendRemake = onSendRemake;
      final listening = FakeListeningApi(
        onboarding: onboardingState(musicReady: true),
      );
      final container = _makeContainer(
        api,
        listening: listening,
        destinations: InMemoryMusicPlatformStore(MusicPlatform.apple),
      );
      return (api: api, listening: listening, container: container);
    }

    Finder tapeRemake() => find.descendant(
      of: find.byType(QueueScreen),
      matching: find.byKey(MusicDoor.remakeKey),
    );

    int remakeTaps(FakeListeningApi listening) => listening.funnelEvents
        .where((type) => type == FunnelEventType.remakeTapped)
        .length;

    /// The route transition, without settling: the working cassette moves.
    Future<void> transition(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('from a tape opened from its conversation: back to it, '
        'then the remake', (tester) async {
      final turn = Completer<TurnResult>();
      final (:api, :listening, :container) = musicIn(
        onSendRemake: (_) => turn.future,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: const ChatScreen(sessionId: 's1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const QueueScreen(sessionId: 's1'),
            ),
          );
      await tester.pumpAndSettle();

      expect(tester.widget<TapeButton>(tapeRemake()).onPressed, isNotNull);
      await tester.tap(tapeRemake());
      await transition(tester);

      expect(find.byType(QueueScreen, skipOffstage: false), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(api.remakes, ['s1']);
      expect(find.text(line), findsOneWidget);
      expect(find.byKey(WorkingCassette.indicatorKey), findsOneWidget);
      expect(remakeTaps(listening), 1);

      turn.complete(remade());
      await tester.pumpAndSettle();
      expect(find.text('Twelve of these are yours now.'), findsOneWidget);
      expect(api.remakes, ['s1']);
      expect(remakeTaps(listening), 1);
    });

    testWidgets('with no conversation below: opens it over the tape, then '
        'the remake', (tester) async {
      final turn = Completer<TurnResult>();
      final (:api, :listening, :container) = musicIn(
        onSendRemake: (_) => turn.future,
      );
      await _pump(tester, container);
      expect(find.byType(ChatScreen), findsNothing);

      await tester.tap(tapeRemake());
      await transition(tester);

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(
        find.byType(QueueScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'the tape stays under the conversation',
      );
      expect(api.remakes, ['s1']);
      expect(find.text(line), findsOneWidget);
      expect(find.byKey(WorkingCassette.indicatorKey), findsOneWidget);
      expect(remakeTaps(listening), 1);

      turn.complete(remade());
      await tester.pumpAndSettle();
      expect(find.text('Twelve of these are yours now.'), findsOneWidget);
      expect(api.remakes, ['s1']);
      expect(remakeTaps(listening), 1);
    });

    testWidgets('a double tap opens one conversation and remakes once', (
      tester,
    ) async {
      final turn = Completer<TurnResult>();
      final (:api, :listening, :container) = musicIn(
        onSendRemake: (_) => turn.future,
      );
      await _pump(tester, container);

      await tester.tap(tapeRemake());
      await tester.tap(tapeRemake(), warnIfMissed: false);
      await transition(tester);

      expect(find.byType(ChatScreen, skipOffstage: false), findsOneWidget);
      expect(api.remakes, ['s1']);
      expect(remakeTaps(listening), 1);

      turn.complete(remade());
      await tester.pumpAndSettle();
    });

    testWidgets('disabled while the session is sending', (tester) async {
      final turn = Completer<TurnResult>();
      final (:api, :listening, :container) = musicIn();
      api.onSendMessage = (_, _) => turn.future;
      await _pump(tester, container);
      expect(tester.widget<TapeButton>(tapeRemake()).onPressed, isNotNull);

      final sending = container.read(chatProvider('s1').notifier).send('more');
      await tester.pump();
      expect(tester.widget<TapeButton>(tapeRemake()).onPressed, isNull);
      await tester.tap(tapeRemake(), warnIfMissed: false);
      await tester.pump();
      expect(find.byType(ChatScreen), findsNothing);
      expect(api.remakes, isEmpty);
      expect(remakeTaps(listening), 0);

      turn.complete(
        TurnResult(
          djMessage: DjMessage(
            id: 'm3',
            role: 'dj',
            content: 'More.',
            createdAt: DateTime(2026, 1, 1),
          ),
          queue: [_track(0)],
          queueVersion: 1,
        ),
      );
      await sending;
      await tester.pumpAndSettle();
      expect(tester.widget<TapeButton>(tapeRemake()).onPressed, isNotNull);
    });
  });
}
