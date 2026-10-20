// Step 1 of 3 and Step 2 of 3 (board frames B1, B2, B3).
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_method_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/doing_screen.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';

import 'first_run_harness.dart';

/// The counter's text and the progress fill's share of the line.
void expectStep(WidgetTester tester, int step) {
  expect(find.text('STEP $step OF 3'), findsOneWidget);
  final line = tester.getSize(find.byKey(StepScaffold.progressKey));
  final fill = tester.getSize(find.byKey(StepScaffold.progressFillKey));
  expect(line.height, 2);
  expect(fill.width, closeTo(line.width * step / 3, 0.5));
}

void main() {
  reduceMotion();

  group('Step 1 of 3, Which do you use?', () {
    testWidgets('counter, progress, copy and both services', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const ChooseServiceScreen());

      expectStep(tester, 1);
      expect(find.text('Which do you use?'), findsOneWidget);
      expect(
        find.text('Mixes get better when the DJ knows your music.'),
        findsOneWidget,
      );
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
      expect(find.byKey(TapeBackButton.defaultKey), findsOneWidget);
    });

    testWidgets('the page name carries the step; the counter is silent', (
      tester,
    ) async {
      final h = FirstRunHarness();
      final semantics = tester.ensureSemantics();
      await h.pump(tester, const ChooseServiceScreen());

      expect(
        find.bySemanticsLabel('Step 1 of 3, Which do you use?'),
        findsOneWidget,
      );
      final node = tester.getSemantics(find.byKey(StepScaffold.headlineKey));
      expect(node.label, 'Step 1 of 3, Which do you use?');
      expect(node.flagsCollection.isHeader, isTrue);
      expect(find.bySemanticsLabel('STEP 1 OF 3'), findsNothing);
      semantics.dispose();
    });

    testWidgets('Skip for now and Back are actionable by VoiceOver', (
      tester,
    ) async {
      final h = FirstRunHarness();
      final handle = tester.ensureSemantics();
      await h.pump(tester, const ChooseServiceScreen());

      for (final label in ['Skip for now', 'Back']) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: '$label: a node with no tap action cannot be activated',
        );
        expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      }
      tester.semantics.tap(find.semantics.byLabel('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistsScreen), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Skip for now goes to Who do you love?', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const ChooseServiceScreen());

      await tester.tap(find.byKey(ChooseServiceScreen.skipKey));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistsScreen), findsOneWidget);
      expect(
        tester.widget<ArtistsScreen>(find.byType(ArtistsScreen)).prompt,
        isNull,
      );
      // Path A pages carry no counter.
      expect(find.byKey(StepScaffold.counterKey), findsNothing);
    });

    testWidgets('each service opens its Step 2', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const ChooseServiceScreen());

      await tester.tap(find.byKey(ChooseServiceScreen.appleKey));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChooseMethodScreen>(find.byType(ChooseMethodScreen))
            .service,
        MusicService.apple,
      );

      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();
      expect(find.byType(ChooseMethodScreen), findsNothing);

      await tester.tap(find.byKey(ChooseServiceScreen.spotifyKey));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChooseMethodScreen>(find.byType(ChooseMethodScreen))
            .service,
        MusicService.spotify,
      );
    });

    testWidgets('from Library there is no Skip', (tester) async {
      final h = FirstRunHarness();
      await h.pump(
        tester,
        const ChooseServiceScreen(mode: AddMusicMode.library),
      );
      expectStep(tester, 1);
      expect(find.byKey(ChooseServiceScreen.skipKey), findsNothing);
    });
  });

  group('Step 2 of 3, How do you want to add it?', () {
    testWidgets('Apple: two methods and the Library line', (tester) async {
      final h = FirstRunHarness();
      final semantics = tester.ensureSemantics();
      await h.pump(
        tester,
        const ChooseMethodScreen(service: MusicService.apple),
      );

      expectStep(tester, 2);
      expect(
        find.bySemanticsLabel('Step 2 of 3, How do you want to add it?'),
        findsOneWidget,
      );
      expect(find.text('Sync my library'), findsOneWidget);
      expect(find.text('Upload an Apple export'), findsOneWidget);
      expect(find.text('You can add more later from Library.'), findsOneWidget);
      expect(find.text(ChooseMethodScreen.spotifyLine), findsNothing);
      semantics.dispose();
    });

    testWidgets('Spotify: the line and two methods', (tester) async {
      final h = FirstRunHarness();
      await h.pump(
        tester,
        const ChooseMethodScreen(service: MusicService.spotify),
      );

      expectStep(tester, 2);
      expect(
        find.text(
          'Exportify brings your playlists and likes. The data export adds '
          'what you actually played.',
        ),
        findsOneWidget,
      );
      expect(find.text('Exportify, a few minutes'), findsOneWidget);
      expect(find.text('Spotify data export, a few days'), findsOneWidget);
      expect(find.text('You can add more later from Library.'), findsOneWidget);
    });

    for (final (service, key, method) in [
      (
        MusicService.apple,
        ChooseMethodScreen.appleExportKey,
        AddMethod.appleExport,
      ),
      (
        MusicService.spotify,
        ChooseMethodScreen.exportifyKey,
        AddMethod.exportify,
      ),
      (
        MusicService.spotify,
        ChooseMethodScreen.spotifyExportKey,
        AddMethod.spotifyExport,
      ),
    ]) {
      testWidgets('${method.name} opens its Step 3', (tester) async {
        final h = FirstRunHarness();
        await h.pump(tester, ChooseMethodScreen(service: service));

        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
        expect(
          tester.widget<DoingScreen>(find.byType(DoingScreen)).method,
          method,
        );
        expectStep(tester, 3);
      });
    }
  });
}
