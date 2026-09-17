import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_surface.dart';

Future<MixtapeTokens> _pump(
  WidgetTester tester,
  Widget surface, {
  ThemeData? theme,
}) async {
  MixtapeTokens? tokens;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? MixtapeTheme.light(),
      home: Builder(
        builder: (context) {
          tokens = context.tokens;
          return Center(child: surface);
        },
      ),
    ),
  );
  return tokens!;
}

Iterable<BoxDecoration> _decorations(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(FrostedSurface),
        matching: find.byType(DecoratedBox),
      ),
    )
    .map((box) => box.decoration)
    .whereType<BoxDecoration>();

Future<void> _pumpSized(
  WidgetTester tester, {
  required Size size,
  required Widget child,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(theme: MixtapeTheme.light(), home: child),
  );
}

void main() {
  const child = SizedBox(key: Key('child'), width: 120, height: 60);

  group('FrostedSurface', () {
    testWidgets('blurs by default', (tester) async {
      await _pump(tester, const FrostedSurface(child: child));

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byKey(const Key('child')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('applies the blur sigma', (tester) async {
      await _pump(tester, const FrostedSurface(blurSigma: 8, child: child));

      final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
      expect(filter.filter, equals(ImageFilter.blur(sigmaX: 8, sigmaY: 8)));
    });

    testWidgets('opaque mode drops the blur and paints scrimBase', (
      tester,
    ) async {
      final tokens = await _pump(
        tester,
        const FrostedSurface(opaque: true, child: child),
      );

      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        _decorations(tester).map((d) => d.color),
        contains(tokens.scrimBase),
      );
    });

    testWidgets('reduced transparency drops the blur', (tester) async {
      final tokens = await _pump(
        tester,
        const FrostedSurfaceMode(
          reduceTransparency: true,
          child: FrostedSurface(child: child),
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        _decorations(tester).map((d) => d.color),
        contains(tokens.scrimBase),
      );
    });

    testWidgets('FrostedSurfaceMode.of defaults to false when absent', (
      tester,
    ) async {
      late bool reduce;
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) {
              reduce = FrostedSurfaceMode.of(context).reduceTransparency;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(reduce, isFalse);
    });

    testWidgets('applies the border radius through ClipRRect', (tester) async {
      const radius = BorderRadius.all(Radius.circular(18));
      await _pump(
        tester,
        const FrostedSurface(borderRadius: radius, child: child),
      );

      final clips = tester.widgetList<ClipRRect>(
        find.descendant(
          of: find.byType(FrostedSurface),
          matching: find.byType(ClipRRect),
        ),
      );
      expect(clips, isNotEmpty);
      expect(clips.map((clip) => clip.borderRadius), contains(radius));
    });

    testWidgets('paints the tint when given one', (tester) async {
      await _pump(
        tester,
        const FrostedSurface(tint: Color(0x8812AB34), child: child),
      );

      expect(
        _decorations(tester).map((d) => d.color),
        contains(const Color(0x8812AB34)),
      );
    });

    testWidgets('hairline: false removes the border', (tester) async {
      final withHairline = await _pump(
        tester,
        const FrostedSurface(child: child),
      );
      expect(
        _decorations(tester).map((d) => d.border).whereType<Border>(),
        isNotEmpty,
        reason: 'the default surface carries a ${withHairline.hairline} edge',
      );

      await _pump(tester, const FrostedSurface(hairline: false, child: child));

      expect(
        _decorations(tester).map((d) => d.border).whereType<Border>(),
        isEmpty,
      );
    });

    testWidgets('shadow: false removes the box shadow', (tester) async {
      await _pump(tester, const FrostedSurface(child: child));
      expect(
        _decorations(tester).where((d) => (d.boxShadow ?? []).isNotEmpty),
        isNotEmpty,
      );

      await _pump(tester, const FrostedSurface(shadow: false, child: child));
      expect(
        _decorations(tester).where((d) => (d.boxShadow ?? []).isNotEmpty),
        isEmpty,
      );
    });

    testWidgets('keeps the glassHighlight top line when blurred', (
      tester,
    ) async {
      final tokens = await _pump(tester, const FrostedSurface(child: child));

      expect(
        _decorations(tester).map((d) => d.color),
        contains(tokens.glassHighlight),
      );
    });

    testWidgets('drops the glassHighlight top line when opaque', (
      tester,
    ) async {
      final tokens = await _pump(
        tester,
        const FrostedSurface(opaque: true, child: child),
      );

      expect(
        _decorations(tester).map((d) => d.color),
        isNot(contains(tokens.glassHighlight)),
      );
    });

    for (final width in [320.0, 768.0]) {
      testWidgets('lays out inside a Column at ${width.toInt()} wide', (
        tester,
      ) async {
        await _pumpSized(
          tester,
          size: Size(width, 640),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [FrostedSurface(child: child)],
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(tester.getSize(find.byType(FrostedSurface)).height, 60);
      });

      testWidgets('lays out inside a Positioned at ${width.toInt()} wide', (
        tester,
      ) async {
        await _pumpSized(
          tester,
          size: Size(width, 640),
          child: const Stack(
            children: [
              Positioned(
                left: 12,
                right: 12,
                bottom: 24,
                child: FrostedSurface(child: child),
              ),
            ],
          ),
        );

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(FrostedSurface)).width, width - 24);
      });
    }

    testWidgets('renders in dark theme without exceptions', (tester) async {
      await _pump(
        tester,
        const FrostedSurface(child: child),
        theme: MixtapeTheme.dark(),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });
}
