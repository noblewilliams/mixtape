import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

void main() {
  testWidgets('a blank listener (no service, no sources, no library) sees the gate',
      (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState());
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    expect(find.byType(ChooseServiceScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Which do you use?'), findsOneWidget);
    expectInteractiveWidgetsKeyed(find.byType(ChooseServiceScreen));
  });

  testWidgets('an Apple listener goes straight to Home', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'apple'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
  });

  testWidgets('a Spotify listener goes straight to Home', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
  });

  testWidgets('while onboarding loads the gate shows the same spinner as the unknown auth state',
      (tester) async {
    final completer = Completer<OnboardingState>();
    final listening = FakeListeningApi()..onGetOnboarding = () => completer.future;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: onboardingContainer(listening: listening),
        child: const MaterialApp(home: ServiceGate()),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(ChooseServiceScreen), findsNothing);

    completer.complete(onboardingState(chosenService: 'apple'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('an onboarding error falls through to Home — never lock a listener out — and a '
      'later successful refetch does not unseat it', (tester) async {
    var calls = 0;
    final listening = FakeListeningApi(onboarding: onboardingState())
      ..onGetOnboarding = () async {
        if (calls++ == 0) throw ApiException(500, 'onboarding boom');
        return onboardingState();
      };
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);

    // Riverpod retries the failed build; it now answers "no service chosen",
    // which must not swap the gate in over a listener already on Home.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
  });

  testWidgets('choosing Apple Music records nothing and lands on Home', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState());
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    await tester.tap(find.byKey(const Key('choose-apple')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(listening.funnelEvents, isEmpty);
  });

  testWidgets(
      'choosing Spotify posts chose_spotify and shows the request screen as the gate\'s second '
      'step; "Done" lands on Home without any route push', (tester) async {
    final listening = FakeListeningApi(onboarding: onboardingState());
    await pumpScreen(tester, onboardingContainer(listening: listening), const ServiceGate());

    await tester.tap(find.byKey(const Key('choose-spotify')));
    await tester.pumpAndSettle();

    expect(listening.funnelEvents, [FunnelEventType.choseSpotify]);
    expect(find.byType(SpotifyRequestScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byKey(const Key('request-done')), findsOneWidget);

    // The refetch after the event now says 'spotify', and the gate must keep
    // showing the request step rather than flipping to Home underneath the
    // listener.
    listening.onboarding = onboardingState(chosenService: 'spotify');
    await tester.pumpAndSettle();
    expect(find.byType(SpotifyRequestScreen), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('request-done')));
    await tester.tap(find.byKey(const Key('request-done')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SpotifyRequestScreen), findsNothing);
    expect(Navigator.of(tester.element(find.byType(HomeScreen))).canPop(), isFalse);
  });
}
