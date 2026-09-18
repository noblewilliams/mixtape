import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/choose_service_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onApple,
  VoidCallback? onSpotify,
  VoidCallback? onSignOut,
  VoidCallback? onSkip,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ChooseServiceScreen(
        onApple: onApple ?? () {},
        onSpotify: onSpotify ?? () {},
        onSignOut: onSignOut ?? () {},
        onSkip: onSkip ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('two flush rows offer the services with one-line explanations', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Which do you use?'), findsOneWidget);
    expect(find.byType(FlushRow), findsNWidgets(2));
    expect(find.text('Apple Music'), findsOneWidget);
    expect(find.text('Spotify'), findsOneWidget);
    expect(find.byKey(ChooseServiceScreen.appleMarkKey), findsOneWidget);
    expect(find.byKey(ChooseServiceScreen.spotifyMarkKey), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    expect(
      tester.getSize(find.byKey(ChooseServiceScreen.appleMarkKey)).width,
      ChooseServiceScreen.markSize,
    );
    expect(
      tester.getSize(find.byKey(ChooseServiceScreen.spotifyMarkKey)).width,
      ChooseServiceScreen.markSize,
    );
  });

  testWidgets('each row reports its choice once', (tester) async {
    var apple = 0;
    var spotify = 0;
    await _pump(tester, onApple: () => apple++, onSpotify: () => spotify++);

    await tester.tap(find.byKey(const Key('choose-apple')));
    await tester.pump();
    expect(apple, 1);
    expect(spotify, 0);

    await tester.tap(find.byKey(const Key('choose-spotify')));
    await tester.pump();
    expect(spotify, 1);
  });

  testWidgets('the intro line is meta-sized muted type', (tester) async {
    await _pump(tester);

    final intro = tester.widget<Text>(find.text(ChooseServiceScreen.intro));
    expect(intro.style?.fontSize, MixtapeTokens.light.meta.fontSize);
    expect(intro.style?.fontSize, 12);
    expect(intro.style?.color, MixtapeTokens.light.muted);
    expect(intro.style?.height, closeTo(1.4, 0.001));
  });

  testWidgets("the Spotify row's subtitle is allowed a second line", (
    tester,
  ) async {
    await _pump(tester);

    final subtitle = tester.widget<Text>(
      find.text('Bring your saved music with an Exportify ZIP or CSV.'),
    );
    expect(subtitle.maxLines, 2);
  });

  testWidgets('the rows sit 32 pt below the intro line', (tester) async {
    await _pump(tester);

    final intro = tester.getRect(find.text(ChooseServiceScreen.intro));
    final firstRow = tester.getRect(find.byType(FlushRow).first);
    expect(firstRow.top - intro.bottom, moreOrLessEquals(32, epsilon: 0.5));
  });

  testWidgets('sign out and skip are offered and report once each', (
    tester,
  ) async {
    var signedOut = 0;
    var skipped = 0;
    await _pump(
      tester,
      onSignOut: () => signedOut++,
      onSkip: () => skipped++,
    );

    expect(find.byKey(ChooseServiceScreen.signOutKey), findsOneWidget);
    expect(find.byKey(ChooseServiceScreen.skipKey), findsOneWidget);
    expect(find.text(ChooseServiceScreen.skipNote), findsOneWidget);

    await tester.tap(find.byKey(ChooseServiceScreen.signOutKey));
    await tester.pump();
    expect(signedOut, 1);
    expect(skipped, 0);

    await tester.tap(find.byKey(ChooseServiceScreen.skipKey));
    await tester.pump();
    expect(skipped, 1);
    expect(signedOut, 1);
  });

  testWidgets('every control is one VoiceOver can activate', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    for (final finder in [
      find.byKey(const Key('choose-apple')),
      find.byKey(const Key('choose-spotify')),
      find.byKey(ChooseServiceScreen.signOutKey),
      find.byKey(ChooseServiceScreen.skipKey),
    ]) {
      expect(
        tester.getSemantics(finder).getSemanticsData().hasAction(
          SemanticsAction.tap,
        ),
        isTrue,
        reason: 'a node with no tap action cannot be activated by VoiceOver',
      );
    }

    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('choose service fits narrow 200% text in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(tester, scale: 2, brightness: brightness);

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('choose-spotify')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('choose-spotify')).hitTestable(),
        findsOneWidget,
      );
    });
  }
}
