// The composer's prism level meter (`.listen i` in
// `docs/mockups/2026-09-17-mobile-home-states.html`, frame V1).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/voice_level_meter.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    double level, {
    bool reduceMotion = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: MixtapeTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Center(child: VoiceLevelMeter(level: level)),
        ),
      ),
    ),
  );

  List<double> heights(WidgetTester tester) => [
    for (var i = 0; i < VoiceLevelMeter.barHeights.length; i++)
      tester.getSize(find.byKey(VoiceLevelMeter.barKey(i))).height,
  ];

  testWidgets('five prism bars ride the amplitude', (tester) async {
    await render(tester, 1);
    expect(heights(tester), VoiceLevelMeter.barHeights);
    for (var i = 0; i < VoiceLevelMeter.barHeights.length; i++) {
      expect(
        tester.getSize(find.byKey(VoiceLevelMeter.barKey(i))).width,
        VoiceLevelMeter.barWidth,
      );
    }
    final bar = tester.widget<AnimatedContainer>(
      find.byKey(VoiceLevelMeter.barKey(0)),
    );
    final decoration = bar.decoration! as BoxDecoration;
    expect(
      (decoration.gradient! as LinearGradient).colors,
      MixtapeTokens.light.prism.take(5),
    );
    expect(decoration.borderRadius, const BorderRadius.all(Radius.circular(2)));

    await render(tester, 0.5);
    await tester.pumpAndSettle();
    expect(heights(tester), const [7.0, 10.0, 4.5, 8.0, 5.5]);
  });

  testWidgets('a quiet room still shows a floor of 4 pt', (tester) async {
    await render(tester, 0);
    await tester.pumpAndSettle();
    expect(heights(tester), everyElement(VoiceLevelMeter.minBarHeight));
  });

  testWidgets('samples animate over 120 ms', (tester) async {
    await render(tester, 0);
    await tester.pumpAndSettle();
    await render(tester, 1);
    await tester.pump(const Duration(milliseconds: 60));
    final midway = tester.getSize(find.byKey(VoiceLevelMeter.barKey(1))).height;
    expect(midway, greaterThan(VoiceLevelMeter.minBarHeight));
    expect(midway, lessThan(20));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(VoiceLevelMeter.barKey(1))).height, 20);
    expect(
      tester
          .widget<AnimatedContainer>(find.byKey(VoiceLevelMeter.barKey(1)))
          .duration,
      VoiceLevelMeter.sample,
    );
  });

  testWidgets('reduced motion holds the bars at mid height', (tester) async {
    await render(tester, 1, reduceMotion: true);
    expect(heights(tester), const [7.0, 10.0, 4.5, 8.0, 5.5]);
    await render(tester, 0, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(heights(tester), const [7.0, 10.0, 4.5, 8.0, 5.5]);
    expect(
      tester
          .widget<AnimatedContainer>(find.byKey(VoiceLevelMeter.barKey(0)))
          .duration,
      Duration.zero,
    );
  });

  testWidgets('the meter is not spoken; the field carries the state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await render(tester, 0.6);
    expect(
      find.ancestor(
        of: find.byKey(VoiceLevelMeter.barKey(0)),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
