// The conversation (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` tasks 4.1–4.3; frames C1–C3 / F1–F3 / A1–A3 in
// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/widgets/conversation_turn.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';
import 'package:mixtape/presentation/widgets/queue_card.dart';

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
  Future<SessionDetail> createSession(String prompt, {InitialPlaylistSeed? playlistSeed}) {
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

/// authProvider override settled at a stable signedIn status — no real
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
      mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
      if (inspiration != null)
        playlistContextApiProvider.overrideWithValue(inspiration),
      // The real controller reaches the player method channel and GET
      // /playback; the mix actions watch it to know whether THIS mix plays.
      playbackProvider.overrideWithValue(
        PlaybackController(playback.FakeApi(), playback.FakeBridge()),
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
  await tester.pumpAndSettle();
}

/// The mix-action reason keys, mirrored from the screen's private row.
abstract final class _MixActionsKeys {
  static const Key appleNeeded = Key('chat-apple-needed-reason');
}

void main() {
  group('the frame', () {
    testWidgets('draws the back, arrangement and More clusters around the title', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(title: 'Night bus notes'), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(const Key('chat-back')), findsOneWidget);
      expect(find.byKey(const Key('chat-arrangement')), findsOneWidget);
      expect(find.byKey(const Key('chat-actions')), findsOneWidget);
      expect(find.text('Night bus notes'), findsOneWidget);
      // The shell owns the chrome now: no Material app bar anywhere.
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('chat-not-personal')), findsNothing);
    });

    testWidgets('the Arrangement button pushes the arrangement for this mix', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(id: 'session-42'),
        messages: [],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api), sessionId: 'session-42');

      await tester.tap(find.byKey(const Key('chat-arrangement')));
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

      expect(find.byKey(ConversationTurn.userKey), findsOneWidget);
      expect(find.byKey(ConversationTurn.djKey), findsOneWidget);
      expect(find.byKey(ConversationTurn.errorKey), findsNothing);
      expect(find.byKey(const Key('dj-accent-bar')), findsNothing);
    });

    testWidgets(
      'the tape card sits under the latest current-version reply; earlier '
      'versions are Version chips',
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

        expect(find.byKey(QueueCard.cardKey), findsOneWidget);
        expect(find.text('The tape'), findsOneWidget);
        expect(find.text('2 songs · 6 min · version 2'), findsOneWidget);
        expect(find.text('Version 1'), findsOneWidget);
        expect(find.text('Version 2'), findsNothing);
      },
    );

    testWidgets('the tape card reports hours once the mix is long enough', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [
          for (var i = 0; i < 18; i++) _track(i, durationMs: 240000),
        ],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.text('18 songs · 1 h 12 · version 2'), findsOneWidget);
    });

    testWidgets('Open pushes the arrangement for this session', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 1, id: 'session-42'),
        messages: [_msg('m1', 'dj', 'here you go', queueVersion: 1)],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api), sessionId: 'session-42');

      await tester.tap(find.byKey(QueueCard.openKey));
      await tester.pumpAndSettle();

      expect(
        tester.widget<QueueScreen>(find.byType(QueueScreen)).sessionId,
        'session-42',
      );
    });

    testWidgets('a Version chip opens history at that version', (tester) async {
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
      await tester.pumpAndSettle();

      final pushed = tester.widget<MixHistoryScreen>(find.byType(MixHistoryScreen));
      expect(pushed.initialVersion, 1);
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
          authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
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

    testWidgets('no tape card when the current turn emptied the queue', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 3),
        messages: [_msg('m1', 'dj', 'cleared the tape', queueVersion: 3)],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(QueueCard.cardKey), findsNothing);
      expect(find.text('Version 3'), findsNothing);
    });

    testWidgets('a standalone tape card lands below every turn', (tester) async {
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

      expect(find.byKey(QueueCard.cardKey), findsOneWidget);
      expect(find.text('Version 1'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(QueueCard.cardKey)).dy,
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
    });
  });

  group('the DJ working', () {
    testWidgets('three dots in place, the caption after the delay, then the reply', (
      tester,
    ) async {
      final completer = Completer<TurnResult>();
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      api.onSendMessage = (id, text) => completer.future;
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'play jazz');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      expect(find.text('play jazz'), findsOneWidget);
      expect(find.byKey(WorkingIndicator.indicatorKey), findsOneWidget);
      expect(find.byKey(WorkingIndicator.captionKey), findsNothing);
      // The composer and the attachments go inert in place, not away.
      expect(
        tester.widget<TextField>(find.byKey(const Key('prompt-field'))).readOnly,
        isTrue,
      );
      expect(find.byKey(const Key('chat-shape-chip')), findsOneWidget);
      expect(
        tester.widget<LabelChip>(find.byKey(const Key('chat-shape-chip'))).onPressed,
        isNull,
      );

      await tester.pump(const Duration(seconds: 11));
      expect(find.text('the DJ is listening…'), findsOneWidget);

      completer.complete(
        TurnResult(djMessage: _msg('m2', 'dj', 'here you go'), queue: [], queueVersion: 1),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WorkingIndicator.indicatorKey), findsNothing);
      expect(find.text('here you go'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('prompt-field'))).readOnly,
        isFalse,
      );
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

      expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
      expect(find.text('the DJ is stuck, try again'), findsOneWidget);

      await tester.tap(find.byKey(ConversationTurn.resendKey));
      await tester.pumpAndSettle();

      expect(sendCall, 2);
      expect(find.text('play jazz'), findsNWidgets(2)); // original + resend
      expect(find.text('sorted, here you go'), findsOneWidget);
      expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
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
      await tester.tap(find.byKey(ConversationTurn.resendKey));
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

      expect(
        tester.widget<IconButton>(find.byKey(ConversationTurn.resendKey)).onPressed,
        isNull,
      );
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
          authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
          playbackProvider.overrideWithValue(
            PlaybackController(playback.FakeApi(), playback.FakeBridge()),
          ),
          chatProvider('s1').overrideWith(() => _FixedChatNotifier(fixedState)),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
      expect(find.byKey(ConversationTurn.resendKey), findsNothing);
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

      expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
      expect(find.text('the DJ hiccupped'), findsOneWidget);

      await tester.tap(find.byKey(ConversationTurn.resendKey));
      await tester.pumpAndSettle();

      expect(sendCall, 1);
      expect(find.text('sorted'), findsOneWidget);
    });

    testWidgets('a null initialError seeds nothing', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(find.byKey(ConversationTurn.errorKey), findsNothing);
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
      expect(
        tester.widget<TapeButton>(find.byKey(const Key('chat-play-now'))).onPressed,
        isNull,
      );
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
    testWidgets('the mix actions are inert until the mix has an arrangement', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async =>
          SessionDetail(session: _session(queueVersion: 0), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      expect(
        tester.widget<TapeButton>(find.byKey(const Key('chat-play-now'))).onPressed,
        isNull,
      );
      expect(
        tester.widget<LabelChip>(find.byKey(const Key('chat-create-playlist'))).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextAction>(find.byKey(const Key('chat-send-to-music'))).onPressed,
        isNull,
      );
      expect(find.text('Play now'), findsOneWidget);
    });

    testWidgets('an arrangement makes all three actions live', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      await _pump(tester, _makeContainer(api));

      expect(
        tester.widget<TapeButton>(find.byKey(const Key('chat-play-now'))).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<LabelChip>(find.byKey(const Key('chat-create-playlist'))).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<TextAction>(find.byKey(const Key('chat-send-to-music'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('the Shape chip writes the brief into the composer', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(session: _session(), messages: [], queue: []);
      await _pump(tester, _makeContainer(api));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'Sunday morning');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-shape-chip')));
      await tester.pumpAndSettle();

      expect(find.byKey(EnergyControl.sheetKey), findsOneWidget);
      expect(find.text('Give the mix a shape.'), findsOneWidget);
      await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.confirmKey));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'Sunday morning\nEnergy journey: Wind down.',
      );
      expect(find.text('Shape added to your brief. Send when ready.'), findsOneWidget);
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
      expect(find.byKey(QueueCard.cardKey), findsOneWidget);
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
    testWidgets('Send to Music uses the arrangement\'s exact skipped-track copy', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0), _spotifyTrack(1)], // one has no Apple match
      );
      final bridge = FakeBridge();
      await _pump(tester, _makeContainer(api, bridge: bridge));

      await tester.tap(find.byKey(const Key('chat-send-to-music')));
      await tester.pumpAndSettle();

      expect(bridge.playedIds, ['apple-0']);
      expect(
        find.text('Playing in Apple Music · 1 song skipped (not in Apple Music)'),
        findsOneWidget,
      );
    });

    testWidgets('a failed save reports Apple\'s own reason, capitalised as shipped', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      final bridge = FakeBridge()..failWith = MusicKitException('not authorised');
      await _pump(tester, _makeContainer(api, bridge: bridge));

      await tester.tap(find.byKey(const Key('chat-create-playlist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-playlist-save')));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't save the playlist — not authorised"),
        findsOneWidget,
      );
    });

    testWidgets('the save dialog prefills the author from the account name', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2, title: 'Night bus notes'),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      await _pump(
        tester,
        _makeContainer(api, accountName: 'Ada'),
      );

      await tester.tap(find.byKey(const Key('chat-create-playlist')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-playlist-author')))
            .controller!
            .text,
        'Ada',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-playlist-name')))
            .controller!
            .text,
        'Night bus notes',
      );
    });

    testWidgets('a device-remembered author beats the account name', (tester) async {
      final api = FakeDjApi();
      api.onGetSession = (_) async => SessionDetail(
        session: _session(queueVersion: 2),
        messages: [_msg('m1', 'dj', 'here', queueVersion: 2)],
        queue: [_track(0)],
      );
      final store = InMemoryAuthorStore();
      await store.write('Grace');
      await _pump(
        tester,
        _makeContainer(api, authorStore: store, accountName: 'Ada'),
      );

      await tester.tap(find.byKey(const Key('chat-create-playlist')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-playlist-author')))
            .controller!
            .text,
        'Grace',
      );
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
      expect(find.text('Send to a transfer tool'), findsOneWidget);
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
      expect(
        tester.widget<TapeButton>(find.byKey(const Key('chat-play-now'))).onPressed,
        isNull,
      );
      expect(find.text('Send to a transfer tool'), findsNothing);
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
      expect(find.byKey(QueueCard.cardKey), findsOneWidget);
      // The cassette keeps its 52 pt even at 200% text.
      expect(
        tester.getSize(find.byType(CassetteTile)).width,
        QueueCard.cassetteWidth,
      );
      // The mix actions wrap rather than truncate, and the composer stays
      // reachable above the keyboard-free bottom.
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
        (tester.widget<Container>(find.byKey(ConversationTurn.djKey)).decoration
                as BoxDecoration)
            .color,
        ConversationTurn.djFillDark,
      );
    });
  });
}
