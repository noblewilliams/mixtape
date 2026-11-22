// Making your mix. (first-run spec → The pages, path A step 3): the waiting
// page from the moment the prompt is sent until the DJ turn returns.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/push/push_service.dart';
import 'package:mixtape/data/dj/dj_api.dart' show TurnStep;
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/mix_background_provider.dart';
import 'package:mixtape/presentation/providers/working_step.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/making_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/push_permission_popup.dart';

import 'first_run_harness.dart';

const _headline = 'Making your mix.';
const _line = 'About a minute.';

/// A stand-in for the page below, so the system back has a route to pop.
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

Future<void> _openArtists(
  WidgetTester tester,
  FirstRunHarness h, {
  String prompt = 'rainy commute',
}) async {
  await h.pump(tester, _above(ArtistsScreen(prompt: prompt)));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  for (final (i, name) in [(0, 'Burna Boy'), (1, 'Tems'), (2, 'Sade')]) {
    await tester.enterText(find.byKey(ArtistsScreen.fieldKey(i)), name);
    await tester.testTextInput.receiveAction(
      i == 2 ? TextInputAction.done : TextInputAction.next,
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _openPromptPage(WidgetTester tester, FirstRunHarness h) async {
  await h.pump(tester, _above(const WelcomeScreen.prompt(songsIn: 1284)));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
  await tester.pump();
}

void _expectMaking() {
  expect(find.byType(MakingScreen), findsOneWidget);
  expect(find.text(_headline), findsOneWidget);
  expect(find.text(_line), findsOneWidget);
  expect(find.byKey(TapeBackButton.defaultKey), findsNothing);
  expect(find.byKey(StepScaffold.counterKey), findsNothing);
  expect(find.byType(FirstRunPill), findsNothing);
}

void main() {
  group('the Mix ready ask (2026-11-21)', () {
    reduceMotion();

    Future<FirstRunHarness> making(WidgetTester tester) async {
      final h = FirstRunHarness();
      h.push.current = PushStatus.notDetermined;
      h.container.read(firstRunActiveProvider);
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();
      _expectMaking();
      return h;
    }

    Future<void> waitForAsk(WidgetTester tester) async {
      await tester.pump(PushAskTrigger.workingDelay);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
    }

    testWidgets('about 3 s in it asks over Making; after Allow, the bell '
        "line joins the step line and the phone registers", (tester) async {
      final h = await making(tester);
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      await waitForAsk(tester);
      // Making carries on behind it.
      expect(find.byType(MakingScreen), findsOneWidget);
      expect(find.byKey(MakingScreen.pingKey), findsNothing);

      await tester.tap(find.byKey(PushAskCopy.allowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(h.push.calls, containsAllInOrder(['requestAuthorization']));
      expect(h.push.calls, contains('register'));
      expect(find.text(MakingScreen.pingLine), findsOneWidget);
      expect(await h.pushAsk.asked(), isTrue);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsNothing);
    });

    testWidgets('a turn that lands under the pop-up waits for the answer: '
        'Making stays behind it, then the mix opens', (tester) async {
      final h = await making(tester);
      await waitForAsk(tester);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(PushAskCopy.popupKey), findsOneWidget);
      expect(find.byType(MakingScreen), findsOneWidget);
      expect(h.container.read(pendingConversationProvider), isNull);

      await tester.tap(find.byKey(PushAskCopy.notNowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(PushAskCopy.popupKey), findsNothing);
      expect(find.byType(MakingScreen), findsNothing);
      expect(
        h.container.read(pendingConversationProvider)?.sessionId,
        'session-new',
      );
      expect(find.byKey(MakingScreen.pingKey), findsNothing);
      expect(h.push.calls, isNot(contains('requestAuthorization')));
    });
  });

  group('with reduced motion', () {
    reduceMotion();

    testWidgets('Artists Continue with a prompt shows the making page, with '
        'its headline and line and no back, before the DJ turn returns', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);

      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();

      expect(h.listening.putSeeds, [
        ['Burna Boy', 'Tems', 'Sade'],
      ]);
      expect(h.dj.prompts, ['rainy commute']);
      _expectMaking();
      expect(h.container.read(pendingConversationProvider), isNull);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('Artists: success pops the making page and hands off with '
        'the new mix', (tester) async {
      final h = FirstRunHarness();
      h.container.read(firstRunActiveProvider);
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsOneWidget);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(MakingScreen), findsNothing);
      expect(h.container.read(firstRunActiveProvider), isFalse);
      expect(
        h.container.read(pendingConversationProvider)?.sessionId,
        'session-new',
      );
    });

    testWidgets('Artists: a failure returns to Who do you love? with the '
        'error and the three chips intact', (tester) async {
      final h = FirstRunHarness();
      h.dj.gate = Completer<void>();
      h.dj.failWith = Exception('boom');
      await _openArtists(tester, h);
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsOneWidget);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(MakingScreen), findsNothing);
      expect(find.byType(ArtistsScreen), findsOneWidget);
      expect(find.byKey(ArtistsScreen.errorKey), findsOneWidget);
      expect(
        find.text('Something went wrong on our end. Try again.'),
        findsOneWidget,
      );
      for (final (i, name) in [(0, 'Burna Boy'), (1, 'Tems'), (2, 'Sade')]) {
        expect(
          find.descendant(
            of: find.byKey(ArtistsScreen.chipKey(i)),
            matching: find.text(name),
          ),
          findsOneWidget,
        );
      }
      expect(enabled(tester, ArtistsScreen.continueKey), isTrue);
      expect(h.container.read(pendingConversationProvider), isNull);
    });

    testWidgets('prompt page send shows the making page before the DJ turn '
        'returns, and success hands off', (tester) async {
      final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
      h.container.read(firstRunActiveProvider);
      h.dj.gate = Completer<void>();
      await _openPromptPage(tester, h);

      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(h.dj.prompts, ['late']);
      _expectMaking();
      expect(h.container.read(pendingConversationProvider), isNull);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(MakingScreen), findsNothing);
      expect(h.container.read(firstRunActiveProvider), isFalse);
      expect(
        h.container.read(pendingConversationProvider)?.sessionId,
        'session-new',
      );
    });

    testWidgets('prompt page: a failure returns to the page with the error '
        'and the prompt kept', (tester) async {
      final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
      h.dj.gate = Completer<void>();
      h.dj.failWith = Exception('boom');
      await _openPromptPage(tester, h);
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsOneWidget);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(MakingScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byKey(WelcomeScreen.errorKey), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'late',
      );
      expect(h.container.read(pendingConversationProvider), isNull);
    });

    testWidgets('the system back does nothing while the mix is being made', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(MakingScreen), findsOneWidget);
      expect(find.text(_headline), findsOneWidget);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(MakingScreen), findsNothing);
    });

    testWidgets('the page is named by its headline and the line is announced '
        'once, politely', (tester) async {
      final h = FirstRunHarness();
      final semantics = tester.ensureSemantics();
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);
      tester.takeAnnouncements();
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));

      expect(
        tester.getSemantics(find.byKey(StepScaffold.headlineKey).last),
        matchesSemantics(label: _headline, isHeader: true, namesRoute: true),
      );
      final announced = tester.takeAnnouncements();
      expect(announced, hasLength(1));
      expect(announced.single.message, _line);
      expect(announced.single.assertiveness, Assertiveness.polite);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
      semantics.dispose();
    });

    testWidgets('reduced motion: the hubs stand still while making', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.dj.gate = Completer<void>();
      await _openArtists(tester, h);
      await tester.tap(find.byKey(ArtistsScreen.continueKey));
      await tester.pumpAndSettle();

      expect(find.byKey(MakingScreen.cassetteKey), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);

      h.dj.gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('the step line (turn steps 2026-11-13)', () {
    reduceMotion();

    Future<FirstRunHarness> making(WidgetTester tester) async {
      final h = FirstRunHarness();
      phone(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: const MakingScreen(),
          ),
        ),
      );
      await tester.pump();
      return h;
    }

    String stepLine(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(MakingScreen.stepKey),
            matching: find.byType(Text),
          ),
        )
        .data!;

    testWidgets('promises a ping once notifications are allowed', (
      tester,
    ) async {
      final h = await making(tester);
      expect(find.text(_line), findsOneWidget);
      expect(find.byKey(MakingScreen.pingKey), findsNothing);
      h.push.current = PushStatus.authorized;
      h.container.read(mixBackgroundProvider.notifier).turnsOut(true);
      await tester.pump();
      await tester.pump();
      // The step line stays; the bell line joins it, under it.
      expect(find.text(MakingScreen.pingLine), findsOneWidget);
      expect(MakingScreen.pingLine, 'We’ll ping you when it’s ready.');
      expect(find.text(_line), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(MakingScreen.pingKey)).dy,
        greaterThan(tester.getBottomLeft(find.byKey(MakingScreen.stepKey)).dy),
      );
      // It never asked: the pop-up is the only ask.
      expect(h.push.calls, isNot(contains('requestAuthorization')));
    });

    testWidgets('under the headline and its line, it starts on listening '
        'and walks the clock while nothing streams', (tester) async {
      await making(tester);
      expect(find.text(_headline), findsOneWidget);
      expect(find.text(_line), findsOneWidget);
      expect(stepLine(tester), 'The DJ is listening');
      expect(
        tester.getTopLeft(find.byKey(MakingScreen.stepKey)).dy,
        greaterThan(tester.getBottomLeft(find.text(_line)).dy),
      );
      final line = tester.widget<Text>(find.text(_line));
      final step = tester.widget<Text>(
        find.descendant(
          of: find.byKey(MakingScreen.stepKey),
          matching: find.byType(Text),
        ),
      );
      expect(step.style?.fontSize, line.style?.fontSize);
      expect(step.maxLines, 1);

      await tester.pump(const Duration(seconds: 5));
      expect(stepLine(tester), isNot('The DJ is listening'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('it follows the new mix\'s steps, names and all, and is not '
        'announced', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await making(tester);
      tester.takeAnnouncements();
      final made = h.container
          .read(mixActivityProvider.notifier)
          .beginNewMix('rainy commute');
      made.step(WorkingStep.listening(DateTime.now()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      expect(stepLine(tester), 'The DJ is listening');

      made.step(
        WorkingStep(
          const TurnStep('digging', scope: 'catalogue', artists: ['Tems']),
          DateTime.now(),
        ),
      );
      await tester.pump();
      expect(
        stepLine(tester),
        isIn(['Digging for Tems', 'Crate-digging for Tems']),
      );
      expect(tester.takeAnnouncements(), isEmpty);
      expect(find.bySemanticsLabel(RegExp('Tems')), findsNothing);

      made(sessionId: 'new');
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    });
  });

  testWidgets('with motion allowed the hubs turn', (tester) async {
    final h = FirstRunHarness();
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const MakingScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<CassetteTile>(find.byKey(MakingScreen.cassetteKey))
          .spinning,
      isTrue,
    );
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
