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
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import '../helpers/fake_listening_api.dart';

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

ProviderContainer _makeContainer(FakeDjApi api) {
  final overrides = [
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    djApiProvider.overrideWithValue(api),
    // Home watches onboarding for the Spotify waiting card; an Apple
    // listener keeps every existing assertion untouched.
    listeningApiProvider.overrideWithValue(FakeListeningApi()),
    authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
  ];
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
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
      'a create failure without a sessionId shows an inline error and '
      'preserves the prompt draft',
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

  group('responsive native layout', () {
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
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: _makeContainer(api),
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const HomeScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
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
        await tester.ensureVisible(find.byKey(const Key('start-session')));
        await tester.pumpAndSettle();
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
              theme: ThemeData(
                colorSchemeSeed: const Color(0xFF544451),
                useMaterial3: true,
                brightness: brightness,
                fontFamily: output.isEmpty ? null : 'NativeSnapshot',
              ),
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

  group('home navigation', () {
    testWidgets(
      'Home is a tab root: no back button, no overflow menu and no mix list',
      (tester) async {
        final api = FakeDjApi()
          ..onListSessions = () async => [_session(title: 'Sunset Drive')];
        await _pump(tester, _makeContainer(api));

        expect(find.byType(BackButton), findsNothing);
        // The menu's destinations are the Library and You tabs now (task 2.2),
        // and the list is the Mixes tab (task 2.3).
        expect(find.byKey(const Key('home-actions')), findsNothing);
        expect(find.byKey(const Key('active-mixes')), findsNothing);
        expect(find.byKey(const Key('archived-mixes')), findsNothing);
        expect(find.byKey(const Key('sessions-list')), findsNothing);
        expect(find.byKey(const Key('sessions-empty')), findsNothing);
        expect(find.text('Sunset Drive'), findsNothing);
        // The composer is what is left.
        expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      },
    );
  });

}
