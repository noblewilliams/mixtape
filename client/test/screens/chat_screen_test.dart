// The conversation (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` tasks 4.1–4.3; frames C1–C3 / F1–F3 / A1–A3 in
// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/play_destination_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/lyric_turn.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';
import 'package:mixtape/presentation/widgets/tape_strip.dart';
import 'package:mixtape/presentation/widgets/version_marker.dart';

import 'package:mixtape/data/auth/account_api.dart' show AccountApi;
import 'package:mixtape/presentation/providers/account_provider.dart'
    show accountApiProvider;
import 'package:mixtape/presentation/widgets/ai_consent_sheet.dart';
import '../helpers/fake_ai_consent.dart';
import '../data/playback/playback_controller_test.dart' as playback
    show FakeApi, FakeBridge;
import '../presentation/providers/playlist_context_provider_test.dart'
    show FakeContextApi, seed;

/// Implements DjApi's public surface (not `extends` — DjApi's constructor
/// builds a real ApiClient, which a fake has no use for). Mirrors the
/// pattern in dj_providers_test.dart: each method delegates to a settable
/// callback, and an unset callback throws so an unexpected call fails
/// loudly rather than hanging.
class FakeDjApi implements DjApi {
  @override
  Future<void> recordPlaylistCreation(String sessionId, String appleLibraryId) async {}

  Future<SessionDetail> Function(String prompt)? onCreateSession;
  Future<List<DjSession>> Function()? onListSessions;
  Future<SessionDetail> Function(String id)? onGetSession;
  Future<TurnResult> Function(String id, String text)? onSendMessage;
  Future<QueueOpsResult> Function(String id, List<QueueOp> ops, int? expectedVersion)?
  onApplyQueueOps;
  Future<DjSession> Function(String id, String status)? onSetStatus;
  Future<DjSession> Function(String id, String title)? onRenameSession;
  Future<void> Function(String sessionId, String type)? onPostSessionEvent;
  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

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
  Future<SessionDetail> createSession(String prompt, {InitialPlaylistSeed? playlistSeed, SessionKind kind = SessionKind.mix}) {
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
  Future<DjSession> setCaseColor(String id, String caseColor) => throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) {
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

/// The MusicKit channel, faked: every call this screen can make records its
/// arguments, and nothing touches a platform channel.
class FakeBridge implements MusicKitBridge {
  List<String>? playedIds;
  int added = 0;
  int failed = 0;
  MusicKitException? failWith;

  @override
  Future<bool> playQueue(List<String> appleIds) async {
    if (failWith != null) throw failWith!;
    playedIds = appleIds;
    return true;
  }

  @override
  Future<({int added, int failed})> createPlaylist(
    String name,
    List<String> appleIds, {
    String? author,
    String? description,
    void Function(String libraryId)? onCreated,
  }) async {
    if (failWith != null) throw failWith!;
    onCreated?.call('library-1');
    return (added: added, failed: failed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// authProvider override settled at a stable session status — no real
/// keychain restore, no async transition mid-test (same pattern as
/// dj_providers_test.dart's TestAuthNotifier).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

/// A chatProvider override that returns a hand-crafted [ChatState] verbatim
/// rather than driving it through a real getSession/send round trip — used
/// to reach transcript shapes the real [ChatNotifier] can't otherwise
/// produce (e.g. an error turn with no preceding user turn), so the
/// screen's defensive UI guards can be exercised directly.
class _FixedChatNotifier extends ChatNotifier {
  _FixedChatNotifier(this._fixedState) : super('irrelevant');
  final ChatState _fixedState;

  @override
  Future<ChatState> build() async => _fixedState;
}

DjSession _session({
  String id = 's1',
  int queueVersion = 1,
  String title = 'Test Session',
  bool notPersonal = false,
  String status = 'active',
}) => DjSession(
  id: id,
  title: title,
  status: status,
  queueVersion: queueVersion,
  updatedAt: DateTime(2026, 1, 1),
  notPersonal: notPersonal,
);

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

QueueTrack _spotifyTrack(int position, {String? appleId}) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: appleId,
  title: 'Title $position',
  artist: 'Artist',
  spotifyId: 'spotify-$position',
  durationMs: 180000,
);

/// A seed in a state the ready-made helper can't express.
PlaylistSeedState _seedWith(PlaylistSeedStatus status, {String name = 'Late nights'}) =>
    PlaylistSeedState(
      playlistId: 'p1',
      revision: 1,
      excludeSourceTracks: false,
      status: status,
      name: name,
      source: null,
      fingerprint: null,
      updatedAt: null,
      entries: 12,
      resolvedEntries: 2,
      recordings: 2,
      profile: null,
    );

ProviderContainer _makeContainer(
  FakeDjApi api, {
  FakeContextApi? inspiration,
  FakeBridge? bridge,
  AuthorStore? authorStore,
  String? accountName,
  AccountApi? account,
  PlaybackController? player,
  PlayDestinationStore? destinations,
}) {
  // The screen watches the Mixes summaries for the title it shows while the
  // transcript loads, and posts session events on an output.
  api.onListSessions ??= () async => [_session()];
  api.onPostSessionEvent ??= (_, _) async {};
  final container = ProviderContainer(
    overrides: [
      // The real ones reach the MusicKit channel, the keychain and GET /me.
      musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
      authorStoreProvider.overrideWithValue(
        authorStore ?? InMemoryAuthorStore(),
      ),
      accountNameProvider.overrideWith((ref) async => accountName),
      if (account != null) accountApiProvider.overrideWithValue(account),
      mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
      playDestinationStoreProvider.overrideWithValue(
        destinations ?? InMemoryPlayDestinationStore(),
      ),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
      if (inspiration != null)
        playlistContextApiProvider.overrideWithValue(inspiration),
      // The real controller reaches the player method channel and GET
      // /playback; the mix actions watch it to know whether THIS mix plays.
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
  String? initialError,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool settle = true,
}) async {
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
            child: ChatScreen(sessionId: sessionId, initialError: initialError),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// The mix-action reason keys, mirrored from the screen's private row.
abstract final class _MixActionsKeys {
  static const Key appleNeeded = Key('chat-apple-needed-reason');
}

void main() {
  testWidgets('loaded chat starts at its end without an entrance scroll', (
    tester,
  ) async {
    final result = Completer<SessionDetail>();
    final api = FakeDjApi()..onGetSession = (_) => result.future;
    await _pump(tester, _makeContainer(api), settle: false);
    result.complete(
      SessionDetail(
        session: _session(),
        queue: [_track(0)],
        messages: [
          for (var i = 0; i < 40; i++)
            _msg(
              'm$i',
              'dj',
              'Turn $i with enough words to fill the conversation.',
            ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Turn 39 with enough words to fill the conversation.'),
      findsOneWidget,
    );
    final list = find.descendant(
      of: find.byKey(const Key('chat-transcript-mask')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(list).position;
    expect(position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(position.isScrollingNotifier.value, isFalse);
  });

  group('the frame', () {
    testWidgets('the header is Back, the title and one More: no queue button', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(title: 'Night bus notes'), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-back')), findsOneWidget);
      expect(find.byKey(const Key('chat-arrangement')), findsNothing);
      expect(find.byKey(const Key('chat-actions')), findsOneWidget);
      expect(find.text('Night bus notes'), findsOneWidget);
      // The shell owns the chrome now: no Material app bar anywhere.
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('chat-not-personal')), findsNothing);
    });

    testWidgets('tapping the strip away from Play opens the tape for this mix', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(id: 'session-42'),
        messages: [],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api), sessionId: 'session-42');

      await tester.tap(find.byKey(TapeStrip.openKey));
      await tester.pumpAndSettle();

      expect(
        tester.widget<QueueScreen>(find.byType(QueueScreen)).sessionId,
        'session-42',
      );
    });

    testWidgets('a corpus-mode session carries the Not personal yet subtitle', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(notPersonal: true, title: 'Focus, forty minutes'),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-not-personal')), findsOneWidget);
      expect(find.text('Not personal yet'), findsOneWidget);
    });
  });

  group('turns', () {
    testWidgets('user turns go right in tape, DJ turns left in glass', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [_msg('m1', 'user', 'play some jazz'), _msg('m2', 'dj', 'here you go')],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(LyricTurn.userKey), findsOneWidget);
      expect(find.byKey(LyricTurn.djKey), findsOneWidget);
      expect(find.byKey(LyricTurn.errorKey), findsNothing);
      expect(find.byKey(const Key('dj-accent-bar')), findsNothing);
    });

    testWidgets(
      'version markers: the current one reads current, earlier ones open '
      'history; no tape card',
      (tester) async {
        final api = FakeDjApi();
        api.onGetSession = (_) async => SessionDetail(
          session: _session(queueVersion: 2),
          messages: [
            _msg('m1', 'dj', 'first cut', queueVersion: 1),
            _msg('m2', 'dj', 'second cut', queueVersion: 2),
          ],
          queue: [_track(0), _track(1)],
        );
        await _pump(tester, _makeContainer(api));

        expect(find.byKey(VersionMarker.keyFor(1)), findsOneWidget);
        expect(find.byKey(VersionMarker.keyFor(2)), findsOneWidget);
        expect(find.textContaining('2 songs · current'), findsOneWidget);
        await tester.tap(find.byKey(VersionMarker.keyFor(2)));
        await tester.pumpAndSettle();
        expect(find.byType(QueueScreen), findsOneWidget);
        Navigator.of(tester.element(find.byType(QueueScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.text('The tape'), findsNothing);
        expect(find.text('Open'), findsNothing);
        // The marker follows the reply that made it.
        expect(
          tester.getTopLeft(find.byKey(VersionMarker.keyFor(2))).dy,
          greaterThan(tester.getTopLeft(find.text('second cut')).dy),
        );
      },
    );

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
      api.onGetSession = (_) async => SessionDetail(
        session: saved,
        messages: [
          _msg('m1', 'dj', 'first cut', queueVersion: 1),
          _msg('m2', 'dj', 'second cut', queueVersion: 2),
        ],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      final colours = tester
          .widgetList<CassetteTile>(find.byType(CassetteTile))
          .map((tile) => tile.caseColor)
          .toSet();
      // Two markers and the strip.
      expect(find.byType(CassetteTile), findsNWidgets(3));
      expect(colours, {const Color(0xFF617F9C)});
    });

    testWidgets('an earlier version marker opens history at that version', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 3),
        messages: [
          _msg('m1', 'dj', 'first cut', queueVersion: 1),
          _msg('m2', 'dj', 'third cut', queueVersion: 3),
        ],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.text('Version 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final pushed = tester.widget<MixHistoryScreen>(find.byType(MixHistoryScreen));
      expect(pushed.initialVersion, 1);
    });

    testWidgets('an earlier version marker is a button VoiceOver can activate', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 3),
        messages: [
          _msg('m1', 'dj', 'first cut', queueVersion: 1),
          _msg('m2', 'dj', 'third cut', queueVersion: 3),
        ],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      final data = tester
          .getSemantics(find.bySemanticsLabel('Version 1'))
          .getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a node with no tap action cannot be activated by VoiceOver',
      );
      expect(data.flagsCollection.isButton, isTrue);

      handle.dispose();
    });

    testWidgets('the energy line states the shape against the ask', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here you go', queueVersion: 2)],
        queue: [_track(0)],
      );
      final container = ProviderContainer(
        overrides: [
          mixEnergyProvider.overrideWith(
            (ref, key) async => <String, dynamic>{
              'energyArc': 'arc',
              'energyJourney': {'status': 'limited'},
            },
          ),
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          djApiProvider.overrideWithValue(api),
          authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
          playbackProvider.overrideWithValue(
            PlaybackController(playback.FakeApi(), playback.FakeBridge()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.byKey(MixEnergySummary.lineKey), findsOneWidget);
      expect(find.text('Build, then settle · limited coverage'), findsOneWidget);
    });

    testWidgets('no current marker when the current turn emptied the queue', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 3),
        messages: [_msg('m1', 'dj', 'cleared the tape', queueVersion: 3)],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(VersionMarker.keyFor(3)), findsNothing);
      expect(find.byKey(TapeStrip.stripKey), findsNothing);
    });

    testWidgets('a current version no reply carries is marked below every turn', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 5),
        messages: [
          _msg('m1', 'dj', 'first cut', queueVersion: 1),
          _msg('m2', 'dj', 'second thought'),
        ],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(VersionMarker.keyFor(5)), findsOneWidget);
      expect(find.byKey(VersionMarker.keyFor(1)), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(VersionMarker.keyFor(5))).dy,
        greaterThan(tester.getTopLeft(find.text('second thought')).dy),
      );
    });

    testWidgets('the transcript uses ListView.builder for virtualization', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [_msg('m1', 'dj', 'hi')], queue: []);
      await _pump(tester, _makeContainer(api));

      final listView = tester.widget<ListView>(find.byType(ListView).first);
      expect(listView.childrenDelegate, isA<SliverChildBuilderDelegate>());
      // Each turn fades by its own paint, so no per-turn repaint boundary.
      expect(
        (listView.childrenDelegate as SliverChildBuilderDelegate)
            .addRepaintBoundaries,
        isFalse,
      );
      expect(find.byType(LyricFade), findsOneWidget);
    });

    testWidgets('the latest exchange is full ink; older turns still fade', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [
          _msg('m1', 'user', 'first ask'),
          _msg('m2', 'dj', List.filled(12, 'An older reply with a little more to say.').join(' ')),
          _msg('m3', 'user', 'now this'),
          _msg('m4', 'dj', 'here you go'),
        ],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      RenderLyricFade fadeOf(String text) => tester.renderObject<RenderLyricFade>(
        find.ancestor(of: find.text(text), matching: find.byType(LyricFade)),
      );
      // Short content: nothing scrolls, so nothing in the latest exchange
      // may sit faded at the top.
      expect(fadeOf('now this').lastOpacity, 1);
      expect(fadeOf('here you go').lastOpacity, 1);
      expect(fadeOf('first ask').lastOpacity, lessThan(1));
    });
  });

  group('the DJ working', () {
    testWidgets('the cassette takes the next line\'s place, then the reply', (
      tester,
    ) async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      api.onSendMessage = (id, text) => completer.future;
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      expect(find.text('play jazz'), findsOneWidget);
      expect(find.byKey(WorkingCassette.indicatorKey), findsOneWidget);
      expect(find.text('The DJ is listening…'), findsOneWidget);
      // Before the first mix the cassette wears the default case.
      expect(
        tester
            .widget<CassetteTile>(find.byKey(WorkingCassette.cassetteKey))
            .caseColor,
        CassetteTile.caseColors.first,
      );
      expect(
        tester.getTopLeft(find.byKey(WorkingCassette.indicatorKey)).dy,
        greaterThan(tester.getTopLeft(find.text('play jazz')).dy),
      );
      // The composer and + go inert in place, not away.
      expect(
        tester.widget<TextField>(find.byKey(const Key('prompt-field'))).readOnly,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pump();
      expect(find.text('Start from a playlist'), findsNothing);

      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'here you go'), queue: [], queueVersion: 1),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WorkingCassette.indicatorKey), findsNothing);
      expect(find.text('here you go'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('prompt-field'))).readOnly,
        isFalse,
      );
    });

    testWidgets('a mix being changed keeps its strip playable', (tester) async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      api.onSendMessage = (id, text) => completer.future;
      final bridge = FakeBridge();
      await _pump(tester, _makeContainer(api, bridge: bridge));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'softer');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      expect(find.byKey(WorkingCassette.indicatorKey), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-play-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('chat-send-to-music')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(bridge.playedIds, ['apple-0']);

      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'softer now'), queue: [_track(0)], queueVersion: 3),
      );
      await tester.pumpAndSettle();
    });
  });

  group('a failed turn', () {
    testWidgets('renders an error turn keeping the user turn; Resend sends it again', (
      tester,
    ) async {
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
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(LyricTurn.errorKey), findsOneWidget);
      expect(find.text('the DJ is stuck, try again'), findsOneWidget);

      await tester.tap(find.byKey(LyricTurn.resendKey));
      await tester.pumpAndSettle();

      expect(sendCall, 2);
      expect(find.text('play jazz'), findsNWidgets(2)); // original + resend
      expect(find.text('sorted, here you go'), findsOneWidget);
      expect(find.byKey(LyricTurn.errorKey), findsOneWidget);
    });

    testWidgets('Resend never clears an in-progress draft', (tester) async {
      var sendCall = 0;
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async {
        sendCall++;
        if (sendCall == 1) throw DjApiException(kind: 'conflict', message: 'try again');
        return TurnResult(djMessage: _msg('m2', 'dj', 'ok'), queue: [], queueVersion: 1);
      };
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('prompt-field')), 'unsent draft');
      await tester.pump();
      await tester.tap(find.byKey(LyricTurn.resendKey));
      await tester.pumpAndSettle();

      expect(sendCall, 2);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'unsent draft',
      );
    });

    testWidgets('Resend is inert while another send is in flight', (tester) async {
      var sendCall = 0;
      final inFlight = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async {
        sendCall++;
        if (sendCall == 1) throw DjApiException(kind: 'conflict', message: 'try again');
        return inFlight.future;
      };
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('prompt-field')), 'another one');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      await tester.tap(find.byKey(LyricTurn.resendKey));
      await tester.pump();
      expect(find.text('Resend'), findsOneWidget);
      expect(sendCall, 2);

      inFlight.complete(
        TurnResult(djMessage: _msg('m3', 'dj', 'ok'), queue: [], queueVersion: 1),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('an error turn with nothing to resend draws no button', (tester) async {
      final fixedState = ChatState(
        session: _session(),
        messages: [ChatMessage(_msg('m1', 'dj', 'a stray apology'), isError: true)],
        queue: [],
      );
      final container = ProviderContainer(
        overrides: [
          mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          djApiProvider.overrideWithValue(FakeDjApi()),
          authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
          playbackProvider.overrideWithValue(
            PlaybackController(playback.FakeApi(), playback.FakeBridge()),
          ),
          chatProvider('s1').overrideWith(() => _FixedChatNotifier(fixedState)),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.byKey(LyricTurn.errorKey), findsOneWidget);
      expect(find.byKey(LyricTurn.resendKey), findsNothing);
    });

    testWidgets('an initialError seeds one error turn whose Resend works', (tester) async {
      var sendCall = 0;
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(),
        messages: [_msg('m1', 'user', 'play jazz')],
        queue: [],
      );
      api.onSendMessage = (id, text) async {
        sendCall++;
        return TurnResult(djMessage: _msg('m2', 'dj', 'sorted'), queue: [], queueVersion: 1);
      };
      await _pump(tester, _makeContainer(api), initialError: 'the DJ hiccupped');

      expect(find.byKey(LyricTurn.errorKey), findsOneWidget);
      expect(find.text('the DJ hiccupped'), findsOneWidget);

      await tester.tap(find.byKey(LyricTurn.resendKey));
      await tester.pumpAndSettle();

      expect(sendCall, 1);
      expect(find.text('sorted'), findsOneWidget);
    });

    testWidgets('a null initialError seeds nothing', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(LyricTurn.errorKey), findsNothing);
    });
  });

  group('opening', () {
    testWidgets('the chrome is present from the first frame; only the turns are skeletons', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) => Completer<SessionDetail>().future;
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
      await tester.pump();

      expect(find.byKey(const Key('chat-skeleton')), findsOneWidget);
      expect(find.byKey(const Key('chat-back')), findsOneWidget);
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      // Nothing is actionable until the transcript lands.
      expect(find.byKey(const Key('chat-play-now')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pump();
      expect(find.text('Start from a playlist'), findsNothing);
    });

    testWidgets('the skeleton keeps the real title and announces Opening <title>', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [_session(title: 'Night bus notes')];
      api.onGetSession = (_) => Completer<SessionDetail>().future;
      final container = _makeContainer(api);
      // The Mixes list the listener just tapped is already warm.
      await container.read(sessionsProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: const ChatScreen(sessionId: 's1'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('chat-skeleton')), findsOneWidget);
      expect(find.text('Night bus notes'), findsOneWidget);
      expect(
        tester
            .widget<Semantics>(find.byKey(const Key('chat-skeleton')))
            .properties
            .label,
        'Opening Night bus notes',
      );
    });

    testWidgets('could-not-open only when there is nothing to show; Try again refetches', (
      tester,
    ) async {
      var shouldFail = true;
      final api = FakeDjApi();
      api.onGetSession = (_) async {
        if (shouldFail) throw ApiException(500, 'internal server error');
        return SessionDetail(session: _session(), messages: [], queue: []);
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text("Couldn't open this mix"), findsOneWidget);
      expect(
        find.text('Check your connection and try again. Nothing here has been lost.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-back')), findsOneWidget); // Back still works
      expect(find.byKey(const Key('prompt-field')), findsNothing);

      shouldFail = false;
      await tester.tap(find.byKey(const Key('chat-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chat-retry')), findsNothing);
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
    });

    testWidgets('a failed refresh keeps the visible transcript and toasts instead', (
      tester,
    ) async {
      var shouldFail = false;
      final api = FakeDjApi();
      api.onGetSession = (_) async {
        if (shouldFail) throw ApiException(500, 'refresh boom');
        return SessionDetail(
          session: _session(),
          messages: [_msg('m1', 'dj', 'welcome back')],
          queue: [],
        );
      };
      final container = _makeContainer(api);
      await _pump(tester, container);

      expect(find.text('welcome back'), findsOneWidget);

      shouldFail = true;
      container.invalidate(chatProvider('s1'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('welcome back'), findsOneWidget);
      expect(find.byKey(const Key('chat-retry')), findsNothing);

      // Riverpod's retry backoff left a pending Timer; dispose explicitly
      // (idempotent) so it is cancelled before the test ends.
      container.dispose();
    });

    testWidgets('a transientError surfaces as a floating snackbar and is cleared', (
      tester,
    ) async {
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
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.margin ?? snack.padding, isNotNull);
    });
  });

  group('the panel', () {
    testWidgets('before the first mix: + and the composer only, no strip', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(TapeStrip.stripKey), findsNothing);
      expect(find.byKey(const Key('chat-play-now')), findsNothing);
      expect(find.byKey(const Key('chat-create-playlist')), findsNothing);
      expect(find.byKey(const Key('chat-shape-chip')), findsNothing);
      expect(find.byType(InspirationChip), findsNothing);
      final plus = find.byKey(const Key('chat-plus'));
      expect(tester.getSize(plus), const Size(44, 44));

      // The + menu holds a playlist to start from and, before the first
      // mix, Shape.
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.text('Start from a playlist'), findsOneWidget);
      expect(find.text('Shape the energy'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Start from a playlist'), findsNothing);
    });

    testWidgets('a mix: the strip holds the tape and the only Play', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2, title: 'Smooth Cruise'),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0), _track(1)],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(TapeStrip.stripKey), findsOneWidget);
      expect(find.text('Version 2 · 2 songs'), findsOneWidget);
      expect(find.byKey(const Key('chat-play-now')), findsOneWidget);
      expect(find.byKey(const Key('chat-play-menu')), findsOneWidget);
      // Create playlist stays on the tape screen; nothing else competes.
      expect(find.byKey(const Key('chat-create-playlist')), findsNothing);
      expect(find.text('Play now'), findsNothing);
      expect(find.text('Play'), findsOneWidget);

      // Once a mix exists Shape leaves the + menu.
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pumpAndSettle();
      expect(find.text('Start from a playlist'), findsOneWidget);
      expect(find.text('Shape the energy'), findsNothing);
    });

    testWidgets('Play plays here by default and opens Now Playing', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 3),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 3)],
        queue: [_track(0)],
      );
      FlutterSecureStorage.setMockInitialValues({});
      final player = PlaybackController(playback.FakeApi(), playback.FakeBridge());
      addTearDown(player.dispose);
      await _pump(tester, _makeContainer(api, player: player));

      await tester.tap(find.byKey(const Key('chat-play-now')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.sessionId, 's1');
      expect(player.version, 3);
    });

    testWidgets('Shape from + writes the brief into the composer', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'Sunday morning');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shape the energy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'Sunday morning\nEnergy journey: Wind down.',
      );
      expect(find.text('Shape added to your brief. Send when ready.'), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(ChatScreen)),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();

      // The menu ticks the shape the brief asks for, and Clear takes it out.
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shape the energy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.clearKey));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'Sunday morning',
      );
    });

    testWidgets('Start from a playlist opens the playlist picker', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      await _pump(tester, _makeContainer(api, inspiration: FakeContextApi()));
      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-plus-playlist')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(PlaylistPicker.sheetKey), findsOneWidget);
    });

    testWidgets('an unavailable playlist keeps its name and offers detach', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      final inspiration = FakeContextApi()
        ..read = () async => _seedWith(PlaylistSeedStatus.unavailable);
      await _pump(tester, _makeContainer(api, inspiration: inspiration));

      final chip = tester.widget<InspirationChip>(find.byType(InspirationChip));
      expect(chip.tone, InspirationChipTone.unavailable);
      expect(find.text('Late nights · unavailable'), findsOneWidget);
      expect(find.byKey(InspirationChip.detachKey), findsOneWidget);
      expect(chip.onPick, isNotNull); // Replace stays available
    });

    testWidgets('a playlist with too few matched songs says so in err ink', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      final inspiration = FakeContextApi()
        ..read = () async => _seedWith(PlaylistSeedStatus.insufficientProfile);
      await _pump(tester, _makeContainer(api, inspiration: inspiration));

      final chip = tester.widget<InspirationChip>(find.byType(InspirationChip));
      expect(chip.tone, InspirationChipTone.insufficient);
      expect(
        chip.ink(tester.element(find.byType(InspirationChip))),
        MixtapeTokens.light.errInk,
      );
      expect(find.text('At least 3 matched recordings are needed.'), findsOneWidget);
    });

    testWidgets('a selection changed elsewhere refreshes and toasts, keeping the draft', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: [_track(0)]);
      final inspiration = FakeContextApi()..read = () async => seed(1, id: 'Late nights');
      final container = _makeContainer(api, inspiration: inspiration);
      await _pump(tester, container);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'and nothing before 2010');
      await tester.pump();

      inspiration.read = () async => seed(2, id: 'Quiet mornings');
      await container.read(sessionPlaylistContextProvider('s1').notifier).refresh();
      await tester.pumpAndSettle();

      expect(
        find.text('Quiet mornings changed elsewhere. Showing the current selection.'),
        findsOneWidget,
      );
      // The arrangement and the unsent text are untouched.
      expect(find.byKey(TapeStrip.stripKey), findsOneWidget);
      expect(find.text('and nothing before 2010'), findsOneWidget);
    });
  });

  group('the More menu', () {
    testWidgets('archives with an Undo that restores the mix', (tester) async {
      var status = 'active';
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(status: status), messages: [], queue: []);
      api.onSetStatus = (id, next) async {
        status = next;
        return _session(status: next);
      };
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.byKey(const Key('chat-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Version history'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();

      expect(find.text('Mix archived'), findsOneWidget);
      expect(status, 'archived');
      // The conversation stays open and editable behind the toast.
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(status, 'active');
    });

    testWidgets('an archived mix offers Restore', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(status: 'archived'), messages: [], queue: []);
      api.onSetStatus = (id, next) async => _session(status: next);
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.byKey(const Key('chat-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Mix restored'), findsOneWidget);
    });

    testWidgets('every entry wears the board\'s trailing glyph', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      Map<String, IconData?> icons() => {
        for (final item in tester.widgetList<MixtapeMenuItem<String>>(
          find.byType(MixtapeMenuItem<String>),
        ))
          item.action.label: item.action.icon,
      };

      await tester.tap(find.byKey(const Key('chat-actions')));
      await tester.pumpAndSettle();
      expect(icons(), {
        'Version history': Icons.history_rounded,
        'Tape settings': Icons.voicemail_rounded,
        'Rename': CupertinoIcons.pencil,
        'Archive': CupertinoIcons.archivebox,
      });
      await tester.tap(find.byKey(mixtapeMenuBarrierKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chat-plus')));
      await tester.pumpAndSettle();
      expect(icons(), {
        'Start from a playlist': Icons.playlist_add_rounded,
        'Shape the energy': Icons.show_chart_rounded,
      });
    });

    testWidgets('Version history opens the history screen', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.byKey(const Key('chat-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Version history'));
      await tester.pumpAndSettle();

      expect(find.byType(MixHistoryScreen), findsOneWidget);
      expect(
        tester.widget<MixHistoryScreen>(find.byType(MixHistoryScreen)).initialVersion,
        isNull,
      );
    });
  });


  group('the handoffs', () {
    testWidgets('a remembered Apple Music plays there, with the skipped-track copy', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0), _spotifyTrack(1)], // one has no Apple match
      );
      final bridge = FakeBridge();
      await _pump(
        tester,
        _makeContainer(
          api,
          bridge: bridge,
          destinations: InMemoryPlayDestinationStore(PlayDestination.appleMusic),
        ),
      );

      expect(find.text('Play in Music'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-play-now')));
      await tester.pumpAndSettle();

      expect(bridge.playedIds, ['apple-0']);
      expect(
        find.text('Playing in Apple Music · 1 song skipped (not in Apple Music)'),
        findsOneWidget,
      );
    });

    testWidgets('the arrow plays in Apple Music and makes it the default', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      final bridge = FakeBridge();
      final store = InMemoryPlayDestinationStore();
      await _pump(tester, _makeContainer(api, bridge: bridge, destinations: store));

      await tester.tap(find.byKey(const Key('chat-play-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-send-to-music')));
      await tester.pumpAndSettle();

      expect(bridge.playedIds, ['apple-0']);
      expect(await store.read(), PlayDestination.appleMusic);
      expect(find.text('Play in Music'), findsOneWidget);
    });

    testWidgets('a Spotify-only mix trades Play and Create for the transfer tool', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_spotifyTrack(0), _spotifyTrack(1)],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-play-now')), findsNothing);
      expect(find.byKey(const Key('chat-create-playlist')), findsNothing);
      expect(find.byKey(const Key('chat-send-to-music')), findsNothing);
      expect(find.text('Play on Spotify'), findsOneWidget);
      expect(find.byKey(_MixActionsKeys.appleNeeded), findsOneWidget);
    });

    testWidgets('a mix Apple Music cannot match keeps the actions and says why', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [
          QueueTrack(
            position: 0,
            trackId: 't0',
            appleId: null,
            title: 'Title',
            artist: 'Artist',
            durationMs: 180000,
          ),
        ],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.text("these tracks aren't in Apple Music"), findsOneWidget);
      final bridge = FakeBridge();
      await tester.tap(find.byKey(const Key('chat-play-now')));
      await tester.pumpAndSettle();
      expect(bridge.playedIds, isNull);
      expect(find.byType(PlaybackScreen), findsNothing);
      expect(find.text('Play on Spotify'), findsNothing);
    });

    testWidgets('an arrangement with no reason to refuse shows no reason line', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.text("these tracks aren't in Apple Music"), findsNothing);
      expect(find.byKey(_MixActionsKeys.appleNeeded), findsNothing);
    });
  });

  group('corpus mode', () {
    testWidgets('the explanatory line follows the last turn, under the subtitle', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(notPersonal: true, title: 'Focus, forty minutes'),
        messages: [
          _msg('m1', 'user', 'Forty minutes of focus music.'),
          _msg('m2', 'dj', 'Instrumental only?'),
        ],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-not-personal')), findsOneWidget);
      expect(
        find.text(
          "Built from Mixtape's catalog and your interview, not your listening. "
          'Import your Spotify data for the real thing.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(
              find.text(
                "Built from Mixtape's catalog and your interview, not your listening. "
                'Import your Spotify data for the real thing.',
              ),
            )
            .dy,
        greaterThan(tester.getTopLeft(find.text('Instrumental only?')).dy),
      );
    });

    testWidgets('a personal mix carries neither the subtitle nor the line', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [_msg('m1', 'dj', 'hi')], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-not-personal')), findsNothing);
      expect(find.byKey(const Key('chat-not-personal-line')), findsNothing);
    });
  });

  group('an unreadable inspiration', () {
    testWidgets('offers a reload that reads again rather than writing', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      var reads = 0;
      final inspiration = FakeContextApi()
        ..read = () async {
          reads++;
          throw ApiException(500, 'seed boom');
        };
      await _pump(tester, _makeContainer(api, inspiration: inspiration));

      expect(find.text('Couldn’t read the current inspiration.'), findsOneWidget);
      expect(find.byKey(const Key('inspiration-reload')), findsOneWidget);
      final before = reads;

      await tester.tap(find.byKey(const Key('inspiration-reload')));
      await tester.pumpAndSettle();

      expect(reads, before + 1);
      expect(inspiration.writes, 0); // a read failure never provokes a write
    });

    testWidgets('a readable selection offers no reload', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      final inspiration = FakeContextApi()..read = () async => seed(1, id: 'Late nights');
      await _pump(tester, _makeContainer(api, inspiration: inspiration));

      expect(find.byKey(const Key('inspiration-reload')), findsNothing);
      expect(find.byKey(const Key('inspiration-status')), findsNothing);
    });
  });

  group('variants', () {
    testWidgets('200% text on a 320 pt phone wraps without overflowing', (tester) async {
      // A tall-enough viewport for the panel and the turns to coexist at
      // 200%; the board's own large-text frame is the same shape.
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2, title: 'Night bus notes'),
        messages: [
          _msg('m1', 'dj', 'Four swapped. The lift is gentler now and nothing shouts.',
              queueVersion: 2),
        ],
        queue: [_track(0)],
      );
      // A readable (empty) selection, as a working session has: no status
      // line under the attachment row to make the panel taller than the
      // board's.
      await _pump(
        tester,
        _makeContainer(api, inspiration: FakeContextApi()),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      // The strip stacks: Play takes a full row under the wrapped title.
      expect(find.byKey(TapeStrip.stripKey), findsOneWidget);
      final play = tester.getRect(find.byKey(const Key('chat-play-now')));
      final title = tester.getRect(
        find.descendant(
          of: find.byKey(TapeStrip.stripKey),
          matching: find.text('Night bus notes'),
        ),
      );
      expect(play.top, greaterThan(title.bottom));
      // The composer stays reachable above the keyboard-free bottom.
      expect(find.byKey(const Key('prompt-field')).hitTestable(), findsOneWidget);
    });

    testWidgets('dark mode renders the whole conversation', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1),
        messages: [
          _msg('m1', 'user', 'Something for the last bus home.'),
          _msg('m2', 'dj', 'Eighteen songs.', queueVersion: 1),
        ],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api), brightness: Brightness.dark);

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.byKey(LyricTurn.djKey)).style!.color,
        MixtapeTokens.dark.text,
      );
      expect(
        tester.widget<Text>(find.byKey(LyricTurn.userKey)).style!.color,
        MixtapeTokens.dark.smoke,
      );
    });
  });

  group('AI consent (plan 2026-11-02)', () {
    testWidgets('a turn without consent re-shows the sheet, keeping the draft', (
      tester,
    ) async {
      final sent = <String>[];
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async {
        sent.add(text);
        return TurnResult(
          djMessage: _msg('m2', 'dj', 'here you go'),
          queue: [],
          queueVersion: 1,
        );
      };
      final account = FakeConsentAccountApi();
      await _pump(tester, _makeContainer(api, account: account));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'more jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.text('more jazz'), findsOneWidget);

      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AiConsentCopy.agreeKey));
      await tester.pumpAndSettle();
      expect(account.grants, 1);
      expect(sent, ['more jazz']);
    });

    testWidgets('a 403 ai_consent_required takes the turn back and asks', (
      tester,
    ) async {
      var refuse = true;
      final sent = <String>[];
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) async {
        sent.add(text);
        if (refuse) throw const AiConsentRequiredException();
        return TurnResult(
          djMessage: _msg('m2', 'dj', 'here you go'),
          queue: [],
          queueVersion: 1,
        );
      };
      final account = FakeConsentAccountApi(aiConsent: true);
      await _pump(tester, _makeContainer(api, account: account));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'more jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
      expect(find.byKey(LyricTurn.errorKey), findsNothing);
      // The draft is back in the composer, not a sent bubble.
      final field = tester.widget<TextField>(
        find.byKey(const Key('prompt-field')),
      );
      expect(field.controller!.text, 'more jazz');

      refuse = false;
      await tester.tap(find.byKey(AiConsentCopy.agreeKey));
      await tester.pumpAndSettle();
      expect(account.grants, 1);
      expect(sent, ['more jazz', 'more jazz']);
      expect(find.text('here you go'), findsOneWidget);
    });
  });
}
