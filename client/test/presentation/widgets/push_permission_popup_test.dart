// The Mix ready notifications ask (`docs/mockups/approved/2026-11-21-push-permission-modal.md`,
// board r3): the centred pop-up and its content, the once rule, the
// triggers, the OS-decided skips, never stacked on another ask, and You's
// row in its three states.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/push/push_ask_store.dart';
import 'package:mixtape/data/push/push_service.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/ai_consent_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';
import 'package:mixtape/presentation/screens/tabs/you_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_switch.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_popup.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import 'package:mixtape/presentation/widgets/ai_consent_sheet.dart';
import 'package:mixtape/presentation/widgets/push_permission_popup.dart';

import '../../helpers/fake_ai_consent.dart';
import '../../helpers/fake_listening_api.dart';
import '../../helpers/fake_push_channel.dart';
import '../../helpers/onboarding_harness.dart' show FakeLinkOpener;

class _Auth extends AuthNotifier {
  _Auth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

/// Reduced motion while [on].
void _reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

class _Harness {
  _Harness({
    PushStatus status = PushStatus.notDetermined,
    bool asked = false,
    bool optedOut = false,
    this.auth = AuthStatus.noSession,
  }) : channel = FakePushChannel(current: status),
       store = InMemoryPushAskStore(asked: asked, optedOut: optedOut);

  final FakePushChannel channel;
  final InMemoryPushAskStore store;
  final AuthStatus auth;
  final links = FakeLinkOpener();
  final List<String> requests = [];

  late final ProviderContainer container = () {
    final tokens = InMemoryTokenStore();
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => _Auth(auth)),
        tokenStoreProvider.overrideWithValue(tokens),
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: 'https://api.test',
            tokenStore: tokens,
            inner: MockClient((request) async {
              requests.add('${request.method} ${request.url.path}');
              return http.Response('', 204);
            }),
          ),
        ),
        pushChannelProvider.overrideWithValue(channel),
        pushAskStoreProvider.overrideWithValue(store),
        listeningApiProvider.overrideWithValue(FakeListeningApi()),
        musicPlatformStoreProvider.overrideWithValue(
          InMemoryMusicPlatformStore(MusicPlatform.apple),
        ),
        linkOpenerProvider.overrideWithValue(links.call),
        accountApiProvider.overrideWithValue(
          FakeConsentAccountApi(aiConsent: true),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pump();
  }
}

/// A screen with a button that opens the bare pop-up.
class _Opener extends StatelessWidget {
  const _Opener({required this.onAllow, required this.onResult});

  final Future<PushStatus> Function() onAllow;
  final void Function(PushStatus?) onResult;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async =>
            onResult(await showPushPermissionPopup(context, onAllow: onAllow)),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  group('the pop-up', () {
    Future<List<PushStatus?>> open(
      WidgetTester tester,
      _Harness h, {
      Brightness brightness = Brightness.light,
      double textScale = 1,
      Future<PushStatus> Function()? onAllow,
    }) async {
      final results = <PushStatus?>[];
      await h.pump(
        tester,
        _Opener(
          onAllow: onAllow ?? () async => PushStatus.authorized,
          onResult: results.add,
        ),
        brightness: brightness,
        textScale: textScale,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      return results;
    }

    testWidgets('a centred card 22 pt in, with the art, the title, the body, '
        'the 50 pt pill and Not now, every line centred', (tester) async {
      _phone(tester);
      final h = _Harness();
      await open(tester, h);

      final card = tester.getRect(find.byKey(MixtapePopup.surfaceKey));
      expect(card.left, 22);
      expect(card.right, 390 - 22);
      expect(card.center.dy, moreOrLessEquals(844 / 2, epsilon: 1));
      final decoration =
          tester
                  .widget<DecoratedBox>(find.byKey(MixtapePopup.surfaceKey))
                  .decoration
              as BoxDecoration;
      expect(decoration.color, const Color(0xFFFBFAF8));
      expect(decoration.borderRadius, BorderRadius.circular(30));

      expect(find.text(PushAskCopy.title), findsOneWidget);
      expect(find.text(PushAskCopy.body), findsOneWidget);
      expect(find.text(PushAskCopy.allowLabel), findsOneWidget);
      expect(find.text(PushAskCopy.notNowLabel), findsOneWidget);
      expect(find.byKey(PushAskCopy.pingKey), findsOneWidget);

      for (final key in [PushAskCopy.titleKey, PushAskCopy.bodyKey]) {
        final text = tester.widget<Text>(find.byKey(key));
        expect(text.textAlign, TextAlign.center);
        expect(
          tester.getCenter(find.byKey(key)).dx,
          moreOrLessEquals(195, epsilon: 0.5),
        );
      }
      final title = tester.widget<Text>(find.byKey(PushAskCopy.titleKey));
      expect(title.style?.fontSize, closeTo(18, 0.2));
      expect(title.style?.fontWeight, FontWeight.w700);
      final body = tester.widget<Text>(find.byKey(PushAskCopy.bodyKey));
      expect(body.style?.fontSize, closeTo(13.5, 0.1));
      expect(body.style?.color, MixtapeTokens.light.smoke);

      // 50 pt tall (the test font is wider than SF, so its label may wrap
      // here; the pill's own minimum is what the board sets).
      final pill = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(PushAskCopy.allowKey),
          matching: find.byType(TextButton),
        ),
      );
      expect(pill.style?.minimumSize?.resolve({})?.height, 50);
      expect(
        tester.getSize(find.byKey(PushAskCopy.allowKey)).width,
        390 - 44 - 44,
      );
      expect(
        tester.getSize(find.byKey(PushAskCopy.notNowKey)).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getCenter(find.byKey(PushAskCopy.notNowKey)).dx,
        moreOrLessEquals(195, epsilon: 0.5),
      );
      // About 18 pt between the art and the title.
      expect(
        tester.getTopLeft(find.byKey(PushAskCopy.titleKey)).dy -
            tester.getBottomLeft(find.byKey(PushAskCopy.artKey)).dy,
        18,
      );
      // The cassette at 108 pt.
      expect(tester.getSize(find.byKey(PushAskCopy.cassetteKey)).width, 108);
    });

    testWidgets('dark: the dark sheet surface', (tester) async {
      _phone(tester);
      await open(tester, _Harness(), brightness: Brightness.dark);
      final decoration =
          tester
                  .widget<DecoratedBox>(find.byKey(MixtapePopup.surfaceKey))
                  .decoration
              as BoxDecoration;
      expect(decoration.color, const Color(0xFF1C1A22));
    });

    testWidgets('the art moves: the hubs turn and the notification rises', (
      tester,
    ) async {
      _phone(tester);
      await open(tester, _Harness());
      final cassette = tester.state<CassetteTileState>(
        find.byKey(PushAskCopy.cassetteKey),
      );
      expect(cassette.isSpinning, isTrue);
      final opacity = find.ancestor(
        of: find.byKey(PushAskCopy.pingKey),
        matching: find.byType(Opacity),
      );
      final early = tester.widget<Opacity>(opacity.first).opacity;
      await tester.pump(const Duration(milliseconds: 1000));
      final later = tester.widget<Opacity>(opacity.first).opacity;
      expect(early, lessThan(later));
    });

    testWidgets('reduced motion: the hubs stand still and the notification '
        'sits still above the tape', (tester) async {
      _phone(tester);
      _reduceMotion(tester);
      await open(tester, _Harness());
      await tester.pumpAndSettle();
      final cassette = tester.state<CassetteTileState>(
        find.byKey(PushAskCopy.cassetteKey),
      );
      expect(cassette.isSpinning, isFalse);
      final opacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(PushAskCopy.pingKey),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, 1);
      // Settled: nothing is ticking.
      expect(tester.binding.hasScheduledFrame, isFalse);
      // The card comes in with a fade only.
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.byKey(MixtapePopup.surfaceKey),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(scale.scale.value, 1);
    });

    testWidgets('200 % text: the cassette alone at about 80 pt, the words '
        'scroll inside, the buttons stay on screen', (tester) async {
      _phone(tester);
      await open(tester, _Harness(), textScale: 2);
      expect(find.byKey(PushAskCopy.pingKey), findsNothing);
      expect(
        tester.getSize(find.byKey(PushAskCopy.cassetteKey)).width,
        closeTo(80, 3),
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(PushAskCopy.scrollKey),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      // The card stays inside the screen, and both buttons are on it.
      final card = tester.getRect(find.byKey(MixtapePopup.surfaceKey));
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(844));
      for (final key in [PushAskCopy.allowKey, PushAskCopy.notNowKey]) {
        final rect = tester.getRect(find.byKey(key));
        expect(rect.bottom, lessThanOrEqualTo(card.bottom));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Turn on notifications asks, then closes with the answer', (
      tester,
    ) async {
      _phone(tester);
      var asked = 0;
      final results = await open(
        tester,
        _Harness(),
        onAllow: () async {
          asked++;
          return PushStatus.authorized;
        },
      );
      await tester.tap(find.byKey(PushAskCopy.allowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(asked, 1);
      expect(results, [PushStatus.authorized]);
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
    });

    testWidgets('Not now and a tap on the overlay close it with no answer', (
      tester,
    ) async {
      _phone(tester);
      var asked = 0;
      final h = _Harness();
      final results = await open(
        tester,
        h,
        onAllow: () async {
          asked++;
          return PushStatus.authorized;
        },
      );
      await tester.tap(find.byKey(PushAskCopy.notNowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(results, [null]);
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tapAt(const Offset(195, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(results, [null, null]);
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(asked, 0);
    });

    testWidgets('VoiceOver: the title as a heading, the body, two buttons; '
        'the art is hidden', (tester) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      await open(tester, _Harness());
      expect(
        tester.getSemantics(find.byKey(PushAskCopy.titleKey)),
        matchesSemantics(label: PushAskCopy.title, isHeader: true),
      );
      expect(find.bySemanticsLabel(PushAskCopy.body), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(PushAskCopy.allowKey)),
        containsSemantics(
          label: PushAskCopy.allowLabel,
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(PushAskCopy.notNowKey)),
        containsSemantics(
          label: PushAskCopy.notNowLabel,
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(find.bySemanticsLabel(PushAskCopy.pingTitle), findsNothing);
      expect(find.bySemanticsLabel(PushAskCopy.pingMix), findsNothing);
      semantics.dispose();
    });
  });

  group('the once rule and the triggers', () {
    Widget screen({bool working = false, bool onArrival = false}) =>
        PushAskTrigger(
          working: working,
          onArrival: onArrival,
          child: const Scaffold(body: Center(child: Text('screen'))),
        );

    testWidgets('about 3 s into a working state it shows once, sets the flag '
        'as it appears, and Allow registers this phone', (tester) async {
      _phone(tester);
      final h = _Harness(auth: AuthStatus.session);
      // `/me` has answered (the shell reads it from launch), so the
      // consent question is settled.
      await h.container.read(meProvider.future);
      await h.pump(tester, screen(working: true));
      await tester.pump(const Duration(milliseconds: 2900));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
      expect(h.store.marks, 1);
      expect(await h.store.asked(), isTrue);

      await tester.tap(find.byKey(PushAskCopy.allowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(h.channel.calls, contains('requestAuthorization'));
      expect(h.channel.calls, contains('register'));
      expect(h.requests, contains('PUT /push/devices'));
    });

    testWidgets('a working state that ends before 3 s asks nothing', (
      tester,
    ) async {
      _phone(tester);
      final h = _Harness();
      await h.pump(tester, screen(working: true));
      await tester.pump(const Duration(seconds: 1));
      await h.pump(tester, screen());
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(h.store.marks, 0);
    });

    testWidgets('after Not now it never shows again: not on the next working '
        'state, not on a new launch', (tester) async {
      _phone(tester);
      final h = _Harness();
      await h.pump(tester, screen(working: true));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(PushAskCopy.notNowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);

      // Another turn, same launch.
      await h.pump(tester, screen());
      await h.pump(tester, screen(working: true));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);

      // A new launch: only the device flag remembers.
      final next = _Harness(asked: await h.store.asked());
      await next.pump(tester, screen(onArrival: true));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(h.channel.calls, isNot(contains('requestAuthorization')));
    });

    testWidgets('on arrival (Home after sign-up, or an existing listener) '
        'once it has settled', (tester) async {
      _phone(tester);
      final h = _Harness();
      await h.pump(tester, screen(onArrival: true));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
      expect(h.store.marks, 1);
    });

    testWidgets('on arrival with a turn out it leaves the ask to that '
        "turn's working state", (tester) async {
      _phone(tester);
      final h = _Harness();
      h.container.read(mixActivityProvider.notifier).beginTurn('a');
      await h.pump(tester, screen(onArrival: true));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);

      // A mix started on Home: never over its first seconds.
      await h.pump(tester, screen(onArrival: true, working: true));
      await tester.pump(const Duration(milliseconds: 2500));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
    });

    for (final status in [PushStatus.authorized, PushStatus.denied]) {
      testWidgets('skipped when iOS already says ${status.name}', (
        tester,
      ) async {
        _phone(tester);
        final h = _Harness(status: status);
        await h.pump(tester, screen(working: true, onArrival: true));
        await tester.pump(const Duration(seconds: 6));
        expect(find.byKey(PushAskCopy.popupKey), findsNothing);
        expect(h.store.marks, 0);
        expect(h.channel.calls, isNot(contains('requestAuthorization')));
      });
    }

    testWidgets('never stacked on the AI-consent sheet: it waits until the '
        'sheet is down', (tester) async {
      _phone(tester);
      final h = _Harness();
      await h.pump(tester, screen(working: true));
      // The consent sheet goes up (any of its places counts it open).
      unawaited(showAiConsentSheet(tester.element(find.text('screen'))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(AiConsentCopy.title), findsOneWidget);
      expect(h.container.read(openAsksProvider), 1);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(h.store.marks, 0);

      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.container.read(openAsksProvider), 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
      // And it counts itself up while it is showing, so nothing stacks on
      // it either.
      expect(h.container.read(openAsksProvider), 1);
    });

    testWidgets('it waits while a route covers its screen', (tester) async {
      _phone(tester);
      final h = _Harness();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            navigatorKey: navigator,
            theme: MixtapeTheme.light(),
            home: screen(working: true),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      navigator.currentState!.pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
    });
  });

  group('You → Mix ready notifications', () {
    Widget row() => const Scaffold(
      body: SingleChildScrollView(child: InsetGroup(children: [MixReadyRow()])),
    );

    GlassSwitch toggle(WidgetTester tester) =>
        tester.widget<GlassSwitch>(find.byKey(MixReadyRow.switchKey));

    testWidgets('on: the switch on and "A ping when a mix lands"; off '
        'unregisters this phone and is remembered', (tester) async {
      _phone(tester);
      final h = _Harness(
        status: PushStatus.authorized,
        auth: AuthStatus.session,
      );
      await h.pump(tester, row());
      await tester.pump();
      expect(find.text(MixReadyRow.title), findsOneWidget);
      expect(find.text(MixReadyRow.onLine), findsOneWidget);
      expect(toggle(tester).value, isTrue);

      await tester.tap(find.byKey(MixReadyRow.switchKey));
      await tester.pump();
      await tester.pump();
      expect(toggle(tester).value, isFalse);
      expect(await h.store.optedOut(), isTrue);
      expect(
        h.requests.where((r) => r.startsWith('DELETE /push/devices/')),
        hasLength(1),
      );
      expect(h.channel.calls, isNot(contains('requestAuthorization')));
    });

    testWidgets('off after Not now: the switch off; on brings up the system '
        'prompt and registers', (tester) async {
      _phone(tester);
      final h = _Harness(auth: AuthStatus.session);
      await h.pump(tester, row());
      await tester.pump();
      expect(find.text(MixReadyRow.onLine), findsOneWidget);
      expect(toggle(tester).value, isFalse);

      await tester.tap(find.byKey(MixReadyRow.switchKey));
      await tester.pump();
      await tester.pump();
      expect(h.channel.calls, contains('requestAuthorization'));
      expect(toggle(tester).value, isTrue);
      expect(h.requests, contains('PUT /push/devices'));
    });

    testWidgets('turned off here: off at the next launch too, and the launch '
        'does not register', (tester) async {
      _phone(tester);
      final h = _Harness(
        status: PushStatus.authorized,
        optedOut: true,
        auth: AuthStatus.session,
      );
      h.container.listen(pushServiceProvider, (_, _) {});
      await h.pump(tester, row());
      await tester.pump();
      expect(toggle(tester).value, isFalse);
      expect(h.channel.calls, isNot(contains('register')));
      expect(h.requests, isEmpty);
    });

    testWidgets('denied: "Off in iOS Settings", no switch, and Settings opens '
        "Mixtape's page there", (tester) async {
      _phone(tester);
      final h = _Harness(status: PushStatus.denied, auth: AuthStatus.session);
      await h.pump(tester, row());
      await tester.pump();
      expect(find.text(MixReadyRow.deniedLine), findsOneWidget);
      expect(find.byKey(MixReadyRow.switchKey), findsNothing);
      await tester.tap(find.byKey(MixReadyRow.settingsKey));
      await tester.pump();
      expect(h.links.opened, [Uri.parse('app-settings:')]);
    });

    testWidgets('hidden where nothing can receive a push', (tester) async {
      expect(
        ProviderContainer(
          overrides: [
            pushChannelProvider.overrideWithValue(const NoPushChannel()),
          ],
        ).read(pushAvailableProvider),
        isFalse,
      );
    });
  });

  test('the sheet tokens the pop-up paints with', () {
    expect(MixtapeTokens.light.sheetSurface, const Color(0xFFFBFAF8));
    expect(MixtapeTokens.dark.sheetSurface, const Color(0xFF1C1A22));
    expect(MixtapeSheet.topRadius, 20);
    expect(MixtapePopup.radius, 30);
    expect(MixtapePopup.blurSigma, 16);
  });
}
