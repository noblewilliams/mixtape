import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/section_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';

import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// The screen under the native theme. `pumpScreen` builds a bare
/// `MaterialApp`, and every foundation control reads `MixtapeTokens` off the
/// ambient theme, so this pump carries one.
Future<void> pumpRequest(
  WidgetTester tester,
  ProviderContainer container,
  Widget home, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Size? surface,
}) async {
  if (surface != null) {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// House rule on the native controls: every one carries a Key and a 44 pt
/// target. Replaces `expectInteractiveWidgetsKeyed`, which audits the Material
/// controls these screens no longer build. Covers the foundation controls, the
/// inset rows, the adaptive switches, the segmented controls and the inline
/// privacy link.
void expectNativeControls(WidgetTester tester, Finder root) {
  final controls = find.descendant(
    of: root,
    matching: find.byWidgetPredicate(
      (w) =>
          w is TapeButton ||
          w is LabelChip ||
          w is TextAction ||
          w is InsetRow ||
          w is Switch ||
          w is CupertinoSlidingSegmentedControl ||
          (w is InkWell && w.key == const Key('link-spotify-privacy')),
    ),
  );
  expect(controls, findsWidgets);
  for (final element in controls.evaluate()) {
    expect(
      element.widget.key,
      isNotNull,
      reason: '${element.widget.runtimeType} without a Key',
    );
    expect(
      tester.getSize(find.byWidget(element.widget)).height,
      greaterThanOrEqualTo(44),
      reason: '${element.widget.key} under 44 pt',
    );
  }
}

void main() {
  testWidgets(
    'renders the eight request steps, word for word, with the address as a link',
    (tester) async {
      final links = FakeLinkOpener();
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, links: links),
        const SpotifyRequestScreen(),
      );

      expect(find.text('Bring your Spotify music'), findsOneWidget);
      expect(find.byKey(const Key('link-spotify-privacy')), findsNothing);
      await tester.tap(find.byKey(const Key('go-deeper')));
      await tester.pumpAndSettle();
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
        find.textContaining(
          'tap the download link in Mail, Safari saves the ZIP to Files',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('What the two emails look like'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(const Key('link-spotify-privacy')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('link-spotify-privacy')));
      await tester.pump();
      expect(links.opened, [spotifyPrivacyUrl]);
      expect(
        spotifyPrivacyUrl.toString(),
        'https://www.spotify.com/account/privacy/',
      );
    },
  );

  testWidgets(
    'the quick start is a section word, a tape button, the meta line and the '
    'Choose files chip over the three numbered rows',
    (tester) async {
      final links = FakeLinkOpener();
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, links: links),
        const SpotifyRequestScreen(),
      );

      expect(
        tester.widget<SectionWord>(find.byType(SectionWord).first).text,
        'Export your saved music',
      );
      expect(exportifyQuickStartSteps, hasLength(3));
      for (var i = 0; i < exportifyQuickStartSteps.length; i++) {
        expect(find.text('${i + 1}'), findsOneWidget);
        expect(find.text(exportifyQuickStartSteps[i]), findsOneWidget);
      }
      expect(
        tester.widget<TapeButton>(find.byKey(const Key('open-exportify'))).label,
        'Open Exportify ↗',
      );
      expect(find.text('Opens exportify.app outside Mixtape.'), findsOneWidget);
      expect(
        tester
            .widget<LabelChip>(find.byKey(const Key('choose-import-files')))
            .label,
        'Choose files',
      );
      expect(
        find.text(
          'Exportify ZIP or CSV files, or an official Spotify ZIP. Read on this '
          'device first; review before uploading.',
        ),
        findsOneWidget,
      );
      // The deeper block is one inset group, not a bordered card.
      expect(find.byType(InsetGroup), findsOneWidget);
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));

      await tester.tap(find.byKey(const Key('open-exportify')));
      await tester.pump();
      expect(links.opened, [Uri.parse('https://exportify.app/')]);
    },
  );

  testWidgets(
    '"I\'ve requested it" posts marked_requested and schedules the reminder three days out; '
    'the button then gives way to the elapsed wait',
    (tester) async {
      final reminders = FakeReminderScheduler();
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      listening.onPostFunnelEvent = (type) async {
        // The server derives markedRequestedAt from the event; the refetch
        // after the post sees it.
        listening.onboarding = onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: DateTime.now(),
        );
      };
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, reminders: reminders),
        const SpotifyRequestScreen(),
      );
      await tester.tap(find.byKey(const Key('go-deeper')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('requested-elapsed')), findsNothing);
      expect(
        tester
            .widget<TextAction>(find.byKey(const Key('mark-requested')))
            .label,
        "I've requested it",
      );

      await tester.ensureVisible(find.byKey(const Key('mark-requested')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mark-requested')));
      await tester.pumpAndSettle();

      expect(listening.funnelEvents, [FunnelEventType.markedRequested]);
      expect(reminders.scheduled, [const Duration(days: 3)]);
      expect(find.byKey(const Key('mark-requested')), findsNothing);
      expect(find.text('Requested just now'), findsOneWidget);
    },
  );

  testWidgets(
    'an already-marked listener sees the elapsed wait instead of the button',
    (tester) async {
      final reminders = FakeReminderScheduler();
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: DateTime.now().subtract(
            const Duration(days: 2, hours: 3),
          ),
        ),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, reminders: reminders),
        const SpotifyRequestScreen(),
      );

      expect(find.byKey(const Key('mark-requested')), findsNothing);
      // Collapsed, the wait rides on the Go deeper row itself.
      expect(find.text('Requested 2 days ago'), findsOneWidget);
      expect(
        find.text(
          'Help the DJ learn your repeat favourites and past listening.',
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('go-deeper')));
      await tester.pumpAndSettle();
      expect(find.text('Requested 2 days ago'), findsOneWidget);
      expect(reminders.scheduled, isEmpty);
      expect(listening.funnelEvents, isEmpty);
    },
  );

  testWidgets(
    'the "Done" button appears only when the gate embeds the screen, and calls back',
    (tester) async {
      var done = 0;
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        SpotifyRequestScreen(onDone: () => done++),
      );

      expect(find.text('Done, take me to the tapes'), findsOneWidget);
      expect(
        tester.widget<TapeButton>(find.byKey(const Key('request-done'))).label,
        'Done, take me to the tapes',
      );
      // The gate owns the way out, so the screen offers no back cluster.
      expect(find.byKey(const Key('request-back')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('request-done')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('request-done')));
      expect(done, 1);
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));

      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );
      expect(find.byKey(const Key('request-done')), findsNothing);
      expect(find.byKey(const Key('request-back')), findsOneWidget);
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    },
  );

  testWidgets('renders in dark without overflowing', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'spotify'),
    );
    await pumpRequest(
      tester,
      onboardingContainer(listening: listening),
      const SpotifyRequestScreen(),
      brightness: Brightness.dark,
    );

    expect(find.text('Bring your Spotify music'), findsOneWidget);
    await tester.tap(find.byKey(const Key('go-deeper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mark-requested')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holds together at 200% text on a 320 pt screen', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'spotify'),
    );
    await pumpRequest(
      tester,
      onboardingContainer(listening: listening),
      const SpotifyRequestScreen(),
      textScale: 2,
      surface: const Size(320, 900),
    );

    expect(find.text('Opens exportify.app outside Mixtape.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('go-deeper')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('go-deeper')));
    await tester.pumpAndSettle();
    expect(find.text('spotify.com/account/privacy'), findsOneWidget);
    expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    expect(tester.takeException(), isNull);
  });
}
