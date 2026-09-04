import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

void main() {
  testWidgets('renders the eight request steps, word for word, with the address as a link',
      (tester) async {
    final links = FakeLinkOpener();
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, links: links),
      const SpotifyRequestScreen(),
    );

    expect(spotifyRequestSteps, hasLength(8));
    for (var i = 1; i <= 8; i++) {
      expect(find.text('$i.'), findsOneWidget, reason: 'step $i number');
    }
    // The spec's eight sentences ("Spotify request flow" in
    // docs/superpowers/specs/2026-09-01-listening-export-import-design.md),
    // as literals so copy drift in the screen fails here. Step 1 carries
    // the link inline, so its plain text is checked around the address.
    expect(find.text('spotify.com/account/privacy'), findsOneWidget);
    expect(
      find.textContaining(
        'and log in with the account that has your listening history. '
        'A laptop is easier than a phone for this part.',
      ),
      findsOneWidget,
    );
    const specSteps = [
      'Scroll to Download your data.',
      'Select Account data and Extended streaming history. '
          'Leave Technical log information unselected.',
      'Press Request data.',
      'Check your email. Spotify sends a confirmation message first. Open it and press '
          'Confirm. Nothing is prepared until you do, and this is the step most people miss.',
      'Wait. The two packages arrive as separate emails, each with a Download button, '
          'usually within days; the extended history can take up to 30. Each link expires '
          'after about two weeks, so download it when you see it.',
      "Save the ZIPs as they are. Don't unzip them.",
      "Come back to Mixtape and give it each ZIP as it arrives. You don't have to wait for both.",
    ];
    for (final step in specSteps) {
      expect(find.text(step), findsOneWidget, reason: step);
    }
    expect(
      find.textContaining('tap the download link in Mail, Safari saves the ZIP to Files'),
      findsOneWidget,
    );
    expect(find.textContaining('What the two emails look like'), findsOneWidget);

    await tester.tap(find.byKey(const Key('link-spotify-privacy')));
    await tester.pump();
    expect(links.opened, [spotifyPrivacyUrl]);
    expect(spotifyPrivacyUrl.toString(), 'https://www.spotify.com/account/privacy/');
  });

  testWidgets(
      '"I\'ve requested it" posts marked_requested and schedules the reminder three days out; '
      'the button then gives way to the elapsed wait', (tester) async {
    final reminders = FakeReminderScheduler();
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    listening.onPostFunnelEvent = (type) async {
      // The server derives markedRequestedAt from the event; the refetch
      // after the post sees it.
      listening.onboarding = onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime.now(),
      );
    };
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, reminders: reminders),
      const SpotifyRequestScreen(),
    );
    expect(find.byKey(const Key('requested-elapsed')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('mark-requested')));
    await tester.tap(find.byKey(const Key('mark-requested')));
    await tester.pumpAndSettle();

    expect(listening.funnelEvents, [FunnelEventType.markedRequested]);
    expect(reminders.scheduled, [const Duration(days: 3)]);
    expect(find.byKey(const Key('mark-requested')), findsNothing);
    expect(find.text('Requested just now'), findsOneWidget);
  });

  testWidgets('an already-marked listener sees the elapsed wait instead of the button',
      (tester) async {
    final reminders = FakeReminderScheduler();
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime.now().subtract(const Duration(days: 2, hours: 3)),
      ),
    );
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening, reminders: reminders),
      const SpotifyRequestScreen(),
    );

    expect(find.byKey(const Key('mark-requested')), findsNothing);
    expect(find.text('Requested 2 days ago'), findsOneWidget);
    expect(reminders.scheduled, isEmpty);
    expect(listening.funnelEvents, isEmpty);
  });

  testWidgets('the "Done" button appears only when the gate embeds the screen, and calls back',
      (tester) async {
    var done = 0;
    final listening = FakeListeningApi(onboarding: onboardingState(chosenService: 'spotify'));
    await pumpScreen(
      tester,
      onboardingContainer(listening: listening),
      SpotifyRequestScreen(onDone: () => done++),
    );

    expect(find.text('Done, take me to the tapes'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('request-done')));
    await tester.tap(find.byKey(const Key('request-done')));
    expect(done, 1);
    expectInteractiveWidgetsKeyed(find.byType(SpotifyRequestScreen));

    await pumpScreen(
      tester,
      onboardingContainer(listening: listening),
      const SpotifyRequestScreen(),
    );
    expect(find.byKey(const Key('request-done')), findsNothing);
    expectInteractiveWidgetsKeyed(find.byType(SpotifyRequestScreen));
  });
}
