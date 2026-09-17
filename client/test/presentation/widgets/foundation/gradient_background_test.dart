import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/gradient_background.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
  List<Color>? artworkColors,
  Widget child = const SizedBox.expand(key: Key('child')),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: GradientBackground(artworkColors: artworkColors, child: child),
    ),
  );
}

GradientBackgroundPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(GradientBackground),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter
        as GradientBackgroundPainter;

void _expectGlow(
  GlowTint glow, {
  required Color color,
  required Alignment center,
  required double radiusX,
  required double radiusY,
}) {
  expect(glow.color, color);
  expect(glow.center, center);
  expect(glow.radiusX, radiusX);
  expect(glow.radiusY, radiusY);
}

void main() {
  const sizes = <String, Size>{
    '320x568': Size(320, 568),
    '768x1024': Size(768, 1024),
  };

  group('GradientBackground', () {
    for (final entry in sizes.entries) {
      testWidgets('renders at ${entry.key} without exceptions', (tester) async {
        await _pump(tester, size: entry.value, theme: MixtapeTheme.light());

        expect(tester.takeException(), isNull);
        expect(find.byType(GradientBackground), findsOneWidget);
      });

      testWidgets('lays the child out to the full size at ${entry.key}', (
        tester,
      ) async {
        await _pump(tester, size: entry.value, theme: MixtapeTheme.light());

        expect(tester.getSize(find.byKey(const Key('child'))), entry.value);
      });
    }

    testWidgets('does not overflow with a tall child', (tester) async {
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.light(),
        child: const SizedBox(key: Key('child'), width: 320, height: 568),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('repaints when the theme changes to dark', (tester) async {
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.light(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.dark(),
          home: const GradientBackground(
            child: SizedBox.expand(key: Key('child')),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('child')), findsOneWidget);
    });

    testWidgets('renders the artwork-colour variant', (tester) async {
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.dark(),
        artworkColors: const [Color(0xFF3355AA), Color(0xFFAA5533)],
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('child'))),
        const Size(320, 568),
      );
    });

    testWidgets('paints the token base gradient', (tester) async {
      for (final theme in [MixtapeTheme.light(), MixtapeTheme.dark()]) {
        await _pump(tester, size: const Size(320, 568), theme: theme);
        // MaterialApp lerps its theme extensions; settle before reading them.
        await tester.pumpAndSettle();
        final tokens = theme.extension<MixtapeTokens>()!;
        expect(_painter(tester).base, tokens.backgroundGradient);
      }
    });

    testWidgets('paints the three token glows in light and dark', (
      tester,
    ) async {
      for (final theme in [MixtapeTheme.light(), MixtapeTheme.dark()]) {
        await _pump(tester, size: const Size(320, 568), theme: theme);
        await tester.pumpAndSettle();
        final tokens = theme.extension<MixtapeTokens>()!;
        final glows = _painter(tester).glows;

        expect(glows, hasLength(3));
        expect(glows, [tokens.violetGlow, tokens.pinkGlow, tokens.blueGlow]);
        // The board's geometry, spelled out rather than taken on trust.
        _expectGlow(
          glows[0],
          color: tokens.violetGlow.color,
          center: const Alignment(0, 1.16),
          radiusX: 0.9,
          radiusY: 0.45,
        );
        _expectGlow(
          glows[1],
          color: tokens.pinkGlow.color,
          center: tokens.pinkGlow.center,
          radiusX: 0.6,
          radiusY: 0.35,
        );
        _expectGlow(
          glows[2],
          color: tokens.blueGlow.color,
          center: tokens.blueGlow.center,
          radiusX: 0.6,
          radiusY: 0.35,
        );
      }
    });

    testWidgets('artwork colours replace the glows with the approved pair', (
      tester,
    ) async {
      const artwork = [Color(0xFF3355AA), Color(0xFFAA5533)];
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.dark(),
        artworkColors: artwork,
      );

      final painter = _painter(tester);
      expect(
        painter.base,
        MixtapeTokens.dark.backgroundGradient,
        reason: 'the artwork variant keeps the same base fall',
      );
      expect(painter.glows, hasLength(2));
      _expectGlow(
        painter.glows[0],
        color: artwork[0].withValues(alpha: 0.55),
        center: const Alignment(-0.4, -0.5),
        radiusX: 0.9,
        radiusY: 0.6,
      );
      _expectGlow(
        painter.glows[1],
        color: artwork[1].withValues(alpha: 0.40),
        center: const Alignment(0.6, 0.6),
        radiusX: 0.8,
        radiusY: 0.6,
      );
    });

    testWidgets('a single artwork colour keeps the token glows', (
      tester,
    ) async {
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.light(),
        artworkColors: const [Color(0xFF3355AA)],
      );

      expect(_painter(tester).glows, hasLength(3));
    });

    testWidgets('the glow falloff reaches transparent at 70%', (tester) async {
      expect(GradientBackgroundPainter.falloffStops, const [0, 0.7]);
    });

    testWidgets('does not clip its children', (tester) async {
      await _pump(
        tester,
        size: const Size(320, 568),
        theme: MixtapeTheme.light(),
      );

      final stack = tester.widget<Stack>(
        find.descendant(
          of: find.byType(GradientBackground),
          matching: find.byType(Stack),
        ),
      );
      expect(stack.clipBehavior, Clip.none);
    });
  });
}
