// A tapped mix-ready push opens that mix through the Mixes route, cold and
// warm; a failed turn's push puts the listener's words back in the composer
// (spec 2026-11-21 durable mix turns → iOS client, "Tapping the
// notification"). The conversation on screen tells `mixtape/push`, so a push
// for it is not shown while the listener is looking at it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/push/push_service.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../helpers/fake_push_channel.dart';
import '../presentation/providers/playlist_context_provider_test.dart'
    show FakeContextApi;
import 'chat_screen_test.dart' show FakeBridge, FakeDjApi, TestAuthNotifier;

DjSession _session(String id) => DjSession(
  id: id,
  title: 'Mix $id',
  status: 'active',
  queueVersion: 1,
  updatedAt: DateTime(2026, 1, 1),
);

DjMessage _msg(String id, String role, String content) => DjMessage(
  id: id,
  role: role,
  content: content,
  createdAt: DateTime(2026, 1, 1),
);

String _composer(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('prompt-field')))
    .controller!
    .text;

void main() {
  late FakeDjApi api;
  late FakePushChannel push;
  late Map<String, List<DjMessage>> transcripts;
  final navigatorKey = GlobalKey<NavigatorState>();

  setUp(() {
    push = FakePushChannel();
    transcripts = {
      's1': [
        _msg('m1', 'user', 'rainy sunday'),
        _msg('m2', 'dj', 'here you go'),
        _msg('m3', 'user', 'more jazz please'),
      ],
      's2': [_msg('m1', 'user', 'gym'), _msg('m2', 'dj', 'done')],
    };
    api = FakeDjApi();
    api.onListSessions = () async => [_session('s1'), _session('s2')];
    api.onPostSessionEvent = (_, _) async {};
    api.onGetSession = (id) async => SessionDetail(
      session: _session(id),
      messages: transcripts[id]!,
      queue: const [],
    );
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        musicKitBridgeProvider.overrideWithValue(FakeBridge()),
        authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
        accountNameProvider.overrideWith((ref) async => null),
        mixEnergyProvider.overrideWith((ref, key) async => const {}),
        musicPlatformStoreProvider.overrideWithValue(
          InMemoryMusicPlatformStore(),
        ),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        djApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        playlistContextApiProvider.overrideWithValue(FakeContextApi()),
        playbackProvider.overrideWithValue(
          PlaybackController(playback.FakeApi(), playback.FakeBridge()),
        ),
        pushChannelProvider.overrideWithValue(push),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: MixtapeTheme.light(),
          home: const Scaffold(body: Text('Mixes list')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> open(WidgetTester tester, PushTap tap) async {
    openMixFromNotification(navigatorKey.currentState!, tap);
    await tester.pumpAndSettle();
  }

  testWidgets('a ready push opens the mix, composer empty', (tester) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'ready'),
    );
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.sessionId, 's1');
    expect(find.text('more jazz please'), findsOneWidget);
    expect(_composer(tester), isEmpty);
  });

  testWidgets(
    'a failed push opens the mix with the words back in the composer',
    (tester) async {
      await pump(tester);
      await open(
        tester,
        const PushTap(sessionId: 's1', turnId: 't1', kind: 'failed'),
      );
      expect(_composer(tester), 'more jazz please');
    },
  );

  testWidgets('a failed push restores nothing when the DJ already answered', (
    tester,
  ) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's2', turnId: 't1', kind: 'failed'),
    );
    expect(_composer(tester), isEmpty);
  });

  testWidgets('a failed remake is not put back as words', (tester) async {
    transcripts['s1'] = [
      _msg('m1', 'user', 'rainy sunday'),
      _msg('m2', 'dj', 'here you go'),
      _msg('m3', 'user', remakeText),
    ];
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'failed'),
    );
    expect(_composer(tester), isEmpty);
  });

  testWidgets('the mix already on screen is not opened twice', (tester) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'ready'),
    );
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't2', kind: 'failed'),
    );
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(_composer(tester), 'more jazz please');
  });

  testWidgets('another mix opens over the one on screen', (tester) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'ready'),
    );
    await open(
      tester,
      const PushTap(sessionId: 's2', turnId: 't2', kind: 'ready'),
    );
    expect(
      tester.widget<ChatScreen>(find.byType(ChatScreen).last).sessionId,
      's2',
    );
  });

  testWidgets('a draft the listener has typed is never overwritten', (
    tester,
  ) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'ready'),
    );
    await tester.enterText(find.byKey(const Key('prompt-field')), 'my draft');
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't2', kind: 'failed'),
    );
    expect(_composer(tester), 'my draft');
  });

  testWidgets('the conversation on screen is the visible session', (
    tester,
  ) async {
    await pump(tester);
    await open(
      tester,
      const PushTap(sessionId: 's1', turnId: 't1', kind: 'ready'),
    );
    expect(push.visible.last, 's1');

    // Covered by another screen: no longer what the listener sees.
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(push.visible.last, isNull);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(push.visible.last, 's1');

    // Back to the list.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(push.visible.last, isNull);
  });
}
