// The AI-consent sheet (plan `2026-11-02-ai-consent-and-privacy.md` → Copy):
// the exact copy, the Privacy policy link, Agree recording consent, a failed
// grant staying open with one line, and Not now.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/ai_consent_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/ai_consent_sheet.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';

import '../../helpers/fake_ai_consent.dart';
import '../../helpers/onboarding_harness.dart' show FakeLinkOpener;

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

class _Harness {
  final api = FakeConsentAccountApi();
  final links = FakeLinkOpener();
  late final container = () {
    final c = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        authProvider.overrideWith(_Auth.new),
        accountApiProvider.overrideWithValue(api),
        linkOpenerProvider.overrideWithValue(links.call),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  bool? result;

  Future<void> pump(WidgetTester tester, {Brightness? brightness}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? MixtapeTheme.dark()
              : MixtapeTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await confirmAiConsent(context);
                },
                child: const Text('send'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('shows the exact copy in the standard sheet', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(find.byKey(MixtapeSheet.surfaceKey), findsOneWidget);
    expect(find.text('Before your first mix'), findsOneWidget);
    expect(
      find.text(
        'Mixtape’s DJ runs on Anthropic’s Claude. To make your mixes we send '
        'it what you type or say, and the music and listening history you '
        'add. Voice clips are transcribed by Groq. Your data is not sold or '
        'used for ads.',
      ),
      findsOneWidget,
    );
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Agree and continue'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('Privacy policy opens the policy outside the app', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(AiConsentCopy.privacyKey));
    await tester.pump();
    expect(h.links.opened, [
      Uri.parse('https://miixtape.netlify.app/privacy/'),
    ]);
    // The sheet stays up.
    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
  });

  testWidgets('Agree records consent, closes and lets the send go on', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();
    expect(h.api.grants, 1);
    expect(h.result, isTrue);
    expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
    expect(h.container.read(aiConsentProvider).granted, isTrue);
  });

  testWidgets('a failed grant stays open with one line and does not go on', (
    tester,
  ) async {
    final h = _Harness();
    h.api.failGrantWith = NetworkException('offline');
    await h.pump(tester);
    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t save that. Try again.'), findsOneWidget);
    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    expect(h.result, isNull);

    // A retry that works clears the line and goes on.
    h.api.failGrantWith = null;
    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();
    expect(h.result, isTrue);
  });

  testWidgets('Agree is disabled while the grant is in flight', (tester) async {
    final h = _Harness();
    h.api.grantGate = Completer<void>();
    await h.pump(tester);
    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pump();
    await tester.tap(find.byKey(AiConsentCopy.agreeKey), warnIfMissed: false);
    await tester.pump();
    h.api.grantGate!.complete();
    await tester.pumpAndSettle();
    expect(h.api.grants, 1);
    expect(h.result, isTrue);
  });

  testWidgets('Not now closes without recording or going on', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(AiConsentCopy.notNowKey));
    await tester.pumpAndSettle();
    expect(h.result, isFalse);
    expect(h.api.grants, 0);
    expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
  });

  testWidgets('no sheet when /me says consent is already given', (
    tester,
  ) async {
    final h = _Harness();
    h.api.aiConsent = true;
    await h.pump(tester);
    expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
    expect(h.result, isTrue);
  });

  testWidgets('fits a phone at 200% text in dark mode', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = _Harness();
    await h.pump(tester, brightness: Brightness.dark);
    expect(tester.takeException(), isNull);
    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
  });

  group('AiConsentPrompt (the one-time sheet over the app)', () {
    Future<_Harness> pumpPrompt(
      WidgetTester tester, {
      bool aiConsent = false,
      bool anonymous = false,
    }) async {
      final h = _Harness();
      h.api
        ..aiConsent = aiConsent
        ..anonymous = anonymous;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: AiConsentPrompt(
              child: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      h.result = await confirmAiConsent(context);
                    },
                    child: const Text('send'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('shows once /me says not yet', (tester) async {
      await pumpPrompt(tester);
      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    });

    testWidgets('an anonymous listener is asked too', (tester) async {
      await pumpPrompt(tester, anonymous: true);
      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    });

    testWidgets('nothing when /me says granted (or has no field)', (
      tester,
    ) async {
      await pumpPrompt(tester, aiConsent: true);
      expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
    });

    testWidgets('Not now puts it away for the launch; a send asks again', (
      tester,
    ) async {
      final h = await pumpPrompt(tester);
      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
      expect(h.container.read(aiConsentProvider).dismissed, isTrue);

      // It does not come back on its own.
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(AiConsentCopy.titleKey), findsNothing);

      // A send re-shows it instead of sending.
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pumpAndSettle();
      expect(h.result, isFalse);
    });

    testWidgets('Agree records it and the sheet does not return', (
      tester,
    ) async {
      final h = await pumpPrompt(tester);
      await tester.tap(find.byKey(AiConsentCopy.agreeKey));
      await tester.pumpAndSettle();
      expect(h.api.grants, 1);
      expect(find.byKey(AiConsentCopy.titleKey), findsNothing);

      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
      expect(h.result, isTrue);
    });
  });
}
