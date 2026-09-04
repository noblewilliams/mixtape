import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/screens/interview_screen.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

const _result = InterviewResult(seeds: 2, notesSaved: 4, notesDuplicate: 0, notesCapped: 0);

Future<void> _addArtist(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const Key('interview-artist-field')), name);
  await tester.tap(find.byKey(const Key('interview-add-artist')));
  await tester.pump();
}

/// Pushes the interview on top of a placeholder so popping is observable.
Future<void> _pumpPushed(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InterviewScreen()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Home has long since built the onboarding state by the time it pushes the
  // interview; build it here too so the first fetch is not mistaken for a refresh.
  container.read(onboardingProvider);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('artists become chips: trimmed, deduplicated, 1–200 chars, at most 20',
      (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const InterviewScreen());

    await _addArtist(tester, '  Sade  ');
    expect(find.byKey(const Key('interview-artist-0')), findsOneWidget);
    expect(find.text('Sade'), findsOneWidget);

    await _addArtist(tester, 'Sade');
    await _addArtist(tester, '   ');
    expect(find.byType(InputChip), findsOneWidget);

    await _addArtist(tester, 'x' * 201);
    expect(find.byType(InputChip), findsOneWidget);
    expect(find.textContaining('200'), findsWidgets);

    for (var i = 1; i < 20; i++) {
      await _addArtist(tester, 'Artist $i');
    }
    expect(find.byType(InputChip), findsNWidgets(20));
    final add = tester.widget<IconButton>(find.byKey(const Key('interview-add-artist')));
    expect(add.onPressed, isNull);

    // A chip's delete affordance removes it.
    tester.widget<InputChip>(find.byKey(const Key('interview-artist-0'))).onDeleted!();
    await tester.pump();
    expect(find.byType(InputChip), findsNWidgets(19));
    expect(find.text('Sade'), findsNothing);

    expectInteractiveWidgetsKeyed(find.byType(InterviewScreen));
  });

  testWidgets('submit posts the five answers on the ios surface, refreshes onboarding, '
      'reports the counts, and pops', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'))
      ..onPostInterview = (_) async => _result;
    final container = onboardingContainer(listening: listening);
    await _pumpPushed(tester, container);
    final getsBefore = listening.getOnboardingCalls;

    await _addArtist(tester, 'Sade');
    await _addArtist(tester, 'Burna Boy');
    await tester.enterText(find.byKey(const Key('interview-plays-most')), ' late-night afrobeats ');
    await tester.enterText(find.byKey(const Key('interview-listens-when')), 'commutes, focus');
    await tester.enterText(find.byKey(const Key('interview-never-wants')), 'novelty songs');
    await tester.enterText(find.byKey(const Key('interview-era')), '2004');
    await tester.ensureVisible(find.byKey(const Key('interview-submit')));
    await tester.tap(find.byKey(const Key('interview-submit')));
    await tester.pumpAndSettle();

    final body = listening.interviews.single.toJson('ios');
    expect(body, {
      'surface': 'ios',
      'neverSkip': ['Sade', 'Burna Boy'],
      'playsMost': 'late-night afrobeats',
      'listensWhen': 'commutes, focus',
      'neverWants': 'novelty songs',
      'era': '2004',
    });
    expect(listening.getOnboardingCalls, getsBefore + 1);
    expect(find.byType(InterviewScreen), findsNothing);
    expect(find.text('saved 4 notes, 2 artists'), findsOneWidget);
  });

  testWidgets('"Save my answers" stays disabled until at least one artist is named',
      (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const InterviewScreen());
    FilledButton submit() =>
        tester.widget<FilledButton>(find.byKey(const Key('interview-submit')));

    expect(submit().onPressed, isNull);
    await _addArtist(tester, 'Sade');
    expect(submit().onPressed, isNotNull);

    tester.widget<InputChip>(find.byKey(const Key('interview-artist-0'))).onDeleted!();
    await tester.pump();
    expect(submit().onPressed, isNull);

    // The four answers alone are not enough.
    await tester.enterText(find.byKey(const Key('interview-era')), '1999');
    await tester.pump();
    expect(submit().onPressed, isNull);
    expect(listening.interviews, isEmpty);
  });

  testWidgets('the four answers may stay empty and post as empty strings', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'))
      ..onPostInterview = (_) async =>
          const InterviewResult(seeds: 1, notesSaved: 1, notesDuplicate: 0, notesCapped: 0);
    await _pumpPushed(tester, onboardingContainer(listening: listening));

    await _addArtist(tester, 'Sade');
    await tester.enterText(find.byKey(const Key('interview-era')), 'the nineties');
    await tester.ensureVisible(find.byKey(const Key('interview-submit')));
    await tester.tap(find.byKey(const Key('interview-submit')));
    await tester.pumpAndSettle();

    final answers = listening.interviews.single;
    expect(answers.neverSkip, ['Sade']);
    expect(answers.playsMost, '');
    expect(answers.listensWhen, '');
    expect(answers.neverWants, '');
    expect(answers.era, 'the nineties');
    expect(find.text('saved 1 note, 1 artist'), findsOneWidget);
  });

  testWidgets('an answer over 300 UTF-16 code units is refused inline, never posted',
      (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'))
      ..onPostInterview = (_) async => _result;
    await _pumpPushed(tester, onboardingContainer(listening: listening));

    await _addArtist(tester, 'Sade');
    // 160 graphemes — inside the field's own 300-character limit — but two
    // UTF-16 code units each, which is what the server's 300 counts.
    final astral = '\u{1F3B5}' * 160;
    expect(astral.characters.length, 160);
    expect(astral.length, 320);
    await tester.enterText(find.byKey(const Key('interview-era')), astral);
    await tester.ensureVisible(find.byKey(const Key('interview-submit')));
    await tester.tap(find.byKey(const Key('interview-submit')));
    await tester.pumpAndSettle();

    expect(listening.interviews, isEmpty);
    expect(find.byType(InterviewScreen), findsOneWidget);
    expect(find.byKey(const Key('interview-error')), findsOneWidget);
    expect(find.text('Keep each answer to 300 characters'), findsOneWidget);
  });

  testWidgets('a failed submit shows an inline error and keeps the form', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'))
      ..onPostInterview = (_) async => throw ApiException(500, 'boom');
    await _pumpPushed(tester, onboardingContainer(listening: listening));

    await _addArtist(tester, 'Sade');
    await tester.enterText(find.byKey(const Key('interview-era')), '1999');
    await tester.ensureVisible(find.byKey(const Key('interview-submit')));
    await tester.tap(find.byKey(const Key('interview-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(InterviewScreen), findsOneWidget);
    expect(find.byKey(const Key('interview-error')), findsOneWidget);
    expect(find.text('1999'), findsOneWidget);
    expect(listening.funnelEvents, isEmpty);
  });
}
