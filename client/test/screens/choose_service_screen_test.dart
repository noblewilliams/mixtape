import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/choose_service_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onApple,
  VoidCallback? onSpotify,
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
