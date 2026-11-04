// AI consent on the first run (plan `2026-11-02-ai-consent-and-privacy.md`
// → Where it shows): after Welcome, before the first prompt is sent. Agree
// records consent and the mix goes on; Not now stays on the page unsent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/widgets/ai_consent_sheet.dart';

import 'first_run_harness.dart';

Future<void> _send(WidgetTester tester, String prompt) async {
  await tester.enterText(find.byKey(const Key('prompt-field')), prompt);
  await tester.pump();
  await tester.tap(find.byKey(const Key('start-session')));
  await tester.pumpAndSettle();
}

void main() {
  reduceMotion();

  testWidgets('the prompt page asks before the first prompt is sent', (
    tester,
  ) async {
    final h = FirstRunHarness(consentGiven: false);
    h.container.read(firstRunActiveProvider.notifier);
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));

    await _send(tester, 'late');

    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    expect(h.dj.prompts, isEmpty);
    // Nothing is created until the listener agrees.
    expect(h.auth.anonymousSignIns, 0);
  });

  testWidgets('Agree creates the listener, records consent, then sends', (
    tester,
  ) async {
    final h = FirstRunHarness(consentGiven: false);
    h.container.read(firstRunActiveProvider.notifier);
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));
    await _send(tester, 'late');

    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();

    expect(h.auth.anonymousSignIns, 1);
    expect(h.account.grants, 1);
    expect(h.dj.prompts, ['late']);
    expect(
      h.container.read(pendingConversationProvider)?.sessionId,
      'session-new',
    );
  });

  testWidgets('Not now stays on the page with the prompt, unsent', (
    tester,
  ) async {
    final h = FirstRunHarness(consentGiven: false);
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));
    await _send(tester, 'late');

    await tester.tap(find.byKey(AiConsentCopy.notNowKey));
    await tester.pumpAndSettle();

    expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('late'), findsOneWidget);
    expect(find.byKey(WelcomeScreen.errorKey), findsNothing);
    expect(h.dj.prompts, isEmpty);
    expect(h.account.grants, 0);

    // A second send asks again.
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
  });

  testWidgets('a failed grant says so and sends nothing', (tester) async {
    final h = FirstRunHarness(consentGiven: false);
    h.account.failGrantWith = NetworkException('offline');
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));
    await _send(tester, 'late');

    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(AiConsentCopy.errorKey), findsOneWidget);
    expect(h.dj.prompts, isEmpty);
  });

  testWidgets('Who do you love? asks after the seeds, before the mix', (
    tester,
  ) async {
    final h = FirstRunHarness(consentGiven: false);
    await h.pump(tester, const ArtistsScreen(prompt: 'late'));
    for (var i = 0; i < ArtistsScreen.slots; i++) {
      await tester.enterText(find.byKey(ArtistsScreen.fieldKey(i)), 'A$i');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    expect(h.dj.prompts, isEmpty);

    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();
    expect(h.dj.prompts, ['late']);
  });

  testWidgets('an existing session that already agreed is not asked', (
    tester,
  ) async {
    final h = FirstRunHarness(
      status: AuthStatus.session,
      anonymous: true,
      consentGiven: false,
    );
    h.account.aiConsent = true;
    h.container.read(firstRunActiveProvider.notifier);
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));
    await _send(tester, 'late');

    expect(find.byKey(AiConsentCopy.titleKey), findsNothing);
    expect(h.dj.prompts, ['late']);
  });

  testWidgets('a 403 ai_consent_required asks again and resends on Agree', (
    tester,
  ) async {
    final h = FirstRunHarness(
      status: AuthStatus.session,
      anonymous: true,
      consentGiven: false,
    );
    h.account.aiConsent = true; // e.g. a /me read that failed open
    h.dj.failWith = const AiConsentRequiredException();
    h.container.read(firstRunActiveProvider.notifier);
    await h.pump(tester, const WelcomeScreen.prompt(songsIn: 12));
    await _send(tester, 'late');

    expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
    expect(find.byKey(WelcomeScreen.errorKey), findsNothing);
    expect(h.dj.prompts, ['late']);

    h.dj.failWith = null;
    await tester.tap(find.byKey(AiConsentCopy.agreeKey));
    await tester.pumpAndSettle();
    expect(h.account.grants, 1);
    expect(h.dj.prompts, ['late', 'late']);
    expect(
      h.container.read(pendingConversationProvider)?.sessionId,
      'session-new',
    );
  });
}
