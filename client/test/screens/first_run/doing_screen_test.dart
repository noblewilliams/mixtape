// Step 3 of 3, the doing page (board frames B4 to B7).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';

import '../../helpers/fake_import_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_method_screen.dart';
import 'package:mixtape/presentation/screens/first_run/doing_screen.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';

import 'first_run_harness.dart';

void main() {
  reduceMotion();

  group('Apple sync', () {
    testWidgets('signs in anonymously before the sync starts, then shows the '
        'live count with Done waiting', (tester) async {
      final h = FirstRunHarness();
      final hold = Completer<void>();
      h.auth.gate = hold;
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));

      expect(find.text('Syncing your library'), findsOneWidget);
      expect(find.text('STEP 3 OF 3'), findsOneWidget);
      expect(h.auth.anonymousSignIns, 1);
      expect(h.sync.runs, 0, reason: 'no sync before the session exists');

      hold.complete();
      await tester.pumpAndSettle();
      expect(h.container.read(authProvider), AuthStatus.session);
      expect(h.sync.runs, 1);

      h.sync.progress(612);
      await tester.pumpAndSettle();
      expect(find.text('612 songs so far'), findsOneWidget);
      expect(enabled(tester, DoingScreen.doneKey), isFalse);
      // Retry's slot is held but nothing is there to press.
      expect(find.text('Retry').hitTestable(), findsNothing);
    });

    testWidgets('done: the count, Done turns full and leads to the prompt '
        'page with the real count', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      h.sync.progress(612);
      await tester.pumpAndSettle();

      h.sync.done(1284);
      await tester.pumpAndSettle();
      expect(find.text('1,284 songs in.'), findsOneWidget);
      expect(enabled(tester, DoingScreen.doneKey), isTrue);

      await tester.tap(find.byKey(DoingScreen.doneKey));
      await tester.pumpAndSettle();
      final prompt = tester.widget<WelcomeScreen>(find.byType(WelcomeScreen));
      expect(prompt.isPrompt, isTrue);
      expect(prompt.songsIn, 1284);
      expect(find.text('1,284 songs in. Ask for anything.'), findsOneWidget);
    });

    testWidgets('failure keeps the count and offers Retry and Continue with '
        "what's in", (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      h.sync.progress(612);
      await tester.pumpAndSettle();
      h.sync.fail();
      await tester.pumpAndSettle();

      expect(find.text('Sync stopped at 612 songs.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text("Continue with what's in"), findsOneWidget);
      expect(find.byKey(DoingScreen.doneKey), findsNothing);

      await tester.tap(find.byKey(DoingScreen.retryKey));
      await tester.pumpAndSettle();
      expect(h.sync.runs, 2);
      expect(h.auth.anonymousSignIns, 1, reason: 'the session is reused');

      h.sync.fail();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(DoingScreen.continueKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<WelcomeScreen>(find.byType(WelcomeScreen)).songsIn,
        612,
      );
    });

    testWidgets(
      'a failure with nothing usable goes to Who do you love? first',
      (tester) async {
        final h = FirstRunHarness();
        await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
        h.sync.fail();
        await tester.pumpAndSettle();

        expect(find.text('Sync stopped at 0 songs.'), findsOneWidget);
        await tester.tap(find.byKey(DoingScreen.continueKey));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistsScreen), findsOneWidget);
      },
    );
    testWidgets('the count is announced at most once per ten seconds, and '
        'the last count before a pause still is', (tester) async {
      final h = FirstRunHarness();
      final semantics = tester.ensureSemantics();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      // The opening "0 songs so far" opened a window; let it close.
      expect(find.bySemanticsLabel('0 songs so far'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));

      h.sync.progress(100);
      await tester.pump();
      expect(find.bySemanticsLabel('100 songs so far'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      h.sync.progress(200);
      await tester.pump();
      // On screen at once; the live region waits for the window.
      expect(find.text('200 songs so far'), findsOneWidget);
      expect(find.bySemanticsLabel('100 songs so far'), findsOneWidget);
      expect(find.bySemanticsLabel('200 songs so far'), findsNothing);

      // No further progress: the window closing alone brings the label on.
      await tester.pump(const Duration(seconds: 9));
      expect(find.bySemanticsLabel('200 songs so far'), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure is announced once, as an alert', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      h.sync.progress(612);
      await tester.pumpAndSettle();
      tester.takeAnnouncements();

      h.sync.fail();
      await tester.pumpAndSettle();
      final announced = tester.takeAnnouncements();
      expect(announced, hasLength(1));
      expect(announced.single.message, 'Sync stopped at 612 songs.');
      expect(announced.single.assertiveness, Assertiveness.assertive);

      // A rebuild while still failed does not announce again.
      h.sync.fail();
      await tester.pumpAndSettle();
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('refused library access says so instead of the generic line', (
      tester,
    ) async {
      final h = FirstRunHarness();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      h.sync.deny();
      await tester.pumpAndSettle();

      expect(
        find.text('Music library access was denied. Enable it in Settings.'),
        findsOneWidget,
      );
      expect(find.textContaining('Sync stopped'), findsNothing);
    });

    testWidgets('a failure left from an earlier run does not show on entry', (
      tester,
    ) async {
      final h = FirstRunHarness();
      h.sync.initial = const SyncFailed('Sync failed. Try again.');
      final hold = Completer<void>();
      h.auth.gate = hold;
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));

      expect(find.textContaining('Sync stopped'), findsNothing);
      expect(find.text('Retry').hitTestable(), findsNothing);
      expect(find.text('0 songs so far'), findsOneWidget);

      hold.complete();
      await tester.pumpAndSettle();
      expect(h.sync.runs, 1);
      expect(find.textContaining('Sync stopped'), findsNothing);
    });

    testWidgets('remembers Apple Music once the listener exists', (
      tester,
    ) async {
      final h = FirstRunHarness();
      await h.pump(tester, const DoingScreen(method: AddMethod.appleSync));
      expect(h.auth.anonymousSignIns, 1);
      expect(await h.prefs.read('anon-1'), 'apple');
      // Apple posts nothing (the onboarding notifier's own rule).
      expect(h.listening.funnelEvents, isEmpty);
    });
  });

  testWidgets('Exportify: the three existing lines, Open Exportify leaves the '
      'app, and Choose files signs in before the picker', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const DoingScreen(method: AddMethod.exportify));

    expect(find.text('Export from Exportify'), findsOneWidget);
    for (final line in exportifyQuickStartSteps) {
      expect(find.text(line), findsOneWidget);
    }
    await tester.tap(find.byKey(DoingScreen.openExportifyKey));
    await tester.pump();
    expect(h.links.opened, [exportifyUrl]);
    expect(h.auth.anonymousSignIns, 0);

    await tester.tap(find.byKey(DoingScreen.chooseFilesKey));
    await tester.pumpAndSettle();
    expect(h.auth.anonymousSignIns, 1);
    expect(h.picker.picks, 1);
    // A dismissed picker leaves the listener here.
    expect(find.byType(DoingScreen), findsOneWidget);
  });

  testWidgets('Exportify posts chose_spotify once the listener exists', (
    tester,
  ) async {
    final h = FirstRunHarness();
    await h.pump(tester, const DoingScreen(method: AddMethod.exportify));
    await tester.tap(find.byKey(DoingScreen.chooseFilesKey));
    await tester.pumpAndSettle();
    expect(h.listening.funnelEvents, [FunnelEventType.choseSpotify]);
    expect(await h.prefs.read('anon-1'), 'spotify');
  });

  testWidgets('a cancelled picker over an earlier import result does not '
      'finish the step', (tester) async {
    final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
    final c = ProviderContainer(
      overrides: [
        ...h.overrides,
        listeningImportProvider.overrideWith(_StaleImport.new),
      ],
    );
    addTearDown(c.dispose);
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const DoingScreen(method: AddMethod.exportify),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.read(listeningImportProvider), isA<ImportDone>());

    await tester.tap(find.byKey(DoingScreen.chooseFilesKey));
    await tester.pumpAndSettle();

    expect(h.picker.picks, 1);
    expect(find.byType(DoingScreen), findsOneWidget);
    expect(find.byType(WelcomeScreen), findsNothing);
    expect(find.byType(ArtistsScreen), findsNothing);
  });

  testWidgets("Spotify data export: the existing steps, then I've requested "
      'it records the request and goes on to Who do you love?', (tester) async {
    final h = FirstRunHarness();
    await h.pump(tester, const DoingScreen(method: AddMethod.spotifyExport));

    expect(find.text('Request your data'), findsOneWidget);
    expect(
      find.textContaining('Scroll to', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Press', findRichText: true), findsWidgets);

    await tester.scrollUntilVisible(
      find.byKey(DoingScreen.requestedKey),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(DoingScreen.requestedKey));
    await tester.pumpAndSettle();

    expect(h.auth.anonymousSignIns, 1);
    expect(h.listening.funnelEvents, [
      FunnelEventType.choseSpotify,
      FunnelEventType.markedRequested,
    ]);
    expect(h.reminders.scheduled, [requestReminderDelay]);
    expect(find.byType(ArtistsScreen), findsOneWidget);
  });

  testWidgets('Apple export: the existing request steps and the picker', (
    tester,
  ) async {
    final h = FirstRunHarness();
    await h.pump(tester, const DoingScreen(method: AddMethod.appleExport));

    expect(find.text('Upload an Apple export'), findsOneWidget);
    expect(
      find.textContaining('Get a copy of your data', findRichText: true),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(DoingScreen.chooseFilesKey),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(DoingScreen.chooseFilesKey));
    await tester.pumpAndSettle();
    expect(h.auth.anonymousSignIns, 1);
    expect(h.picker.picks, 1);
  });
}

/// An import provider still holding a finished run from earlier.
class _StaleImport extends ListeningImportNotifier {
  @override
  ImportFlowState build() {
    super.build();
    return ImportDone(extendedArchive, extendedResult());
  }
}
