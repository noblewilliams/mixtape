// The conversation for an album session (album picks plan Task 12; frames
// A1 to A8 and F1 to F3 of `docs/mockups/2026-10-20-album-picks-states.html`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/album_card.dart';
import 'package:mixtape/presentation/widgets/conversation_turn.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import 'chat_screen_test.dart' show FakeDjApi, FakeBridge, TestAuthNotifier;

class _AlbumApi extends FakeDjApi {
  Object? saveFails;

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) =>
      Future.error(saveFails ?? StateError('saveForLater not wired'));

  final List<int> wentBackTo = [];
  final List<String> picked = [];
  AlbumPickState? answer;

  @override
  Future<AlbumPickState> goBackToPick(
    String sessionId, {
    required int version,
    int? expectedVersion,
  }) async {
    wentBackTo.add(version);
    return answer!;
  }

  @override
  Future<AlbumPickState> choosePick(
    String sessionId, {
    required String albumId,
    int? expectedVersion,
  }) async {
    picked.add(albumId);
    return answer!;
  }
}

class _AlbumBridge extends FakeBridge {
  final List<String> albums = [];

  @override
  Future<bool> playAlbum(String appleAlbumId) async {
    albums.add(appleAlbumId);
    return true;
  }
}

class _Onboarding extends OnboardingNotifier {
  @override
  Future<OnboardingState> build() async => const OnboardingState(
    userId: 'u1',
    sources: [],
    hasLibrary: true,
    chosenService: 'apple',
    markedRequestedAt: null,
    interviewCompletedAt: null,
    importCompletedAt: null,
  );
}

DjSession _session({int version = 1, String title = 'Train home'}) => DjSession(
  id: 's1',
  title: title,
  status: 'active',
  queueVersion: version,
  updatedAt: DateTime(2026, 10, 20),
  kind: SessionKind.album,
);

DjMessage _msg(String id, String role, String content, {int? version}) =>
    DjMessage(
      id: id,
      role: role,
      content: content,
      queueVersion: version,
      createdAt: DateTime(2026, 10, 20),
    );

AlbumPick _album(String id, String title, {int version = 1}) => AlbumPick(
  id: id,
  title: title,
  artist: 'Mara Ilesanmi',
  type: 'album',
  releaseYear: 2019,
  trackCount: 11,
  durationMs: 44 * 60000,
  newToThem: false,
  reason: 'Slow and warm.',
  savedForLater: false,
  version: version,
  appleId: 'apple-$id',
);

SessionDetail _detail({
  int version = 1,
  List<DjMessage> messages = const [],
  AlbumPickState? pickState,
  List<String>? suggestions,
}) => SessionDetail(
  session: _session(version: version),
  messages: messages,
  queue: const [],
  pickState: pickState,
  suggestions: suggestions,
);

ProviderContainer _container(_AlbumApi api, {_AlbumBridge? bridge}) {
  api.onListSessions ??= () async => [_session()];
  api.onPostSessionEvent ??= (_, _) async {};
  final container = ProviderContainer(
    overrides: [
      musicKitBridgeProvider.overrideWithValue(bridge ?? _AlbumBridge()),
      authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
      accountNameProvider.overrideWith((ref) async => null),
      mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
      onboardingProvider.overrideWith(_Onboarding.new),
      playbackProvider.overrideWithValue(
        PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final _navigator = GlobalKey<NavigatorState>();

/// The screen pushed over a stand-in shell, as the tab navigator does.
Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: _navigator,
        theme: MixtapeTheme.light(),
        home: const Scaffold(body: Text('the shell')),
      ),
    ),
  );
  _navigator.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const ChatScreen(sessionId: 's1')),
  );
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, Finder finder) => tester.getRect(finder).top;

void main() {
  final first = _album('a1', 'Low Tide Hours');
  final second = _album('a2', 'Harbour Lights', version: 2);

  group('the frame', () {
    testWidgets('no Arrangement button; More holds Rename and Archive only', (
      tester,
    ) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async =>
            _detail(pickState: AlbumPickState(version: 1, pick: first));
      await _pump(tester, _container(api));

      expect(find.byKey(const Key('chat-arrangement')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Version history'), findsNothing);
      expect(find.text('Tape settings'), findsNothing);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Rename mix'), findsNothing);
    });

    testWidgets('the panel: inspiration stays, no Shape, no mix actions', (
      tester,
    ) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async =>
            _detail(pickState: AlbumPickState(version: 1, pick: first));
      await _pump(tester, _container(api));

      expect(find.byType(InspirationChip), findsOneWidget);
      expect(find.byKey(const Key('chat-shape-chip')), findsNothing);
      expect(find.byType(MixActionsRow), findsNothing);
    });

    testWidgets('the placeholder suggests refinements once there is a pick', (
      tester,
    ) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async =>
            _detail(pickState: AlbumPickState(version: 1, pick: first));
      await _pump(tester, _container(api));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .decoration!
            .hintText,
        'Another? Older? Something you do not know?',
      );
    });

    testWidgets('without a pick it asks for more', (tester) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async =>
            _detail(version: 0, pickState: const AlbumPickState(version: 0));
      await _pump(tester, _container(api));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .decoration!
            .hintText,
        'Tell the DJ more…',
      );
    });
  });

  testWidgets('working: finding your album, checking Apple Music', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final completer = Completer<TurnResult>();
    final api = _AlbumApi()
      ..onGetSession = (_) async =>
          _detail(version: 0, pickState: const AlbumPickState(version: 0));
    api.onSendMessage = (_, _) => completer.future;
    await _pump(tester, _container(api));

    await tester.enterText(find.byKey(const Key('prompt-field')), 'train home');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pump();

    expect(
      tester.getSemantics(find.byKey(WorkingIndicator.indicatorKey)).label,
      'Finding your album',
    );
    expect(find.byKey(WorkingIndicator.captionKey), findsNothing);
    await tester.pump(const Duration(seconds: 11));
    expect(
      find.text('Finding your album · checking Apple Music'),
      findsOneWidget,
    );

    completer.complete(
      TurnResult(
        djMessage: _msg('m2', 'dj', 'One record.', version: 1),
        queue: const [],
        queueVersion: 1,
        pickState: AlbumPickState(version: 1, pick: first),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AlbumCard.cardKey), findsOneWidget);
    semantics.dispose();
  });

  group('the transcript', () {
    testWidgets(
      'the card under the current reply; the passed pick after its own reply',
      (tester) async {
        final api = _AlbumApi()
          ..onGetSession = (_) async => _detail(
            version: 2,
            messages: [
              _msg('m1', 'user', 'An album for the train'),
              _msg('m2', 'dj', 'One record.', version: 1),
              _msg('m3', 'user', 'Another, older.'),
              _msg('m4', 'dj', 'Older then.', version: 2),
            ],
            pickState: AlbumPickState(
              version: 2,
              pick: second,
              passed: [first],
            ),
          );
        await _pump(tester, _container(api));

        final card = find.byKey(AlbumCard.cardKey);
        final passed = find.byKey(PassedOverRow.keyFor(1));
        expect(card, findsOneWidget);
        expect(passed, findsOneWidget);
        expect(
          _top(tester, card),
          greaterThan(_top(tester, find.text('Older then.'))),
        );
        expect(
          _top(tester, passed),
          greaterThan(_top(tester, find.text('One record.'))),
        );
        expect(
          _top(tester, passed),
          lessThan(_top(tester, find.text('Another, older.'))),
        );
        // No tape card, no version chip for an album.
        expect(find.byKey(const ValueKey('version-chip-1')), findsNothing);
      },
    );

    testWidgets('a passed pick with no reply of its own sits above the card', (
      tester,
    ) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          version: 3,
          messages: [
            _msg('m1', 'user', 'An album for the train'),
            _msg('m2', 'dj', 'One record.', version: 1),
          ],
          pickState: AlbumPickState(
            version: 3,
            pick: _album('a3', 'Slow Rooms', version: 3),
            passed: [first, second],
          ),
        );
      await _pump(tester, _container(api));

      final card = find.byKey(AlbumCard.cardKey);
      final one = find.byKey(PassedOverRow.keyFor(1));
      final two = find.byKey(PassedOverRow.keyFor(2));
      expect(
        _top(tester, one),
        greaterThan(_top(tester, find.text('One record.'))),
      );
      expect(_top(tester, two), greaterThan(_top(tester, one)));
      expect(_top(tester, card), greaterThan(_top(tester, two)));
    });

    testWidgets('Go back restores that version', (tester) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          version: 2,
          messages: [
            _msg('m1', 'user', 'An album for the train'),
            _msg('m2', 'dj', 'One record.', version: 1),
          ],
          pickState: AlbumPickState(version: 2, pick: second, passed: [first]),
        );
      api.answer = AlbumPickState(
        version: 3,
        pick: _album('a1', 'Low Tide Hours', version: 3),
        passed: [first, second],
      );
      await _pump(tester, _container(api));

      await tester.tap(find.byKey(PassedOverRow.goBackKey(1)));
      await tester.pumpAndSettle();
      expect(api.wentBackTo, [1]);
    });

    testWidgets('Pick this swaps the pick', (tester) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          messages: [_msg('m2', 'dj', 'One record.', version: 1)],
          pickState: AlbumPickState(
            version: 1,
            pick: first,
            runnersUp: [second],
          ),
        );
      api.answer = AlbumPickState(version: 2, pick: second, passed: [first]);
      await _pump(tester, _container(api));

      await tester.tap(find.byKey(AlbumCard.runnersKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AlbumCard.pickKey('a2')));
      await tester.pumpAndSettle();
      expect(api.picked, ['a2']);
      // The swap wrote a version with no reply: the new card stands alone
      // at the end, under the old pick's passed-over row.
      final passed = find.byKey(PassedOverRow.keyFor(1));
      final card = find.byKey(AlbumCard.cardKey);
      expect(passed, findsOneWidget);
      expect(find.text('Harbour Lights'), findsOneWidget);
      expect(
        _top(tester, passed),
        greaterThan(_top(tester, find.text('One record.'))),
      );
      expect(_top(tester, card), greaterThan(_top(tester, passed)));
      final list = tester.getRect(find.byType(ListView).first);
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(list.bottom));
      expect(
        tester.getRect(card).top,
        greaterThan(tester.getRect(find.byKey(ConversationTurn.djKey)).bottom),
      );
    });

    testWidgets('Play now hands the album id to the Music app', (tester) async {
      final bridge = _AlbumBridge();
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          messages: [_msg('m2', 'dj', 'One record.', version: 1)],
          pickState: AlbumPickState(version: 1, pick: first),
        );
      await _pump(tester, _container(api, bridge: bridge));

      await tester.tap(find.byKey(AlbumCard.playKey));
      await tester.pumpAndSettle();
      expect(bridge.albums, ['apple-a1']);
    });
  });

  testWidgets('a failed save reverts the chip and shows no shelf toast', (
    tester,
  ) async {
    final api = _AlbumApi()
      ..saveFails = NetworkException('offline')
      ..onGetSession = (_) async => _detail(
        messages: [_msg('m2', 'dj', 'One record.', version: 1)],
        pickState: AlbumPickState(version: 1, pick: first),
      );
    await _pump(tester, _container(api));

    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pumpAndSettle();
    expect(find.text('Listen later'), findsOneWidget);
    expect(find.text('Saved for later'), findsNothing);
    expect(find.text('On your Listen later shelf.'), findsNothing);
  });

  group('honest failures', () {
    testWidgets('Resend on a failed album turn sends the same words again', (
      tester,
    ) async {
      final sent = <String>[];
      final api = _AlbumApi()
        ..onGetSession = (_) async =>
            _detail(version: 0, pickState: const AlbumPickState(version: 0));
      api.onSendMessage = (_, text) async {
        sent.add(text);
        if (sent.length == 1) {
          throw DjApiException(
            kind: 'album_failed',
            message:
                'Could not reach Apple Music to check the album. Your ask is still here.',
          );
        }
        return TurnResult(
          djMessage: _msg('m3', 'dj', 'One record.', version: 1),
          queue: const [],
          queueVersion: 1,
          pickState: AlbumPickState(version: 1, pick: first),
        );
      };
      await _pump(tester, _container(api));

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'train home',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
      expect(
        find.textContaining('Could not reach Apple Music'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(ConversationTurn.resendKey));
      await tester.pumpAndSettle();
      expect(sent, ['train home', 'train home']);
      expect(find.byKey(AlbumCard.cardKey), findsOneWidget);
    });

    testWidgets('refinement pills send their words as the next turn', (
      tester,
    ) async {
      final sent = <String>[];
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          version: 0,
          messages: [
            _msg('m1', 'user', 'a dishwasher arguing with a choir'),
            _msg('m2', 'dj', 'None of them are in Apple Music.'),
          ],
          pickState: const AlbumPickState(version: 0),
          suggestions: ['Any year', 'Something stranger I do know'],
        );
      api.onSendMessage = (_, text) async {
        sent.add(text);
        return TurnResult(
          djMessage: _msg('m4', 'dj', 'Here.', version: 1),
          queue: const [],
          queueVersion: 1,
          pickState: AlbumPickState(version: 1, pick: first),
        );
      };
      await _pump(tester, _container(api));

      expect(find.byType(IdeaPill), findsNWidgets(2));
      expect(
        _top(tester, find.widgetWithText(IdeaPill, 'Any year')),
        greaterThan(
          _top(tester, find.text('None of them are in Apple Music.')),
        ),
      );
      await tester.tap(find.widgetWithText(IdeaPill, 'Any year'));
      await tester.pumpAndSettle();
      expect(sent, ['Any year']);
      expect(find.byType(IdeaPill), findsNothing);
    });

    testWidgets('Add my music goes to the Library tab', (tester) async {
      final api = _AlbumApi()
        ..onGetSession = (_) async => _detail(
          version: 0,
          messages: [_msg('m2', 'dj', 'I do not see whole albums yet.')],
          pickState: const AlbumPickState(version: 0),
          suggestions: ['Add my music', 'Something new is fine'],
        );
      final container = _container(api);
      await _pump(tester, container);

      await tester.tap(find.widgetWithText(IdeaPill, 'Add my music'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.text('the shell'), findsOneWidget);
      expect(container.read(selectedTabProvider), AppTab.library.index);
    });
  });
}
