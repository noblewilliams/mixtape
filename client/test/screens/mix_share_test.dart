// Share and Stop sharing in the mix's ⋯ menus (spec 2026-11-13 shared-mixes
// → Sender; board frames S1–S6): the conversation's and the tape's menus,
// the name page when the server needs a name, the system share sheet, and
// the Stop sharing alert.

import 'package:flutter/cupertino.dart' show CupertinoAlertDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/name_page_store.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/data/share/share_sheet.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/name_page_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/first_run/name_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';
import 'package:mixtape/presentation/widgets/mix_share.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../helpers/fake_clipboard_writer.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart' show FakeLinkOpener;

const _url = 'https://miixtape.netlify.app/m/AbCdEfGhIjKlMnOpQrStUv';

DjSession _session({SessionKind kind = SessionKind.mix}) => DjSession(
  id: 's1',
  title: 'Late drive, windows down',
  status: 'active',
  queueVersion: 1,
  updatedAt: DateTime(2026, 11, 13),
  kind: kind,
);

QueueTrack _track(int position) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: 'apple-$position',
  title: 'Title $position',
  artist: 'Artist',
  durationMs: 180000,
);

class _Api implements DjApi, DjSharedMixes {
  _Api({this.shared = false, this.queue, this.kind = SessionKind.mix});

  final bool shared;
  final List<QueueTrack>? queue;
  final SessionKind kind;

  final shares = <String>[];
  final stops = <String>[];

  /// What each share answers, in order; the last one repeats.
  List<Object> shareAnswers = [
    const ShareLinkResult(token: 'AbCdEfGhIjKlMnOpQrStUv', url: _url),
  ];
  Object? stopError;

  @override
  Future<SessionDetail> getSession(String id) async => SessionDetail(
    session: _session(kind: kind),
    messages: const [],
    queue: queue ?? [_track(0), _track(1)],
    shared: shared,
  );

  @override
  Future<List<DjSession>> listSessions() async => [_session(kind: kind)];

  @override
  Future<void> postSessionEvent(String sessionId, String type) async {}

  @override
  Future<ShareLinkResult> shareSession(String sessionId) async {
    shares.add(sessionId);
    final answer = shareAnswers.length >= shares.length
        ? shareAnswers[shares.length - 1]
        : shareAnswers.last;
    if (answer is ShareLinkResult) return answer;
    throw answer;
  }

  @override
  Future<void> stopSharing(String sessionId) async {
    stops.add(sessionId);
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Sheet implements ShareSheet {
  final shared = <({String text, String url})>[];

  @override
  Future<void> share({
    required String text,
    required String url,
    Rect? origin,
  }) async => shared.add((text: text, url: url));
}

class _Account implements AccountApi {
  final names = <String?>[];
  bool fail = false;

  @override
  Future<void> updateUser({String? name}) async {
    names.add(name);
    if (fail) throw AccountApiException(500, '', null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

class _MusicKit implements MusicKitBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Harness {
  _Harness(this.api, {this.anonymous = false});

  final _Api api;
  final bool anonymous;
  final sheet = _Sheet();
  final account = _Account();

  late final ProviderContainer container = () {
    FlutterSecureStorage.setMockInitialValues({});
    final c = ProviderContainer(
      overrides: [
        djApiProvider.overrideWithValue(api),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        authProvider.overrideWith(_Auth.new),
        isAnonymousProvider.overrideWithValue(anonymous),
        shareSheetProvider.overrideWithValue(sheet),
        accountApiProvider.overrideWithValue(account),
        namePageStoreProvider.overrideWithValue(InMemoryNamePageStore()),
        meProvider.overrideWith(
          (ref) async => Me(id: 'u1', isAnonymous: anonymous),
        ),
        musicKitBridgeProvider.overrideWithValue(_MusicKit()),
        authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
        accountNameProvider.overrideWith((ref) async => null),
        mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
        musicPlatformStoreProvider.overrideWithValue(
          InMemoryMusicPlatformStore(),
        ),
        listeningApiProvider.overrideWithValue(FakeListeningApi()),
        servicePreferenceStoreProvider.overrideWithValue(
          InMemoryServicePreferenceStore(),
        ),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        linkOpenerProvider.overrideWithValue(FakeLinkOpener().call),
        linkProbeProvider.overrideWithValue((_) async => false),
        clipboardWriterProvider.overrideWithValue(FakeClipboardWriter()),
        playbackProvider.overrideWithValue(
          PlaybackController(playback.FakeApi(), playback.FakeBridge()),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: MixtapeTheme.light(), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// The two ⋯ menus Share lives in.
final _menus = <({String name, Widget screen, Key more})>[
  (
    name: 'conversation',
    screen: const ChatScreen(sessionId: 's1'),
    more: const Key('chat-actions'),
  ),
  (
    name: 'tape',
    screen: const QueueScreen(sessionId: 's1'),
    more: const Key('arrangement-more'),
  ),
];

Future<void> _openMenu(WidgetTester tester, Key more) async {
  await tester.tap(find.byKey(more));
  await tester.pumpAndSettle();
}

Finder get _share => find.text(MixShare.shareLabel);
Finder get _stop => find.text(MixShare.stopLabel);

void main() {
  for (final menu in _menus) {
    group('the ${menu.name} ⋯ menu', () {
      testWidgets('Share opens the share sheet with the link and the text', (
        tester,
      ) async {
        final h = _Harness(_Api());
        await h.pump(tester, menu.screen);
        await _openMenu(tester, menu.more);
        expect(_share, findsOneWidget);
        expect(_stop, findsNothing);

        await tester.tap(_share);
        await tester.pumpAndSettle();
        expect(h.api.shares, ['s1']);
        expect(h.sheet.shared, [
          (
            text: 'Listen to my mix “Late drive, windows down” on Mixtape',
            url: _url,
          ),
        ]);

        // Shared now: the menu offers Stop sharing under Share.
        await _openMenu(tester, menu.more);
        expect(_share, findsOneWidget);
        expect(_stop, findsOneWidget);
      });

      testWidgets('Stop sharing shows only while shared, confirms, and stops', (
        tester,
      ) async {
        final h = _Harness(_Api(shared: true));
        await h.pump(tester, menu.screen);
        await _openMenu(tester, menu.more);
        await tester.tap(_stop);
        await tester.pumpAndSettle();

        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.text('Stop sharing?'), findsOneWidget);
        expect(
          find.text("People with the link won't be able to open it."),
          findsOneWidget,
        );
        // Cancel leaves it shared.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(h.api.stops, isEmpty);

        await _openMenu(tester, menu.more);
        await tester.tap(_stop);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(CupertinoAlertDialog),
            matching: find.text(MixShare.stopLabel),
          ),
        );
        await tester.pumpAndSettle();
        expect(h.api.stops, ['s1']);

        await _openMenu(tester, menu.more);
        expect(_share, findsOneWidget);
        expect(_stop, findsNothing);
      });

      testWidgets('a failed share says so in the toast', (tester) async {
        final api = _Api()..shareAnswers = [ApiException(500, 'boom')];
        final h = _Harness(api);
        await h.pump(tester, menu.screen);
        await _openMenu(tester, menu.more);
        await tester.tap(_share);
        await tester.pumpAndSettle();
        expect(h.sheet.shared, isEmpty);
        expect(find.text(MixShare.shareFailed), findsOneWidget);
      });
    });
  }

  testWidgets('a mix with no songs has no Share', (tester) async {
    final h = _Harness(_Api(queue: const []));
    await h.pump(tester, const ChatScreen(sessionId: 's1'));
    await _openMenu(tester, const Key('chat-actions'));
    expect(find.text('Rename'), findsOneWidget);
    expect(_share, findsNothing);
  });

  testWidgets('an album session has no Share', (tester) async {
    final h = _Harness(_Api(kind: SessionKind.album, shared: true));
    await h.pump(tester, const ChatScreen(sessionId: 's1'));
    await _openMenu(tester, const Key('chat-actions'));
    expect(find.text('Rename'), findsOneWidget);
    expect(_share, findsNothing);
    expect(_stop, findsNothing);
  });

  for (final anonymous in [false, true]) {
    testWidgets(
      'name required (${anonymous ? 'anonymous' : 'account'}): the name page '
      'without Skip, then the share goes on',
      (tester) async {
        final api = _Api()
          ..shareAnswers = [
            const ShareNameRequiredException(),
            const ShareLinkResult(token: 'AbCdEfGhIjKlMnOpQrStUv', url: _url),
          ];
        final h = _Harness(api, anonymous: anonymous);
        await h.pump(tester, const ChatScreen(sessionId: 's1'));
        await _openMenu(tester, const Key('chat-actions'));
        await tester.tap(_share);
        await tester.pumpAndSettle();

        expect(find.byType(NameScreen), findsOneWidget);
        expect(find.text('What should we call you?'), findsOneWidget);
        expect(
          find.text('Whoever opens your link will see your first name.'),
          findsOneWidget,
        );
        expect(find.text('Skip'), findsNothing);
        expect(find.byKey(TapeBackButton.defaultKey), findsOneWidget);
        expect(h.sheet.shared, isEmpty);

        await tester.enterText(find.byKey(NameScreen.fieldKey), 'Ada Okafor');
        await tester.pump();
        await tester.tap(find.byKey(NameScreen.continueKey));
        await tester.pumpAndSettle();

        expect(h.account.names, ['Ada Okafor']);
        expect(find.byType(NameScreen), findsNothing);
        expect(api.shares, ['s1', 's1']);
        expect(h.sheet.shared.single.url, _url);
      },
    );
  }

  testWidgets('Back from the name page shares nothing', (tester) async {
    final api = _Api()..shareAnswers = [const ShareNameRequiredException()];
    final h = _Harness(api);
    await h.pump(tester, const ChatScreen(sessionId: 's1'));
    await _openMenu(tester, const Key('chat-actions'));
    await tester.tap(_share);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(TapeBackButton.defaultKey));
    await tester.pumpAndSettle();
    expect(find.byType(NameScreen), findsNothing);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(api.shares, ['s1']);
    expect(h.account.names, isEmpty);
    expect(h.sheet.shared, isEmpty);
  });

  testWidgets('a failed name save keeps the page with the text', (
    tester,
  ) async {
    final api = _Api()..shareAnswers = [const ShareNameRequiredException()];
    final h = _Harness(api)..account.fail = true;
    await h.pump(tester, const ChatScreen(sessionId: 's1'));
    await _openMenu(tester, const Key('chat-actions'));
    await tester.tap(_share);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(NameScreen.fieldKey), 'Ada');
    await tester.pump();
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pumpAndSettle();
    expect(find.byType(NameScreen), findsOneWidget);
    expect(find.text(NameScreen.failed), findsOneWidget);
    expect(api.shares, ['s1']);
  });

  testWidgets('the menu entries wear the transport glyphs', (tester) async {
    final h = _Harness(_Api(shared: true));
    await h.pump(tester, const ChatScreen(sessionId: 's1'));
    await _openMenu(tester, const Key('chat-actions'));
    final menu = find.byKey(mixtapeMenuKey);
    expect(
      find.descendant(of: menu, matching: find.byIcon(MixMenuIcons.share)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: menu,
        matching: find.byIcon(MixMenuIcons.stopSharing),
      ),
      findsOneWidget,
    );
  });
}
