import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/interview_screen.dart';
import 'package:mixtape/presentation/screens/music_sources_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

void main() {
  testWidgets('an Apple listener sees no waiting card', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'apple'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.byKey(const Key('waiting-card')), findsNothing);
    expect(find.byKey(const Key('prompt-field')), findsOneWidget);
  });

  testWidgets('a Spotify choice the server never heard (dropped post) still shows the waiting '
      'card on the next launch, through the flag kept on the device', (tester) async {
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('user-1', 'spotify');
    final listening = FakeListeningApi(onboarding: onboardingState(userId: 'user-1'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, prefs: prefs),
      const HomeScreen(),
    );

    expect(find.byKey(const Key('waiting-card')), findsOneWidget);
    expect(find.text('Not requested yet'), findsOneWidget);
  });

  testWidgets('a Spotify listener with both packages in sees no waiting card', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime(2026, 8, 1),
        interviewCompletedAt: DateTime(2026, 8, 2),
        importCompletedAt: DateTime(2026, 8, 20),
        sources: [
          musicSource(
            packages: ['spotify_account', 'spotify_extended'],
            lastImportedAt: DateTime(2026, 8, 20),
          ),
        ],
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.byKey(const Key('waiting-card')), findsNothing);
  });

  testWidgets('one package in: the card stays with a "1 of 2 in" chip and a nudge for the other '
      'package, and no "Not personal yet" note', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime(2026, 8, 1),
        importCompletedAt: DateTime(2026, 8, 20),
        sources: [
          musicSource(packages: ['spotify_extended'], lastImportedAt: DateTime(2026, 8, 20)),
        ],
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.byKey(const Key('waiting-card')), findsOneWidget);
    expect(find.text('1 of 2 in'), findsOneWidget);
    expect(find.textContaining('Still waiting for the account data'), findsOneWidget);
    expect(find.textContaining('Not personal yet'), findsNothing);
    expect(find.byKey(const Key('waiting-requested')), findsNothing);
    expectInteractiveWidgetsKeyed(find.byKey(const Key('waiting-card')));

    listening.onboarding = onboardingState(
      chosenService: 'spotify',
      sources: [musicSource(packages: ['spotify_account'], lastImportedAt: DateTime(2026, 8, 20))],
    );
    await tester.drag(find.byKey(const Key('sessions-empty')), const Offset(0, 300));
    await tester.pumpAndSettle();
    // Home refreshes onboarding on the way back from a pushed screen; drive
    // that path through the sources screen.
    await tester.tap(find.byKey(const Key('sources-action')));
    await tester.pumpAndSettle();
    expect(find.byType(MusicSourcesScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(MusicSourcesScreen))).pop();
    await tester.pumpAndSettle();

    expect(find.textContaining('Still waiting for the extended history'), findsOneWidget);
    expect(find.textContaining('Still waiting for the account data'), findsNothing);
  });

  testWidgets('the chip reads Not requested, then Waiting', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());
    expect(find.text('Not requested'), findsOneWidget);

    listening.onboarding = onboardingState(
      chosenService: 'spotify',
      markedRequestedAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    await tester.tap(find.byKey(const Key('open-request')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(SpotifyRequestScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Waiting'), findsOneWidget);
  });

  testWidgets('Choose a ZIP opens the import sheet and picks', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    final picker = FakeArchivePicker(extendedArchive);
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, picker: picker),
      const HomeScreen(),
    );

    await tester.tap(find.byKey(const Key('waiting-choose-zip')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets('the Interview done tile shows the notes and artists it produced', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        interviewCompletedAt: DateTime(2026, 8, 2),
        interview: const InterviewCounts(artists: 6, notes: 5),
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.byKey(const Key('interview-done')), findsOneWidget);
    expect(find.text('5 notes, 6 artists'), findsOneWidget);
  });

  testWidgets('the Your music action pushes the sources screen', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'apple'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    await tester.tap(find.byKey(const Key('sources-action')));
    await tester.pumpAndSettle();

    expect(find.byType(MusicSourcesScreen), findsOneWidget);
  });

  testWidgets('not requested yet: the card says so and opens the request screen (pushed, '
      'without the gate\'s Done button)', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.byKey(const Key('waiting-card')), findsOneWidget);
    expect(find.text('Not requested yet'), findsOneWidget);
    expect(find.textContaining('Not personal yet'), findsOneWidget);
    expectInteractiveWidgetsKeyed(find.byKey(const Key('waiting-card')));

    await tester.tap(find.byKey(const Key('open-request')));
    await tester.pumpAndSettle();

    expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    expect(find.byKey(const Key('request-done')), findsNothing);
    expect(find.byKey(const Key('mark-requested')), findsOneWidget);
  });

  testWidgets('requested: the card shows the elapsed wait', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime.now().subtract(const Duration(days: 2, hours: 1)),
      ),
    );
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.text('Requested 2 days ago'), findsOneWidget);
    expect(find.text('Not requested yet'), findsNothing);
    expect(find.byKey(const Key('open-request')), findsOneWidget);
  });

  testWidgets('the interview card opens the interview until it is done', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const HomeScreen());

    expect(find.text('Tell the DJ about your taste'), findsOneWidget);
    expect(find.byKey(const Key('interview-done')), findsNothing);

    await tester.tap(find.byKey(const Key('open-interview')));
    await tester.pumpAndSettle();
    expect(find.byType(InterviewScreen), findsOneWidget);

    listening.onboarding = onboardingState(
      chosenService: 'spotify',
      interviewCompletedAt: DateTime.now(),
    );
    Navigator.of(tester.element(find.byType(InterviewScreen))).pop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('interview-done')), findsOneWidget);
    expect(find.text('Interview done'), findsOneWidget);
    expect(find.byKey(const Key('open-interview')), findsNothing);
  });
}
