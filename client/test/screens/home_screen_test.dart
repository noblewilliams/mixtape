// The Home tab in the native shell (plan `docs/superpowers/plans/
// 2026-09-17-native-design-implementation.md` task 3.1; the approved Home
// records of 2026-09-17).
//
// Home is a large title over open space with one hint line, plus the bottom
// panel that holds everything you can do. The mix list moved to Mixes (task
// 2.3) and the menu's destinations to Library and You (task 2.2).
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/home_mode_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/home_panel.dart';
import 'package:mixtape/presentation/screens/shell/shell_route_observer.dart';
import 'package:mixtape/presentation/widgets/foundation/liquid_glass_surface.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import '../helpers/fake_listening_api.dart';
import 'routine_suggestions_test.dart' show FakeSuggestions;

/// Mirrors chat_screen_test.dart's FakeDjApi: implements DjApi's public
/// surface (not `extends`, since DjApi's constructor builds a real
/// ApiClient), each method delegating to a settable callback that throws
/// loudly when unset rather than hanging.
class FakeDjApi implements DjApi {
  @override
  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) async {}

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

  /// Every kind and seed `createSession` was called with, in order.
  final List<SessionKind> kinds = [];
  final List<InitialPlaylistSeed?> seeds = [];
  final List<String> prompts = [];

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<AlbumPickState> choosePick(
    String sessionId, {
    required String albumId,
    int? expectedVersion,
  }) => throw UnimplementedError();

  @override
  Future<AlbumPickState> goBackToPick(
    String sessionId, {
    required int version,
    int? expectedVersion,
  }) => throw UnimplementedError();

  @override
  Future<List<ListenLaterEntry>> listListenLater() =>
      throw UnimplementedError();

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) =>
      throw UnimplementedError();

  @override
  Future<void> unsaveForLater(String albumId) => throw UnimplementedError();

  @override
  Future<ListenLaterEntry> markListened(String albumId) =>
      throw UnimplementedError();

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) {
    kinds.add(kind);
    seeds.add(playlistSeed);
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

/// authProvider override settled at a stable session status — no real
/// keychain restore, no async transition mid-test (same pattern as
/// dj_providers_test.dart's TestAuthNotifier).
class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

DjSession _session({
  String id = 's1',
  String title = 'Test Session',
  String status = 'active',
  int queueVersion = 1,
  DateTime? updatedAt,
}) => DjSession(
  id: id,
  title: title,
  status: status,
  queueVersion: queueVersion,
  updatedAt: updatedAt ?? DateTime.now(),
);

ProviderContainer _makeContainer(
  FakeDjApi api, {
  FakeSuggestions? suggestions,
  bool albumPicks = true,
  bool anonymous = false,
  bool Function(Ref ref)? albumPicksFrom,
}) {
  final overrides = [
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    djApiProvider.overrideWithValue(api),
    // Home watches onboarding for the Spotify waiting card; an Apple
    // listener keeps every existing assertion untouched.
    listeningApiProvider.overrideWithValue(FakeListeningApi()),
    // The panel's first idea pill. No platform time zone channel in a test.
    suggestionsApiProvider.overrideWithValue(suggestions ?? FakeSuggestions()),
    suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
    authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
    // The Mix | Album control (album picks Task 11): on unless a test says
    // the flag is off or the listener is anonymous.
    albumPicksFrom != null
        ? albumPicksEnabledProvider.overrideWith(albumPicksFrom)
        : albumPicksEnabledProvider.overrideWithValue(albumPicks && !anonymous),
    isAnonymousProvider.overrideWithValue(anonymous),
  ];
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool settle = true,
  bool reduceMotion = false,
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
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reduceMotion,
            ),
            child: const HomeScreen(),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void main() {
  group('prompt-first session start', () {
    testWidgets(
      'submitting the prompt calls sessionStarter with the trimmed text '
      'and navigates to ChatScreen on success',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        String? capturedPrompt;
        api.onCreateSession = (prompt) async {
          capturedPrompt = prompt;
          return SessionDetail(
            session: _session(id: 'new-1'),
            messages: [],
            queue: [],
          );
        };
        api.onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          '  chill sunset drive  ',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(capturedPrompt, 'chill sunset drive');
        expect(find.byType(ChatScreen), findsOneWidget);
        final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
        expect(pushed.sessionId, 'new-1');
      },
    );

    testWidgets(
      'a shape on the chip rides out with the message, not in the field',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        String? capturedPrompt;
        api.onCreateSession = (prompt) async {
          capturedPrompt = prompt;
          return SessionDetail(
            session: _session(id: 'new-1'),
            messages: [],
            queue: [],
          );
        };
        api.onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
        await _pump(tester, _makeContainer(api));

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'chill sunset drive',
        );
        await tester.pump();

        await tester.tap(find.byKey(EnergyControl.chipKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EnergyControl.confirmKey));
        await tester.pumpAndSettle();

        // The chip wears it; the field is exactly what was typed.
        expect(find.text(EnergyArc.fall.label), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('prompt-field')))
              .controller!
              .text,
          'chill sunset drive',
        );

        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(
          capturedPrompt,
          'chill sunset drive\nEnergy journey: ${EnergyArc.fall.label}.',
          reason: 'the sentence is composed on the way out',
        );
      },
    );

    testWidgets('with no shape set, the raw draft is what is sent', (
      tester,
    ) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      String? capturedPrompt;
      api.onCreateSession = (prompt) async {
        capturedPrompt = prompt;
        return SessionDetail(
          session: _session(id: 'new-1'),
          messages: [],
          queue: [],
        );
      };
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'chill sunset drive',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(capturedPrompt, 'chill sunset drive');
    });

    testWidgets('Clear takes the shape back off the chip', (tester) async {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      await _pump(tester, _makeContainer(api));

      await tester.tap(find.byKey(EnergyControl.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.rise)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.confirmKey));
      await tester.pumpAndSettle();
      expect(find.text(EnergyArc.rise.label), findsOneWidget);

      await tester.tap(find.byKey(EnergyControl.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.clearKey));
      await tester.pumpAndSettle();

      expect(find.text(EnergyControl.unsetLabel), findsOneWidget);
      expect(find.text(EnergyArc.rise.label), findsNothing);
    });

    testWidgets(
      'a composed message with no room says so under the composer and sends '
      'nothing',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        var creates = 0;
        api.onCreateSession = (prompt) async {
          creates += 1;
          return SessionDetail(
            session: _session(id: 'new-1'),
            messages: [],
            queue: [],
          );
        };
        await _pump(tester, _makeContainer(api));

        await tester.tap(find.byKey(EnergyControl.chipKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.rise)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EnergyControl.confirmKey));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'x' * 2000,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(creates, 0);
        expect(find.text(energySheetTooLong), findsOneWidget);
      },
    );

    testWidgets(
      'the start button is disabled while a create is in flight, and a second '
      'tap does not mint a second session',
      (tester) async {
        final completer = Completer<SessionDetail>();
        var createCalls = 0;
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) {
          createCalls++;
          return completer.future;
        };
        api.onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'a prompt',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pump();

        final button = tester.widget<IconButton>(
          find.byKey(const Key('start-session')),
        );
        expect(button.onPressed, isNull);
        final field = tester.widget<TextField>(
          find.byKey(const Key('prompt-field')),
        );
        expect(field.readOnly, isTrue);

        // Tapping the (structurally disabled) button again is a no-op.
        await tester.tap(
          find.byKey(const Key('start-session')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(createCalls, 1);

        completer.complete(
          SessionDetail(
            session: _session(id: 'new-2'),
            messages: [],
            queue: [],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatScreen), findsOneWidget);
      },
    );

    testWidgets(
      'a create failure that carries a sessionId still navigates to ChatScreen',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) async => throw DjApiException(
          kind: 'conflict',
          message: 'the DJ hiccupped',
          sessionId: 'partial-1',
        );
        api.onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'play jazz',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(find.byType(ChatScreen), findsOneWidget);
        final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
        expect(pushed.sessionId, 'partial-1');
      },
    );

    testWidgets(
      'a create failure without a sessionId shows the alert line in the panel '
      'and preserves the prompt draft',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) async => throw DjApiException(
          kind: 'invalid',
          message: 'try a shorter prompt',
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'a very long prompt',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(find.byType(ChatScreen), findsNothing);
        expect(find.text('try a shorter prompt'), findsOneWidget);
        // Inside the panel, under the composer.
        expect(
          find.descendant(
            of: find.byType(HomePanel),
            matching: find.byKey(HomePanel.errorKey),
          ),
          findsOneWidget,
        );
        final field = tester.widget<TextField>(
          find.byKey(const Key('prompt-field')),
        );
        expect(field.controller!.text, 'a very long prompt');
        final button = tester.widget<IconButton>(
          find.byKey(const Key('start-session')),
        );
        expect(button.onPressed, isNotNull); // usable again, not stuck disabled
      },
    );

    testWidgets(
      'a create failure with a sessionId passes the server message through as '
      "ChatScreen's initialError",
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) async => throw DjApiException(
          kind: 'conflict',
          message: 'the DJ hiccupped',
          sessionId: 'partial-1',
        );
        api.onGetSession = (id) async => SessionDetail(
          session: _session(id: id),
          messages: [],
          queue: [],
        );
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'play jazz',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        final pushed = tester.widget<ChatScreen>(find.byType(ChatScreen));
        expect(pushed.initialError, 'the DJ hiccupped');
      },
    );

    testWidgets(
      'a NetworkException on submit shows the offline message and preserves the draft',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) async => throw NetworkException('boom');
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'a network-flaky prompt',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(find.byType(ChatScreen), findsNothing);
        expect(
          find.text(
            "couldn't reach the DJ — check your connection and try again",
          ),
          findsOneWidget,
        );
        final field = tester.widget<TextField>(
          find.byKey(const Key('prompt-field')),
        );
        expect(field.controller!.text, 'a network-flaky prompt');
      },
    );

    testWidgets(
      'a plain ApiException on submit shows the generic message and preserves the draft',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        api.onCreateSession = (prompt) async =>
            throw ApiException(500, 'internal server error');
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'a 500 prompt',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();

        expect(find.byType(ChatScreen), findsNothing);
        expect(
          find.text('something went wrong on our end — try again'),
          findsOneWidget,
        );
        final field = tester.widget<TextField>(
          find.byKey(const Key('prompt-field')),
        );
        expect(field.controller!.text, 'a 500 prompt');
      },
    );
  });

  group('native layout', () {
    testWidgets('a large title over open space, with the panel at the bottom', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeDjApi()..onListSessions = () async => [];
      await _pump(tester, _makeContainer(api));

      expect(find.text('Home'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(HomeScreen.hintKey), findsOneWidget);
      expect(find.text(HomeScreen.hintText), findsOneWidget);
      expect(find.byType(HomePanel), findsOneWidget);
      // The dock's mini-player replaces Home's own (task 2.1).
      expect(find.byType(PlaybackMini), findsNothing);
      // Three idea pills, and the hint above them.
      expect(find.byType(IdeaPill), findsNWidgets(3));
      expect(
        tester.getRect(find.byKey(HomeScreen.hintKey)).bottom,
        lessThan(tester.getRect(find.byType(HomePanel)).top),
      );
      // Nothing of the old Home is left.
      expect(find.byType(BackButton), findsNothing);
      expect(find.byKey(const Key('home-actions')), findsNothing);
      expect(find.byKey(const Key('sessions-list')), findsNothing);
      expect(find.byKey(const Key('sessions-empty')), findsNothing);
    });

    testWidgets(
      'the Shape chip rides the panel row above the composer, trailing the '
      'Mix | Album control (album picks board H1, superseding the title row)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FakeDjApi()..onListSessions = () async => [];
        await _pump(tester, _makeContainer(api));

        final chip = find.byKey(EnergyControl.chipKey);
        final mix = find.byKey(HomeScreen.modeMixKey);
        final album = find.byKey(HomeScreen.modeAlbumKey);
        for (final finder in [chip, mix, album]) {
          expect(
            find.descendant(of: find.byType(HomePanel), matching: finder),
            findsOneWidget,
          );
        }
        // The title row carries nothing beside "Home" now.
        expect(
          tester.getRect(chip).top,
          greaterThan(tester.getRect(find.byType(HomePanel)).top),
        );

        final composer = tester.getRect(find.byType(MixPromptInput));
        final chipRect = tester.getRect(chip);
        final track = tester.getRect(find.byKey(SegmentedToggle.trackKey));
        // One row, above the composer, under the handle.
        expect(chipRect.bottom, lessThanOrEqualTo(composer.top));
        expect(track.bottom, lessThanOrEqualTo(composer.top));
        expect(
          track.top,
          greaterThan(tester.getRect(find.byKey(HomePanel.handleKey)).bottom),
        );
        expect(
          chipRect.center.dy,
          moreOrLessEquals(track.center.dy, epsilon: 1),
        );
        // Control leading, chip trailing.
        expect(track.left, moreOrLessEquals(composer.left, epsilon: 4));
        expect(chipRect.right, moreOrLessEquals(composer.right, epsilon: 4));
        // 26 pt drawn, 44 pt to touch.
        expect(track.height, moreOrLessEquals(26, epsilon: 0.5));
        expect(chipRect.height, moreOrLessEquals(26, epsilon: 0.5));
        for (final segment in [mix, album]) {
          expect(
            tester.getRect(segment).height,
            greaterThanOrEqualTo(MixtapeMetrics.minTarget),
          );
        }
      },
    );

    testWidgets('Home does not scroll while the panel fits', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeDjApi()..onListSessions = () async => [];
      await _pump(tester, _makeContainer(api));

      final scrollable = tester.widget<Scrollable>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.controller!.position.maxScrollExtent, 0);
      // No pull-to-refresh on Home.
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });

    testWidgets('the keyboard lifts the panel and drops the hint', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final api = FakeDjApi()..onListSessions = () async => [];
      await _pump(tester, _makeContainer(api));
      final resting = tester.getRect(find.byType(HomePanel));

      tester.view.viewInsets = const FakeViewPadding(bottom: 500);
      await tester.pumpAndSettle();

      final composer = tester.getRect(find.byKey(const Key('prompt-field')));
      expect(composer.bottom, lessThanOrEqualTo(844 - 500));
      expect(tester.getRect(find.byType(HomePanel)).top, lessThan(resting.top));
      // Too little space left for it.
      expect(find.byKey(HomeScreen.hintKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('starting a mix turns the hubs and locks the composer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final completer = Completer<SessionDetail>();
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) => completer.future;
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      await _pump(tester, _makeContainer(api));

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'a slow wind-down',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();

      expect(find.byKey(HomeScreen.startingKey), findsOneWidget);
      expect(find.text(HomeScreen.startingTitle), findsOneWidget);
      expect(find.text(HomeScreen.startingHint), findsOneWidget);
      expect(find.byType(CassetteTile), findsOneWidget);
      expect(find.byKey(HomeScreen.hintKey), findsNothing);
      // The prompt is still there, and the field is locked.
      final field = tester.widget<TextField>(
        find.byKey(const Key('prompt-field')),
      );
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, 'a slow wind-down');
      // Pills go dim and inert.
      expect(
        tester
            .widgetList<IdeaPill>(find.byType(IdeaPill))
            .every((pill) => pill.dimmed),
        isTrue,
      );
      // Announced, per the approved record.
      expect(
        tester
            .getSemantics(find.byKey(HomeScreen.startingKey))
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );

      completer.complete(
        SessionDetail(
          session: _session(id: 'new-3'),
          messages: [],
          queue: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets(
      'short narrow screen supports large text and keyboard draft without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = FakeViewPadding.zero;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final api = FakeDjApi()..onListSessions = () async => [];
        await _pump(tester, _makeContainer(api), textScale: 2);
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'Quiet soul\nfor my evening\nwith warm vocals',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('prompt-field')))
              .controller!
              .text,
          'Quiet soul\nfor my evening\nwith warm vocals',
        );
        expect(
          find.byKey(const Key('start-session')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final brightness in Brightness.values) {
      testWidgets('renders synthetic Home in ${brightness.name} theme', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const output = String.fromEnvironment('NATIVE_HOME_SNAPSHOT_DIR');
        if (output.isNotEmpty) {
          final icons = FontLoader('MaterialIcons');
          icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await tester.runAsync(icons.load);
          const fontPath = String.fromEnvironment('NATIVE_HOME_SNAPSHOT_FONT');
          if (fontPath.isNotEmpty) {
            final loader = FontLoader('NativeSnapshot');
            loader.addFont(
              Future.value(
                ByteData.sublistView(File(fontPath).readAsBytesSync()),
              ),
            );
            await tester.runAsync(loader.load);
          }
        }
        final api = FakeDjApi()..onListSessions = () async => [];
        const boundaryKey = Key('native-home-snapshot');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: _makeContainer(api),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: brightness == Brightness.dark
                  ? MixtapeTheme.dark()
                  : MixtapeTheme.light(),
              home: const RepaintBoundary(
                key: boundaryKey,
                child: HomeScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('prompt-field')), findsOneWidget);
        expect(find.byType(IdeaPill), findsNWidgets(3));
        if (output.isNotEmpty) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundaryKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$output/native-home-${brightness.name}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  });

  group('Mix | Album (album picks Task 11, board H1 to H4)', () {
    FakeDjApi recordingApi() {
      final api = FakeDjApi();
      api.onListSessions = () async => [];
      api.onCreateSession = (prompt) async {
        api.prompts.add(prompt);
        return SessionDetail(
          session: _session(id: 'new-1'),
          messages: [],
          queue: [],
        );
      };
      api.onGetSession = (id) async => SessionDetail(
        session: _session(id: id),
        messages: [],
        queue: [],
      );
      return api;
    }

    bool selected(WidgetTester tester, Key key) => tester
        .getSemantics(find.byKey(key))
        .getSemanticsData()
        .flagsCollection
        .isSelected;

    String sendLabel(WidgetTester tester) => tester
        .widget<IconButton>(find.byKey(const Key('start-session')))
        .tooltip!;

    String? hint(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('prompt-field')))
        .decoration!
        .hintText;

    Future<void> chooseShape(WidgetTester tester, EnergyArc arc) async {
      await tester.tap(find.byKey(EnergyControl.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.presetKey(arc)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EnergyControl.confirmKey));
      await tester.pumpAndSettle();
    }

    testWidgets('Mix is the default, the shape folds in, and the kind is mix', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final api = recordingApi();
      await _pump(tester, _makeContainer(api));

      expect(selected(tester, HomeScreen.modeMixKey), isTrue);
      expect(selected(tester, HomeScreen.modeAlbumKey), isFalse);
      expect(find.bySemanticsLabel('What to make'), findsOneWidget);
      expect(find.byKey(EnergyControl.chipKey), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'a slow walk',
      );
      await tester.pump();
      expect(sendLabel(tester), 'Start new mix');
      await chooseShape(tester, EnergyArc.fall);
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(api.kinds, [SessionKind.mix]);
      expect(
        api.prompts.single,
        'a slow walk\nEnergy journey: ${EnergyArc.fall.label}.',
      );
      handle.dispose();
    });

    testWidgets(
      'Album drops the chip, fixes the placeholder, renames Send, swaps the '
      'pills, and sends the raw draft as an album',
      (tester) async {
        final handle = tester.ensureSemantics();
        final api = recordingApi();
        await _pump(tester, _makeContainer(api));
        final rowHeight = tester
            .getRect(find.byKey(HomePanel.modeRowKey))
            .height;

        // A shape chosen under Mix must not ride out with an album ask.
        await chooseShape(tester, EnergyArc.rise);
        await tester.tap(find.byKey(HomeScreen.modeAlbumKey));
        await tester.pumpAndSettle();

        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
        expect(find.byKey(EnergyControl.chipKey), findsNothing);
        expect(
          tester.getRect(find.byKey(HomePanel.modeRowKey)).height,
          moreOrLessEquals(rowHeight, epsilon: 0.5),
          reason: 'the row keeps its height so nothing jumps',
        );
        expect(hint(tester), 'What kind of record are you in the mood for…');
        for (final pill in const [
          'Rainy evening, start to finish',
          'Something I have never heard',
          'One I own and forgot',
        ]) {
          expect(find.widgetWithText(IdeaPill, pill), findsOneWidget);
        }
        expect(find.byType(IdeaPill), findsNWidgets(3));

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'something warm for cooking',
        );
        await tester.pump();
        expect(sendLabel(tester), 'Find an album');
        expect(find.bySemanticsLabel('Find an album'), findsOneWidget);

        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();
        expect(api.kinds, [SessionKind.album]);
        expect(api.prompts.single, 'something warm for cooking');
        handle.dispose();
      },
    );

    testWidgets(
      'typing "album" under Mix switches once, says so in place of the pills, '
      'and "Keep it a mix" undoes it for the rest of the draft',
      (tester) async {
        final handle = tester.ensureSemantics();
        final api = recordingApi();
        await _pump(tester, _makeContainer(api));
        final field = find.byKey(const Key('prompt-field'));

        await tester.enterText(field, 'an album for the train home');
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsOneWidget);
        expect(find.text(HomePanel.switchedText), findsOneWidget);
        expect(find.byKey(HomePanel.keepMixKey), findsOneWidget);
        expect(find.text('Keep it a mix'), findsOneWidget);
        expect(find.byType(IdeaPill), findsNothing);
        expect(
          tester
              .getSemantics(find.byKey(HomePanel.switchedKey))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );

        await tester.tap(find.byKey(HomePanel.keepMixKey));
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeMixKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsNothing);

        await tester.enterText(field, 'an album for the train home, albums');
        await tester.pumpAndSettle();
        expect(
          selected(tester, HomeScreen.modeMixKey),
          isTrue,
          reason: 'one nudge per draft',
        );
        expect(find.byKey(HomePanel.switchedKey), findsNothing);

        // Clearing the field re-arms it.
        await tester.enterText(field, '');
        await tester.pumpAndSettle();
        await tester.enterText(field, 'an Album please');
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsOneWidget);

        // A manual tap on Mix suppresses it the same way.
        await tester.tap(find.byKey(HomeScreen.modeMixKey));
        await tester.pumpAndSettle();
        expect(find.byKey(HomePanel.switchedKey), findsNothing);
        await tester.enterText(field, 'an Album please, an album');
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeMixKey), isTrue);

        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();
        expect(api.kinds, [SessionKind.mix]);
        handle.dispose();
      },
    );

    testWidgets('a nudged prompt is sent as an album with the raw draft', (
      tester,
    ) async {
      final api = recordingApi();
      await _pump(tester, _makeContainer(api));
      await chooseShape(tester, EnergyArc.rise);
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'an album for the train home',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(api.kinds, [SessionKind.album]);
      expect(api.prompts.single, 'an album for the train home');
    });

    for (final (name, anonymous, albumPicks) in const [
      ('an anonymous listener', true, true),
      ('albums off', false, false),
    ]) {
      testWidgets('$name: no control, the chip keeps the row, nothing nudges', (
        tester,
      ) async {
        final api = recordingApi();
        await _pump(
          tester,
          _makeContainer(api, anonymous: anonymous, albumPicks: albumPicks),
        );
        expect(find.byKey(HomeScreen.modeMixKey), findsNothing);
        expect(find.byKey(HomeScreen.modeAlbumKey), findsNothing);
        expect(find.byType(SegmentedToggle<SessionKind>), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(HomePanel.modeRowKey),
            matching: find.byKey(EnergyControl.chipKey),
          ),
          findsOneWidget,
        );
        expect(
          tester.getRect(find.byKey(EnergyControl.chipKey)).height,
          moreOrLessEquals(26, epsilon: 0.5),
        );

        await tester.enterText(
          find.byKey(const Key('prompt-field')),
          'an album for the train home',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(HomePanel.switchedKey), findsNothing);
        expect(find.byKey(EnergyControl.chipKey), findsOneWidget);
        await tester.tap(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();
        expect(api.kinds, [SessionKind.mix]);
      });
    }

    testWidgets('at 1.5x text both row controls draw at least 28 pt', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, _makeContainer(recordingApi()), textScale: 1.5);

      final row = find.byKey(HomePanel.modeRowKey);
      final track = find.descendant(
        of: row,
        matching: find.byKey(SegmentedToggle.trackKey),
      );
      final chip = find.descendant(
        of: row,
        matching: find.byKey(EnergyControl.chipKey),
      );
      for (final control in [track, chip]) {
        final height = tester.getRect(control).height;
        expect(height, greaterThanOrEqualTo(28));
        expect(height, lessThanOrEqualTo(32));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'typing "album" before albums turn on changes nothing out of sight',
      (tester) async {
        final albumsOn = ValueNotifier(false);
        addTearDown(albumsOn.dispose);
        final api = recordingApi();
        final container = _makeContainer(
          api,
          albumPicksFrom: (ref) {
            void changed() => ref.invalidateSelf();
            albumsOn.addListener(changed);
            ref.onDispose(() => albumsOn.removeListener(changed));
            return albumsOn.value;
          },
        );
        await _pump(tester, container);
        final field = find.byKey(const Key('prompt-field'));

        await tester.enterText(field, 'an album for the train home');
        await tester.pumpAndSettle();
        expect(find.byKey(HomeScreen.modeMixKey), findsNothing);

        albumsOn.value = true;
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeMixKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsNothing);
        expect(find.byKey(EnergyControl.chipKey), findsOneWidget);

        // Still armed: the next "album" word now offered nudges.
        await tester.enterText(field, 'an album for the train home, albums');
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsOneWidget);
      },
    );

    testWidgets(
      'a nudged Album returns to Mix after a send; a hand-chosen Album stays',
      (tester) async {
        final api = recordingApi();
        await _pump(tester, _makeContainer(api));
        final field = find.byKey(const Key('prompt-field'));

        Future<void> sendAndComeBack() async {
          await tester.tap(find.byKey(const Key('start-session')));
          await tester.pumpAndSettle();
          expect(find.byType(ChatScreen), findsOneWidget);
          Navigator.of(tester.element(find.byType(ChatScreen))).pop();
          await tester.pumpAndSettle();
        }

        await tester.enterText(field, 'an album for the train home');
        await tester.pumpAndSettle();
        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
        await sendAndComeBack();
        expect(api.kinds, [SessionKind.album]);
        expect(selected(tester, HomeScreen.modeMixKey), isTrue);
        expect(find.byKey(HomePanel.switchedKey), findsNothing);

        await tester.tap(find.byKey(HomeScreen.modeAlbumKey));
        await tester.pumpAndSettle();
        await tester.enterText(field, 'something warm for cooking');
        await tester.pump();
        await sendAndComeBack();
        expect(api.kinds, [SessionKind.album, SessionKind.album]);
        expect(selected(tester, HomeScreen.modeAlbumKey), isTrue);
      },
    );

    testWidgets('reduced motion: the thumb does not slide', (tester) async {
      final api = recordingApi();
      await _pump(tester, _makeContainer(api), reduceMotion: true);
      final align = tester.widget<AnimatedAlign>(
        find.descendant(
          of: find.byType(SegmentedToggle<SessionKind>),
          matching: find.byType(AnimatedAlign),
        ),
      );
      expect(align.duration, Duration.zero);

      await tester.tap(find.byKey(HomeScreen.modeAlbumKey));
      await tester.pump();
      final thumb = tester.getRect(find.byKey(SegmentedToggle.thumbKey));
      final albumRect = tester.getRect(find.byKey(HomeScreen.modeAlbumKey));
      expect(thumb.right, moreOrLessEquals(albumRect.right, epsilon: 0.5));
    });

    testWidgets('a pending Album request opens Home on Album and is cleared', (
      tester,
    ) async {
      final api = recordingApi();
      final container = _makeContainer(api);
      container
          .read(homeModeRequestProvider.notifier)
          .request(SessionKind.album);
      await _pump(tester, container);

      expect(find.byKey(EnergyControl.chipKey), findsNothing);
      expect(hint(tester), 'What kind of record are you in the mood for…');
      expect(container.read(homeModeRequestProvider), isNull);

      // …and one made while Home is mounted is taken too.
      await tester.tap(find.byKey(HomeScreen.modeMixKey));
      await tester.pumpAndSettle();
      expect(find.byKey(EnergyControl.chipKey), findsOneWidget);
      container
          .read(homeModeRequestProvider.notifier)
          .request(SessionKind.album);
      await tester.pumpAndSettle();
      expect(find.byKey(EnergyControl.chipKey), findsNothing);
      expect(container.read(homeModeRequestProvider), isNull);
    });
  });

  group('the panel under a modal', () {
    /// Home inside a tab's route-observer scope, the way the shell builds it.
    Future<ShellRouteObserver> pumpInShell(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final observer = ShellRouteObserver();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            navigatorObservers: [observer],
            home: ShellRouteObserverScope(
              observer: observer,
              child: const HomeScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return observer;
    }

    double panelOpacity(WidgetTester tester) =>
        tester.widget<AnimatedOpacity>(find.byKey(HomePanel.veilKey)).opacity;

    bool panelAllowsNative(WidgetTester tester) => tester
        .widget<LiquidGlassSurface>(find.byKey(HomePanel.surfaceKey))
        .allowNative;

    testWidgets(
      'the panel fades out and drops its native glass while a sheet is over '
      'Home, and comes back when it pops',
      (tester) async {
        final api = FakeDjApi();
        api.onListSessions = () async => [];
        final container = _makeContainer(api);
        await pumpInShell(tester, container);

        expect(panelOpacity(tester), 1);
        expect(panelAllowsNative(tester), isTrue);

        final context = tester.element(find.byType(HomePanel));
        unawaited(
          showMixtapeSheet<void>(
            context,
            builder: (_) => const SizedBox(height: 120),
          ),
        );
        await tester.pumpAndSettle();

        expect(panelOpacity(tester), 0);
        expect(panelAllowsNative(tester), isFalse);

        Navigator.of(context).pop();
        await tester.pumpAndSettle();

        expect(panelOpacity(tester), 1);
        expect(panelAllowsNative(tester), isTrue);
      },
    );
  });
}
