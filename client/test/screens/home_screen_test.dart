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
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/home_panel.dart';
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

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
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

/// authProvider override settled at a stable signedIn status — no real
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
    authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
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
        api.onGetSession = (id) async =>
            SessionDetail(session: _session(id: id), messages: [], queue: []);
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
      api.onGetSession = (id) async =>
          SessionDetail(session: _session(id: id), messages: [], queue: []);
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
}
