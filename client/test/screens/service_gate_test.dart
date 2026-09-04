import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
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

  testWidgets('an onboarding error falls through to Home — never lock a listener out — is not '
      'retried, and a later successful refetch does not unseat it', (tester) async {
    var calls = 0;
    final listening = FakeListeningApi(onboarding: onboardingState())
      ..onGetOnboarding = () async {
        if (calls++ == 0) throw ApiException(500, 'onboarding boom');
        return onboardingState();
      };
    final container = onboardingContainer(listening: listening);
    await pumpScreen(tester, container, const ServiceGate());

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);

    // No retry: the failed load is final (after a sign-out, a 401 must not
    // become a loop of unauthenticated GETs through the backoff), and Home
    // stays.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(HomeScreen), findsOneWidget);

    // A refetch that now answers "no service chosen" must not swap the gate
    // in over a listener already on Home.
    expect(await container.read(onboardingProvider.notifier).refresh(), isTrue);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
  });

  testWidgets("the next listener's gate decides from their own onboarding, never from the "
      "previous account's carried-over state", (tester) async {
    final auth = TestAuthNotifier(AuthStatus.signedIn);
    final listening =
        FakeListeningApi(onboarding: onboardingState(chosenService: 'apple', userId: 'a'));
    final container = onboardingContainer(listening: listening, auth: auth);
    await pumpScreen(tester, container, const ServiceGate());
    expect(find.byType(HomeScreen), findsOneWidget);

    // A signs out: the signed-in tree, gate included, goes away.
    auth.set(AuthStatus.signedOut);
    await pumpScreen(tester, container, const SizedBox());

    // B signs in with nothing yet, and their onboarding takes a moment to
    // load. Riverpod carries A's value into that loading state; the gate
    // must not decide from it.
    final completer = Completer<OnboardingState>();
    listening.onGetOnboarding = () => completer.future;
    auth.set(AuthStatus.signedIn);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ServiceGate()),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    completer.complete(onboardingState(userId: 'b'));
    await tester.pumpAndSettle();
    expect(find.byType(ChooseServiceScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('choosing Apple Music records nothing on the server, remembers the choice on '
      'the device, and lands on Home', (tester) async {
    final prefs = InMemoryServicePreferenceStore();
    final listening = FakeListeningApi(onboarding: onboardingState(userId: 'user-1'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, prefs: prefs),
      const ServiceGate(),
    );

    await tester.tap(find.byKey(const Key('choose-apple')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(listening.funnelEvents, isEmpty);
    expect(await prefs.read('user-1'), 'apple');
  });

  testWidgets('a blank server answer with an Apple choice remembered on this device goes '
      'straight to Home', (tester) async {
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('user-1', 'apple');
    final listening = FakeListeningApi(onboarding: onboardingState(userId: 'user-1'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, prefs: prefs),
      const ServiceGate(),
    );

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
  });

  testWidgets("another account's remembered choice does not skip the gate", (tester) async {
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('someone-else', 'apple');
    final listening = FakeListeningApi(onboarding: onboardingState(userId: 'user-1'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, prefs: prefs),
      const ServiceGate(),
    );

    expect(find.byType(ChooseServiceScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets(
      'choosing Spotify posts chose_spotify and shows the request screen as the gate\'s second '
      'step; "Done" lands on Home without any route push', (tester) async {
    final prefs = InMemoryServicePreferenceStore();
    final listening = FakeListeningApi(onboarding: onboardingState(userId: 'user-1'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, prefs: prefs),
      const ServiceGate(),
    );

    await tester.tap(find.byKey(const Key('choose-spotify')));
    await tester.pumpAndSettle();

    expect(listening.funnelEvents, [FunnelEventType.choseSpotify]);
    expect(await prefs.read('user-1'), 'spotify');
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
