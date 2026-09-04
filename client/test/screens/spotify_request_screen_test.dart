import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// The spec's copy is kept in the screen with `**bold**` / `*italic*`
/// markup; what the listener reads is the text without the marks.
String plain(String step) => step.replaceAll('**', '').replaceAll('*', '');

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
    // Step 1 carries the link inline, so its plain text is checked around it.
    expect(
      find.textContaining(
        'and log in with the account that has your listening history. '
        'A laptop is easier than a phone for this part.',
      ),
      findsOneWidget,
    );
    for (final step in spotifyRequestSteps.skip(1)) {
      expect(find.text(plain(step)), findsOneWidget, reason: step);
    }
    expect(find.text('Scroll to Download your data.'), findsOneWidget);
    expect(find.text("Save the ZIPs as they are. Don't unzip them."), findsOneWidget);
    expect(
      find.textContaining('tap the download link in Mail, Safari saves the ZIP to Files'),
      findsOneWidget,
    );
    expect(find.textContaining('What the two emails look like'), findsOneWidget);

    expect(find.text('spotify.com/account/privacy'), findsOneWidget);
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
