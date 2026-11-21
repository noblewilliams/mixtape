import 'package:flutter/cupertino.dart' show CupertinoAlertDialog;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/brand_icons.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_segmented_control.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import 'package:mixtape/presentation/widgets/library_sync_dialog.dart';

import '../helpers/fake_import_service.dart';
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
  bool settle = true,
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
  if (settle) await tester.pumpAndSettle();
}

/// House rule on the native controls: every one carries a Key and a 44 pt
/// target. Replaces `expectInteractiveWidgetsKeyed`, which audits the Material
/// controls these screens no longer build. Covers the foundation controls, the
/// inset rows, the adaptive switches, the glass segmented control (its
/// fallback toggle is keyed by its segments), the step's sync icon and the
/// inline privacy link.
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
          w is GlassSegmentedControl ||
          (w is InkWell && w.key == const Key('link-spotify-privacy')) ||
          (w is InkWell && w.key == SpotifyRequestScreen.goDeeperKey) ||
          w.key == SpotifyRequestScreen.appleSyncKey,
    ),
  );
  expect(controls, findsWidgets);
  for (final element in controls.evaluate()) {
    expect(
      element.widget.key,
      isNotNull,
      reason: '${element.widget.runtimeType} without a Key',
    );
    // The house segmented toggle is drawn to the founder's 32 pt track
    // (smoke round five, note 3); everything else keeps the 44 pt rule.
    final floor = element.widget is GlassSegmentedControl
        ? SegmentedToggle.trackHeight
        : 44.0;
    expect(
      tester.getSize(find.byWidget(element.widget)).height,
      greaterThanOrEqualTo(floor),
      reason: '${element.widget.key} under $floor pt',
    );
  }
}

/// The disclosure row sits in the pane's second step, below the fold on a
/// test surface.
Future<void> openDeeper(WidgetTester tester) async {
  final row = find.byKey(SpotifyRequestScreen.goDeeperKey);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
}

DateTime _thisYear(int month, int day) =>
    DateTime(DateTime.now().year, month, day);

/// Spotify with the Exportify package in: step 1 done, step 2 open.
OnboardingState _savedIn({DateTime? markedRequestedAt}) => onboardingState(
  chosenService: 'spotify',
  markedRequestedAt: markedRequestedAt,
  sources: [
    musicSource(
      packages: ['spotify_exportify'],
      lastImportedAt: _thisYear(10, 12),
    ),
  ],
);

/// Apple with the library synced on 2 November and no history.
OnboardingState _appleSynced({List<MusicSource> more = const []}) =>
    onboardingState(
      chosenService: 'apple',
      hasLibrary: true,
      sources: [
        musicSource(source: 'apple_live', lastImportedAt: _thisYear(11, 2)),
        ...more,
      ],
    );

class _RunningSync extends LibrarySyncNotifier {
  @override
  SyncState build() => const SyncRunning(0.42);
}

class _FailedSync extends LibrarySyncNotifier {
  @override
  SyncState build() => const SyncFailed('boom');
}

/// Pumps a few frames: a running sync's progress never settles.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'renders the eight request steps, word for word, with the address as a link',
    (tester) async {
      final links = FakeLinkOpener();
      final listening = FakeListeningApi(onboarding: _savedIn());
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, links: links),
        const SpotifyRequestScreen(),
      );

      // Pushed from the Library tab, the screen is "Add your music"; the
      // gate's own copy is pinned by its own test below.
      expect(find.text('Add your music'), findsOneWidget);
      expect(find.byKey(const Key('link-spotify-privacy')), findsNothing);
      await openDeeper(tester);
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
    'not added: step 1 is the three numbered rows over Open Exportify and '
    'Choose files; step 2 waits',
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

      expect(find.text('Saved music'), findsOneWidget);
      expect(exportifyQuickStartSteps, hasLength(3));
      for (var i = 0; i < exportifyQuickStartSteps.length; i++) {
        expect(find.text(exportifyQuickStartSteps[i]), findsOneWidget);
      }
      expect(
        tester
            .widget<TapeButton>(find.byKey(const Key('open-exportify')))
            .label,
        'Open Exportify ↗',
      );
      expect(
        tester
            .widget<LabelChip>(find.byKey(const Key('choose-import-files')))
            .label,
        'Choose files',
      );
      // Step 2 waits, closed: a line and a small action, no fold row.
      expect(find.text('Request it from Spotify any time'), findsOneWidget);
      expect(
        tester
            .widget<TextAction>(find.byKey(SpotifyRequestScreen.goDeeperKey))
            .label,
        'How to request it',
      );
      expect(find.byKey(const Key('link-spotify-privacy')), findsNothing);
      expect(find.bySemanticsLabel('Spotify, Not added yet'), findsOneWidget);
      // Flush steps: no inset box anywhere.
      expect(find.byType(InsetGroup), findsNothing);
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
      final listening = FakeListeningApi(onboarding: _savedIn());
      listening.onPostFunnelEvent = (type) async {
        // The server derives markedRequestedAt from the event; the refetch
        // after the post sees it.
        listening.onboarding = _savedIn(markedRequestedAt: DateTime.now());
      };
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening, reminders: reminders),
        const SpotifyRequestScreen(),
      );
      await openDeeper(tester);
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
        onboarding: _savedIn(
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
      // Collapsed, the wait rides on the disclosure row itself.
      expect(find.text('Requested 2 days ago'), findsOneWidget);
      await openDeeper(tester);
      await tester.pumpAndSettle();
      expect(find.text('Requested 2 days ago'), findsOneWidget);
      expect(reminders.scheduled, isEmpty);
      expect(listening.funnelEvents, isEmpty);
    },
  );

  testWidgets('before saved music, a request already made is step 2\'s '
      'status', (tester) async {
    await pumpRequest(
      tester,
      onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(
            chosenService: 'spotify',
            markedRequestedAt: DateTime.now().subtract(
              const Duration(days: 2, hours: 3),
            ),
          ),
        ),
      ),
      const SpotifyRequestScreen(),
    );
    expect(find.text('Requested 2 days ago'), findsOneWidget);
    expect(find.text('Request it from Spotify any time'), findsNothing);
  });

  testWidgets('before saved music, the request steps are one tap away, so '
      "Home's waiting card can still lead to I've requested it", (
    tester,
  ) async {
    await pumpRequest(
      tester,
      onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
      ),
      const SpotifyRequestScreen(),
    );
    await openDeeper(tester);
    await tester.pumpAndSettle();
    expect(find.text('spotify.com/account/privacy'), findsOneWidget);
    expect(find.byKey(const Key('mark-requested')), findsOneWidget);
    // Folding it again brings the small action back.
    await openDeeper(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mark-requested')), findsNothing);
    expect(find.text('How to request it'), findsOneWidget);
    expectNativeControls(tester, find.byType(SpotifyRequestScreen));
  });

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

  testWidgets('renders in dark without overflowing, the white Spotify icon', (
    tester,
  ) async {
    final listening = FakeListeningApi(onboarding: _savedIn());
    await pumpRequest(
      tester,
      onboardingContainer(listening: listening),
      const SpotifyRequestScreen(),
      brightness: Brightness.dark,
    );

    expect(find.text('Add your music'), findsOneWidget);
    expect(find.byType(SpotifyIcon), findsOneWidget);
    await openDeeper(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mark-requested')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holds together at 200% text on a 320 pt screen', (tester) async {
    await pumpRequest(
      tester,
      onboardingContainer(
        listening: FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        ),
      ),
      const SpotifyRequestScreen(),
      textScale: 2,
      surface: const Size(320, 900),
    );
    expect(find.text(exportifyQuickStartSteps.first), findsOneWidget);
    expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    expect(tester.takeException(), isNull);

    await pumpRequest(
      tester,
      onboardingContainer(listening: FakeListeningApi(onboarding: _savedIn())),
      const SpotifyRequestScreen(),
      textScale: 2,
      surface: const Size(320, 900),
    );
    await openDeeper(tester);
    await tester.pumpAndSettle();
    expect(find.text('spotify.com/account/privacy'), findsOneWidget);
    expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    expect(tester.takeException(), isNull);
  });

  group('the Apple Music / Spotify toggle', () {
    int segmentOf(WidgetTester tester) => tester
        .widget<GlassSegmentedControl<int>>(
          find.byKey(SpotifyRequestScreen.segmentKey),
        )
        .value;

    testWidgets('the gate preselects Spotify and keeps its own copy', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        SpotifyRequestScreen(onDone: () {}),
      );

      expect(find.text('Bring your Spotify music'), findsOneWidget);
      expect(segmentOf(tester), SpotifyRequestScreen.spotifySegment);
      // The Apple segment is still there to switch to.
      expect(find.byKey(SpotifyRequestScreen.appleSegmentKey), findsOneWidget);
      expect(find.byKey(const Key('open-exportify')), findsOneWidget);
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    });

    testWidgets('it is the glass segmented control, on the left margin, '
        '22 pt above the header', (tester) async {
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(
            onboarding: onboardingState(chosenService: 'apple'),
          ),
        ),
        const SpotifyRequestScreen(),
      );

      final toggle = tester.getRect(
        find.byKey(SpotifyRequestScreen.segmentKey),
      );
      final header = tester.getRect(
        find.byKey(SpotifyRequestScreen.statusRowKey),
      );
      expect(toggle.left, moreOrLessEquals(header.left, epsilon: 0.5));
      expect(header.top - toggle.bottom, moreOrLessEquals(22, epsilon: 0.5));
    });

    testWidgets('a Spotify listener lands on the Spotify pane from Library', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      expect(segmentOf(tester), SpotifyRequestScreen.spotifySegment);
      expect(find.byKey(const Key('open-exportify')), findsOneWidget);
      expect(find.byKey(SpotifyRequestScreen.appleSyncKey), findsNothing);
    });

    testWidgets('everyone else lands on the Apple pane', (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'apple'),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      expect(segmentOf(tester), SpotifyRequestScreen.appleSegment);
      expect(find.byKey(SpotifyRequestScreen.appleSyncKey), findsOneWidget);
      expect(find.byKey(const Key('open-exportify')), findsNothing);
      final handle = tester.ensureSemantics();
      await tester.pump();
      final sync = tester
          .getSemantics(find.byKey(SpotifyRequestScreen.appleSyncKey))
          .getSemanticsData();
      expect(sync.label, 'Sync Apple Music');
      expect(sync.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    });

    testWidgets(
      'never synced: one tape Sync, the history file waits as a small action, '
      'and the Spotify segment swaps the pane over',
      (tester) async {
        final listening = FakeListeningApi(
          onboarding: onboardingState(chosenService: 'apple'),
        );
        await pumpRequest(
          tester,
          onboardingContainer(listening: listening),
          const SpotifyRequestScreen(),
        );

        expect(
          find.bySemanticsLabel('Apple Music, Not added yet'),
          findsOneWidget,
        );
        expect(find.byType(AppleMusicIcon), findsOneWidget);
        expect(
          tester
              .widget<TapeButton>(find.byKey(SpotifyRequestScreen.appleSyncKey))
              .label,
          'Sync Apple Music',
        );
        expect(find.text(appleSyncIntro), findsOneWidget);
        expect(find.text('After your library, or any time'), findsOneWidget);
        expect(
          tester
              .widget<TextAction>(find.byKey(const Key('choose-apple-files')))
              .label,
          'Choose file',
        );
        expect(find.byKey(SpotifyRequestScreen.goDeeperKey), findsNothing);

        await tester.tap(find.byKey(SpotifyRequestScreen.appleSyncKey));
        await tester.pumpAndSettle();
        expect(find.byType(LibrarySyncDialog), findsOneWidget);
        expect(find.text(LibrarySyncDialog.firstTitle), findsOneWidget);
        await tester.tap(find.byKey(LibrarySyncDialog.cancelKey));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(SpotifyRequestScreen.spotifySegmentKey));
        await tester.pumpAndSettle();
        expect(segmentOf(tester), SpotifyRequestScreen.spotifySegment);
        expect(find.byKey(const Key('open-exportify')), findsOneWidget);
        expect(find.byKey(SpotifyRequestScreen.appleSyncKey), findsNothing);
        expect(find.byType(SpotifyIcon), findsOneWidget);
      },
    );

    testWidgets(
      'synced: the sync icon on step 1, and the Choose button only inside the '
      'fold, after the five steps',
      (tester) async {
        final listening = FakeListeningApi(onboarding: _appleSynced());
        await pumpRequest(
          tester,
          onboardingContainer(listening: listening),
          const SpotifyRequestScreen(),
        );
        expect(
          find.bySemanticsLabel('Apple Music, 1 of 2 added'),
          findsOneWidget,
        );
        expect(find.text('Synced 2 Nov'), findsOneWidget);
        // An icon now, with a 44 pt target and its name for VoiceOver.
        final sync = find.byKey(SpotifyRequestScreen.appleSyncKey);
        expect(
          find.descendant(of: sync, matching: find.byType(Icon)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sync, matching: find.text('Sync Apple Music')),
          findsNothing,
        );
        expect(tester.getSize(sync).width, greaterThanOrEqualTo(44));
        expect(tester.getSize(sync).height, greaterThanOrEqualTo(44));
        expect(find.bySemanticsLabel('Sync Apple Music'), findsOneWidget);

        expect(find.text(appleHistoryIntro), findsOneWidget);
        expect(find.text('Get your Apple file'), findsOneWidget);
        expect(find.text('From privacy.apple.com'), findsOneWidget);
        expect(find.byKey(const Key('choose-apple-files')), findsNothing);
        expect(find.byKey(const Key('link-apple-privacy')), findsNothing);

        await openDeeper(tester);
        await tester.pumpAndSettle();
        expect(find.text('Request it, then choose it'), findsOneWidget);
        expect(appleRequestSteps, hasLength(5));
        for (var i = 1; i <= 5; i++) {
          expect(find.text('$i.'), findsOneWidget);
        }
        expect(find.text('privacy.apple.com'), findsNWidgets(2));
        expect(
          find.textContaining('Apple Media Services information'),
          findsOneWidget,
        );
        final choose = find.byKey(const Key('choose-apple-files'));
        expect(tester.widget(choose), isA<TapeButton>());
        // After the steps, so VoiceOver reaches them first.
        expect(
          tester.getRect(choose).top,
          greaterThan(tester.getRect(find.text('5.')).bottom),
        );
        // Counts only: the pane never promises to show what it read.
        expect(find.text(appleFileNote), findsOneWidget);
        expectNativeControls(tester, find.byType(SpotifyRequestScreen));

        await tester.ensureVisible(sync);
        await tester.pumpAndSettle();
        await tester.tap(sync);
        await tester.pumpAndSettle();
        expect(find.text(LibrarySyncDialog.resyncTitle), findsOneWidget);
      },
    );

    testWidgets('each step is one semantics container that says where it '
        'stands', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(onboarding: _appleSynced()),
        ),
        const SpotifyRequestScreen(),
      );
      expect(
        find.bySemanticsLabel('Step 1, Library, done, Synced 2 Nov'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Step 2, Listening history, optional, to do'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a sync under way: its percent and a progress bar, no action', (
      tester,
    ) async {
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(onboarding: _appleSynced()),
          extra: [librarySyncProvider.overrideWith(_RunningSync.new)],
        ),
        const SpotifyRequestScreen(),
        settle: false,
      );
      await _frames(tester);

      expect(find.textContaining('Syncing… 42%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byKey(SpotifyRequestScreen.appleSyncKey), findsNothing);
    });

    testWidgets('a failed sync: the amber step and the same sync icon', (
      tester,
    ) async {
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(onboarding: _appleSynced()),
          extra: [librarySyncProvider.overrideWith(_FailedSync.new)],
        ),
        const SpotifyRequestScreen(),
      );

      expect(find.text("Sync didn't finish"), findsOneWidget);
      expect(find.text('!'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(SpotifyRequestScreen.appleSyncKey),
          matching: find.byType(Icon),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'at 2x text on a 320 pt phone the step action drops under the status '
      'and keeps its 44 pt target',
      (tester) async {
        await pumpRequest(
          tester,
          onboardingContainer(
            listening: FakeListeningApi(onboarding: _appleSynced()),
          ),
          const SpotifyRequestScreen(),
          brightness: Brightness.dark,
          textScale: 2,
          surface: const Size(320, 1400),
        );

        final status = tester.getRect(find.text('Synced 2 Nov'));
        final action = tester.getRect(
          find.byKey(SpotifyRequestScreen.appleSyncKey),
        );
        expect(action.top, greaterThanOrEqualTo(status.bottom));
        expect(action.height, greaterThanOrEqualTo(44));
        // The header stacks: the count under the name, not squeezed beside.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('history added: All in, Replace and a quiet Remove', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: _appleSynced(
          more: [
            musicSource(
              source: 'apple_export',
              lastImportedAt: _thisYear(10, 28),
              ledgerFrom: '2019-03-01',
              ledgerTo: '2026-10-20',
            ),
          ],
        ),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      expect(find.bySemanticsLabel('Apple Music, All in'), findsOneWidget);
      expect(find.text('Added 28 Oct · 2019 – 2026'), findsOneWidget);
      expect(
        tester
            .widget<TextAction>(find.byKey(const Key('choose-apple-files')))
            .label,
        'Replace',
      );
      final remove = tester.widget<TextAction>(
        find.byKey(const Key('remove-apple_export')),
      );
      expect(remove.label, 'Remove');
      expect(remove.quiet, isTrue);
      expect(find.byKey(SpotifyRequestScreen.goDeeperKey), findsNothing);

      await tester.tap(find.byKey(const Key('remove-apple_export')));
      await tester.pumpAndSettle();
      expect(find.text('Remove Apple Music · export?'), findsOneWidget);
      expect(
        find.textContaining('Your synced Apple Music library stays'),
        findsOneWidget,
      );
    });

    testWidgets('saved music in: Import again and Remove on step 1, the '
        'Exportify block gone, step 2 open', (tester) async {
      final listening = FakeListeningApi(onboarding: _savedIn());
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      expect(find.bySemanticsLabel('Spotify, 1 of 2 added'), findsOneWidget);
      expect(find.text('Imported 12 Oct'), findsOneWidget);
      expect(
        tester
            .widget<TextAction>(
              find.byKey(SpotifyRequestScreen.spotifyImportAgainKey),
            )
            .label,
        'Import again',
      );
      expect(find.byKey(const Key('remove-spotify_export')), findsOneWidget);
      expect(find.byKey(const Key('open-exportify')), findsNothing);
      expect(find.text(spotifyHistoryIntro), findsOneWidget);
      expect(find.text('How to request it'), findsOneWidget);
      expect(find.text('8 steps'), findsOneWidget);
      expect(find.byKey(const Key('choose-import-files')), findsOneWidget);
      expectNativeControls(tester, find.byType(SpotifyRequestScreen));
    });

    testWidgets('both in: All in, and one Remove for the one export', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          sources: [
            musicSource(
              packages: ['spotify_exportify', 'spotify_extended'],
              lastImportedAt: _thisYear(10, 18),
              ledgerFrom: '2016-01-04',
              ledgerTo: '2026-10-01',
            ),
          ],
        ),
      );
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      expect(find.bySemanticsLabel('Spotify, All in'), findsOneWidget);
      expect(find.text('Imported 18 Oct · 2016 – 2026'), findsOneWidget);
      expect(
        find.byKey(SpotifyRequestScreen.spotifyImportAgainKey),
        findsOneWidget,
      );
      expect(
        find.byKey(SpotifyRequestScreen.spotifyHistoryImportAgainKey),
        findsOneWidget,
      );
      expect(find.byKey(const Key('remove-spotify_export')), findsOneWidget);
      expect(find.byKey(SpotifyRequestScreen.goDeeperKey), findsNothing);
    });

    testWidgets(
      'Open Exportify and Choose files spread across one row at 1x and stack '
      'at 2x',
      (tester) async {
        final listening = FakeListeningApi(
          onboarding: onboardingState(chosenService: 'spotify'),
        );
        // The default surface, not a phone's: the test font draws every
        // glyph one em wide, so both labels measure about twice what SF gives
        // them on the device. The pair sharing a row on a 390 pt phone is the
        // simulator's job (smoke round four captures); what is pinned here is
        // that they share one when they fit, and stack when they do not.
        await pumpRequest(
          tester,
          onboardingContainer(listening: listening),
          const SpotifyRequestScreen(),
        );

        final row = tester.getRect(
          find.byKey(SpotifyRequestScreen.exportifyRowKey),
        );
        var button = tester.getRect(find.byKey(const Key('open-exportify')));
        var chip = tester.getRect(find.byKey(const Key('choose-import-files')));
        // Spread to both edges, not huddled on the left (smoke round five,
        // note 2).
        expect(button.left, moreOrLessEquals(row.left, epsilon: 0.5));
        expect(chip.right, moreOrLessEquals(row.right, epsilon: 0.5));
        expect(chip.left, greaterThan(button.right));
        expect(chip.center.dy, moreOrLessEquals(button.center.dy, epsilon: 1));

        await pumpRequest(
          tester,
          onboardingContainer(
            listening: FakeListeningApi(
              onboarding: onboardingState(chosenService: 'spotify'),
            ),
          ),
          const SpotifyRequestScreen(),
          textScale: 2,
          surface: const Size(320, 1400),
        );
        button = tester.getRect(find.byKey(const Key('open-exportify')));
        chip = tester.getRect(find.byKey(const Key('choose-import-files')));
        expect(chip.top, greaterThanOrEqualTo(button.bottom));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Remove (the September 4 removal flow)', () {
    testWidgets('confirms with the copy that says what goes and what stays, '
        'then deletes and refreshes', (tester) async {
      final listening = FakeListeningApi(onboarding: _savedIn());
      listening.onDeleteSource = (source) async {
        listening.onboarding = onboardingState(chosenService: 'spotify');
        return const DeleteSourceResult(
          deletedDays: 0,
          deletedTracks: 226,
          unlibraried: 214,
        );
      };
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );
      final before = listening.getOnboardingCalls;

      await tester.tap(find.byKey(const Key('remove-spotify_export')));
      await tester.pumpAndSettle();
      expect(find.text('Remove Spotify · saved music?'), findsOneWidget);
      expect(
        find.text(
          'Deletes your listening history, liked songs, artists, and playlists from Mixtape. '
          'The DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
        ),
        findsOneWidget,
      );
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('remove-keep')));
      await tester.pumpAndSettle();
      expect(listening.deletedSources, isEmpty);

      await tester.tap(find.byKey(const Key('remove-spotify_export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();

      expect(listening.deletedSources, ['spotify_export']);
      expect(listening.getOnboardingCalls, before + 1);
      expect(find.byKey(const Key('open-exportify')), findsOneWidget);
    });

    testWidgets('a failed removal keeps the step and says so', (tester) async {
      final listening = FakeListeningApi(onboarding: _savedIn());
      listening.onDeleteSource = (_) async => throw StateError('boom');
      await pumpRequest(
        tester,
        onboardingContainer(listening: listening),
        const SpotifyRequestScreen(),
      );

      await tester.tap(find.byKey(const Key('remove-spotify_export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('Imported 12 Oct'), findsOneWidget);
      expect(find.text("couldn't remove — try again"), findsOneWidget);
    });
  });

  group('Choose files goes straight to the picker (smoke round seven)', () {
    testWidgets('the chip picks with no sheet in between, and a dismissed '
        'picker leaves nothing on screen', (tester) async {
      final picker = FakeArchivePicker();
      final service = FakeImportService();
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(
            onboarding: onboardingState(chosenService: 'spotify'),
          ),
          picker: picker,
          importService: service,
        ),
        const SpotifyRequestScreen(),
      );

      await tester.tap(find.byKey(const Key('choose-import-files')));
      await tester.pumpAndSettle();

      expect(picker.picks, 1, reason: 'the picker opened straight away');
      expect(find.byType(ImportSheet), findsNothing);
      expect(service.inspected, isEmpty);
    });

    testWidgets('a chosen file brings the sheet up on the reading step', (
      tester,
    ) async {
      final picker = FakeArchivePicker(extendedArchive);
      final service = FakeImportService()..holdInspect = true;
      await pumpRequest(
        tester,
        onboardingContainer(
          listening: FakeListeningApi(
            onboarding: onboardingState(chosenService: 'spotify'),
          ),
          picker: picker,
          importService: service,
        ),
        const SpotifyRequestScreen(),
      );

      await tester.tap(find.byKey(const Key('choose-import-files')));
      // Not settled: the spinner over a file still being read never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ImportSheet), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.textContaining('my_spotify_data_extended.zip'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ImportSheet),
          matching: find.text('Choose files'),
        ),
        findsNothing,
        reason: 'the sheet has no idle step of its own',
      );
    });
  });
}
