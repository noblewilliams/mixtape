// Who do you love? (board frames A3, A4).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';

import 'first_run_harness.dart';

Future<void> _enter(WidgetTester tester, int i, String name) async {
  await tester.enterText(find.byKey(ArtistsScreen.fieldKey(i)), name);
  await tester.testTextInput.receiveAction(
    i == 2 ? TextInputAction.done : TextInputAction.next,
  );
  await tester.pumpAndSettle();
}

/// A stand-in for Welcome, so the screen sits above a route and back pops.
Widget _above(Widget page) => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('open'),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => page)),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  reduceMotion();

  testWidgets('copy, the optional label, three fields, a dimmed Continue '
      'and Skip for now, with no counter', (tester) async {
    final h = FirstRunHarness();
    final semantics = tester.ensureSemantics();
    await h.pump(tester, const ArtistsScreen(prompt: 'late'));

    expect(find.text('Who do you love?'), findsOneWidget);
    expect(
      find.text(
        'Name a few and the DJ tailors your mix to them. Optional: skip and '
        'it works from what you asked for.',
      ),
      findsOneWidget,
    );
    expect(find.text('ARTISTS YOU LOVE (OPTIONAL)'), findsOneWidget);
    for (final hint in ['Type an artist', 'Another artist', 'One more']) {
      expect(find.text(hint), findsOneWidget);
    }
    expect(find.byKey(ArtistsScreen.skipKey), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(enabled(tester, ArtistsScreen.continueKey), isFalse);
    expect(
      tester.getSemantics(find.byKey(ArtistsScreen.continueKey)),
      matchesSemantics(
        label: 'Continue',
        hint: 'Add an artist, or skip for now.',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    expect(find.byKey(StepScaffold.counterKey), findsNothing);
    expect(find.byKey(StepScaffold.progressKey), findsNothing);
    semantics.dispose();
  });

  testWidgets('Continue enables at one artist, which becomes a chip; '
      'removing it dims Continue again', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const ArtistsScreen(prompt: 'late'));

    expect(enabled(tester, ArtistsScreen.continueKey), isFalse);
    await _enter(tester, 0, 'Burna Boy');
    expect(find.byKey(ArtistsScreen.chipKey(0)), findsOneWidget);
    expect(enabled(tester, ArtistsScreen.continueKey), isTrue);

    await tester.tap(find.byKey(ArtistsScreen.removeKey(0)));
    await tester.pumpAndSettle();
    expect(find.byKey(ArtistsScreen.chipKey(0)), findsNothing);
    expect(find.byKey(ArtistsScreen.fieldKey(0)), findsOneWidget);
    expect(enabled(tester, ArtistsScreen.continueKey), isFalse);
  });

  testWidgets('Continue with one artist saves just that one', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const ArtistsScreen(prompt: 'rainy commute'));

    await _enter(tester, 1, 'Sade');
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(h.listening.putSeeds, [
      ['Sade'],
    ]);
    expect(h.dj.prompts, ['rainy commute']);
  });

  testWidgets('Skip for now saves no seeds and makes the mix from the '
      'prompt alone', (tester) async {
    final h = FirstRunHarness();
    h.container.read(firstRunActiveProvider);
    await h.pump(tester, const ArtistsScreen(prompt: 'rainy commute'));

    await tester.tap(find.byKey(ArtistsScreen.skipKey));
    await tester.pumpAndSettle();

    expect(h.listening.putSeeds, isEmpty);
    expect(h.auth.anonymousSignIns, 1);
    expect(h.dj.prompts, ['rainy commute']);
    expect(h.container.read(firstRunActiveProvider), isFalse);
  });

  testWidgets('Skip for now without a prompt goes on to the prompt page, '
      'whose send starts the mix', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const ArtistsScreen());

    await tester.tap(find.byKey(ArtistsScreen.skipKey));
    await tester.pumpAndSettle();

    final prompt = tester.widget<WelcomeScreen>(find.byType(WelcomeScreen));
    expect(prompt.artistsPassed, isTrue);
    await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    expect(h.listening.putSeeds, isEmpty);
    expect(h.dj.prompts, ['late']);
  });

  testWidgets('Continue signs in anonymously once, saves the seeds, starts '
      'the mix with the prompt and hands off with its id', (tester) async {
    final h = FirstRunHarness();
    h.container.read(firstRunActiveProvider);
    await h.pump(tester, const ArtistsScreen(prompt: 'rainy commute'));

    await _enter(tester, 0, 'Burna Boy');
    await _enter(tester, 1, 'Tems');
    await _enter(tester, 2, 'Sade');
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(h.auth.anonymousSignIns, 1);
    expect(h.container.read(authProvider), AuthStatus.session);
    expect(h.listening.putSeeds, [
      ['Burna Boy', 'Tems', 'Sade'],
    ]);
    expect(h.dj.prompts, ['rainy commute']);
    expect(h.container.read(firstRunActiveProvider), isFalse);
    expect(
      h.container.read(pendingConversationProvider)?.sessionId,
      'session-new',
    );
  });

  testWidgets('the seeds are saved before the prompt is sent', (tester) async {
    final h = FirstRunHarness();
    final saving = Completer<List<ArtistSeed>>();
    h.listening.onPutArtistSeeds = (_) => saving.future;
    await h.pump(tester, const ArtistsScreen(prompt: 'late'));

    await _enter(tester, 0, 'A');
    await _enter(tester, 1, 'B');
    await _enter(tester, 2, 'C');
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pump();
    expect(h.dj.prompts, isEmpty);
    expect(enabled(tester, ArtistsScreen.continueKey), isFalse);

    saving.complete(const []);
    await tester.pumpAndSettle();
    expect(h.dj.prompts, ['late']);
  });

  testWidgets('a failed save says so and sends nothing', (tester) async {
    final h = FirstRunHarness();
    h.listening.onPutArtistSeeds = (_) async => throw Exception('down');
    await h.pump(tester, const ArtistsScreen(prompt: 'late'));

    await _enter(tester, 0, 'A');
    await _enter(tester, 1, 'B');
    await _enter(tester, 2, 'C');
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(
      find.text("Couldn't save those artists. Try again."),
      findsOneWidget,
    );
    expect(h.dj.prompts, isEmpty);
    expect(enabled(tester, ArtistsScreen.continueKey), isTrue);
  });

  testWidgets('without a prompt Continue goes on to the prompt page, whose '
      'send starts the mix', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const ArtistsScreen());

    await _enter(tester, 0, 'A');
    await _enter(tester, 1, 'B');
    await _enter(tester, 2, 'C');
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    final prompt = tester.widget<WelcomeScreen>(find.byType(WelcomeScreen));
    expect(prompt.isPrompt, isTrue);
    expect(prompt.artistsPassed, isTrue);
    expect(find.byKey(WelcomeScreen.addMusicKey), findsNothing);

    await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    expect(h.dj.prompts, ['late']);
    expect(h.auth.anonymousSignIns, 1);
  });

  testWidgets('back pops', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, _above(const ArtistsScreen(prompt: 'late')));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsScreen), findsOneWidget);

    await tester.tap(find.byKey(TapeBackButton.defaultKey));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsScreen), findsNothing);
    expect(find.byKey(const Key('open')), findsOneWidget);
  });
}
