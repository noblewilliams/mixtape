// Everyone gets a mix, Task 8: with the server's never-refuse flag on,
// "Skip for now" on Step 1 of 3 goes to the prompt page, whose send makes
// the mix without artists.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/config/config_api.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/making_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';

import 'first_run_harness.dart';

Future<void> _skipFromWelcome(WidgetTester tester, FirstRunHarness h) async {
  await h.pump(tester, const WelcomeScreen());
  await tester.tap(find.byKey(WelcomeScreen.addMusicKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ChooseServiceScreen.skipKey));
  await tester.pumpAndSettle();
}

/// The prompt page in its after-sync form: no add-music pill, no count line.
void _expectPromptPage() {
  expect(find.byType(ArtistsScreen), findsNothing);
  expect(find.byType(WelcomeScreen), findsOneWidget);
  expect(find.text(WelcomeScreen.headline), findsOneWidget);
  expect(find.byKey(WelcomeScreen.addMusicKey), findsNothing);
  expect(find.byKey(WelcomeScreen.countLineKey), findsNothing);
}

void main() {
  reduceMotion();

  group('never refuse on', () {
    testWidgets('Skip for now goes to the prompt page', (tester) async {
      final h = FirstRunHarness();
      h.config.answer = const FirstRunFlags(neverRefuse: true);
      await _skipFromWelcome(tester, h);

      _expectPromptPage();
      expect(
        tester.widget<WelcomeScreen>(find.byType(WelcomeScreen)).isPrompt,
        isTrue,
      );
    });

    testWidgets('the prompt page send makes the mix with no seeds saved', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.config.answer = const FirstRunFlags(neverRefuse: true);
      h.container.read(firstRunActiveProvider);
      await _skipFromWelcome(tester, h);

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'afrobeats for a long drive',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistsScreen), findsNothing);
      expect(find.byType(MakingScreen), findsNothing);
      expect(h.listening.putSeeds, isEmpty);
      expect(h.dj.prompts, ['afrobeats for a long drive']);
      expect(h.auth.anonymousSignIns, 1);
      expect(
        h.container.read(pendingConversationProvider)?.sessionId,
        'session-new',
      );
    });

    testWidgets('the config is read once per flow, before any anonymous '
        'sign-in', (tester) async {
      final h = FirstRunHarness();
      h.config.answer = const FirstRunFlags(neverRefuse: true);
      await _skipFromWelcome(tester, h);
      // Back to Step 1 and skip again: no second read.
      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChooseServiceScreen.skipKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(h.config.calls, 1);
      expect(h.config.signInsAtRead, [0]);
      expect(h.auth.anonymousSignIns, 1);
    });

    testWidgets('Who do you love? stays reachable from Welcome', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.config.answer = const FirstRunFlags(neverRefuse: true);
      await h.pump(tester, const WelcomeScreen());
      await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<ArtistsScreen>(find.byType(ArtistsScreen)).prompt,
        'late',
      );
    });
  });

  group('never refuse off or unknown: Skip goes to Who do you love?', () {
    for (final (name, configure) in <(String, void Function(FakeConfigApi))>[
      ('flag false', (c) => c.answer = FirstRunFlags.off),
      ('fetch fails', (c) => c.failWith = NetworkException('offline')),
      ('route 404s', (c) => c.failWith = ApiException(404, 'Not Found')),
    ]) {
      testWidgets(name, (tester) async {
        final h = FirstRunHarness();
        configure(h.config);
        await _skipFromWelcome(tester, h);

        expect(find.byType(ArtistsScreen), findsOneWidget);
        expect(
          tester.widget<ArtistsScreen>(find.byType(ArtistsScreen)).prompt,
          isNull,
        );
      });
    }
  });
}
