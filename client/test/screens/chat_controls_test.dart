// The conversation's controls: the More menu's rename alert, the inspiration
// write gate, the keyboard-bound panel and the light/dark render (plan tasks
// 4.1 and 4.3).
import 'dart:async';
import '../helpers/auth_ui_snapshot.dart';
import '../presentation/widgets/playlist_inspiration_test.dart' show BrowseApi;
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import '../data/playback/playback_controller_test.dart' as playback
    show FakeApi, FakeBridge;
import '../presentation/providers/playlist_context_provider_test.dart'
    show FakeContextApi, seed;
import 'chat_screen_test.dart' show FakeDjApi, TestAuthNotifier;

DjSession session([String title = 'Sunday']) => DjSession(
  id: 'mix',
  title: title,
  status: 'active',
  queueVersion: 7,
  updatedAt: DateTime(2026),
);

/// The snapshot theme (seeded colours, the synthetic font) plus the design
/// tokens every native widget reads off the ambient theme.
ThemeData nativeSnapshotTheme(Brightness brightness) =>
    authSnapshotTheme(brightness).copyWith(
      extensions: [
        brightness == Brightness.dark
            ? MixtapeTokens.dark
            : MixtapeTokens.light,
      ],
    );

void main() {
  late FakeDjApi api;
  late FakeContextApi inspiration;
  late ProviderContainer container;
  setUp(() {
    api = FakeDjApi();
    api.onGetSession = (_) async =>
        SessionDetail(session: session(), messages: [], queue: []);
    api.onListSessions = () async => [session()];
    api.onRenameSession = (_, title) async => session(title);
    inspiration = FakeContextApi();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
        djApiProvider.overrideWithValue(api),
        playlistContextApiProvider.overrideWithValue(inspiration),
        playlistApiProvider.overrideWithValue(BrowseApi()),
        playbackProvider.overrideWithValue(
          PlaybackController(playback.FakeApi(), playback.FakeBridge()),
        ),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const ChatScreen(sessionId: 'mix'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Rename opens a native alert with the title preselected and keeps the draft', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('prompt-field')), 'keep my draft');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    final field = tester.widget<CupertinoTextField>(
      find.byKey(const Key('chat-rename-field')),
    );
    expect(field.controller!.text, 'Sunday');
    expect(field.controller!.selection.baseOffset, 0);
    expect(field.controller!.selection.extentOffset, 'Sunday'.length);

    await tester.enterText(
      find.byKey(const Key('chat-rename-field')),
      'A softer Sunday',
    );
    await tester.tap(find.byKey(const Key('chat-rename-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('A softer Sunday'), findsOneWidget);
    expect(find.text('keep my draft'), findsOneWidget);
    expect(container.read(chatProvider('mix')).value!.queueVersion, 7);
  });

  testWidgets('inspiration mutation blocks send without losing text', (
    tester,
  ) async {
    inspiration.read = () async => seed(1, id: 'source');
    await pump(tester);
    await tester.enterText(
      find.byKey(const Key('prompt-field')),
      'keep my draft',
    );
    await tester.pump();
    final pending = Completer<dynamic>();
    inspiration.write = () async => await pending.future;
    final write = container
        .read(sessionPlaylistContextProvider('mix').notifier)
        .select(playlistId: null);
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('start-session'))).onPressed,
      isNull,
    );
    expect(find.text('keep my draft'), findsOneWidget);
    pending.complete(seed(2));
    await write;
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('start-session'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('short large-text keyboard keeps the composer reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    inspiration.read = () async =>
        seed(1, id: 'Night Bus Notes with a very long name');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 260),
            ),
            child: child!,
          ),
          home: const ChatScreen(sessionId: 'mix'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('prompt-field')),
      'one\ntwo\nthree\nfour',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('start-session')).hitTestable(), findsOneWidget);
    expect(find.text('one\ntwo\nthree\nfour'), findsOneWidget);
  });

  testWidgets('late DJ title cannot replace a manual conversation name', (
    tester,
  ) async {
    final turn = Completer<TurnResult>();
    api.onSendMessage = (_, _) => turn.future;
    await pump(tester);
    final send = container
        .read(chatProvider('mix').notifier)
        .send('change the pace');
    await tester.pump();
    expect(
      await container
          .read(chatProvider('mix').notifier)
          .rename('My chosen name'),
      true,
    );
    turn.complete(
      TurnResult(
        djMessage: DjMessage(
          id: 'reply',
          role: 'dj',
          content: 'Done',
          createdAt: DateTime(2026),
        ),
        queue: [],
        queueVersion: 8,
        sessionTitle: 'Older generated name',
      ),
    );
    await send;
    await tester.pumpAndSettle();
    expect(
      container.read(chatProvider('mix')).value!.session.title,
      'My chosen name',
    );
    expect(container.read(chatProvider('mix')).value!.queueVersion, 8);
  });

  testWidgets('pending recovery read keeps a newer manual title', (
    tester,
  ) async {
    await pump(tester);
    final read = Completer<SessionDetail>();
    api.onGetSession = (_) => read.future;
    api.onSendMessage = (_, _) async =>
        throw DjApiException(kind: 'stale', message: 'stale');
    final send = container.read(chatProvider('mix').notifier).send('retry');
    await tester.pump();
    expect(
      await container
          .read(chatProvider('mix').notifier)
          .rename('My chosen name'),
      true,
    );
    read.complete(
      SessionDetail(session: session('Old snapshot'), messages: [], queue: []),
    );
    await send;
    expect(
      container.read(chatProvider('mix')).value!.session.title,
      'My chosen name',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('conversation ${brightness.name} render', (tester) async {
      await loadAuthSnapshotFonts(tester);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      inspiration.read = () async => seed(1, id: 'Night Bus Notes');
      api.onGetSession = (_) async => SessionDetail(
        session: session('A slow way into Sunday'),
        messages: [
          DjMessage(
            id: 'm1',
            role: 'user',
            content:
                'A warm start, a little lift in the middle, then room to wind down.',
            createdAt: DateTime(2026),
          ),
        ],
        queue: [],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: nativeSnapshotTheme(brightness),
            home: const RepaintBoundary(
              key: authSnapshotKey,
              child: ChatScreen(sessionId: 'mix'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureAuthSnapshot(tester, 'native-chat-${brightness.name}');
    });
  }
}
