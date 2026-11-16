import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/tape_palette.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required ThemeData theme,
  bool disableAnimations = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  ),
);

CassetteTileState _state(WidgetTester tester) =>
    tester.state<CassetteTileState>(find.byType(CassetteTile));

CassettePainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(CassetteTile.paintKey)).painter
        as CassettePainter;

void main() {
  group('CassetteTile geometry', () {
    for (final width in <double>[22, 44, 60, 150]) {
      for (final entry in {
        'light': MixtapeTheme.light(),
        'dark': MixtapeTheme.dark(),
      }.entries) {
        testWidgets('paints at $width in ${entry.key}', (tester) async {
          await _pump(
            tester,
            CassetteTile(width: width, seedId: 'mix-$width'),
            theme: entry.value,
          );

          expect(tester.takeException(), isNull);
          // Height follows the 200x128 viewBox.
          expect(
            tester.getSize(find.byType(CassetteTile)),
            Size(width, width * 128 / 200),
          );
        });
      }
    }
  });

  group('CassetteTile case colour', () {
    test('the same id always gives the same case', () {
      expect(
        CassetteTile.caseColorFor('session-abc'),
        CassetteTile.caseColorFor('session-abc'),
      );
      expect(CassetteTile.caseColors, hasLength(5));
      expect(
        CassetteTile.caseColors.first,
        const Color(0xFF3F4851),
        reason: 'decorative brand tapes retain their neutral colours',
      );
    });

    test('ids spread across the whole set', () {
      final seen = {
        for (var i = 0; i < 300; i++) CassetteTile.caseColorFor('mix-$i'),
      };

      expect(seen, hasLength(48));
      expect(
        seen,
        containsAll(tapePalette.map((entry) => tapeColor(entry.$2))),
      );
    });

    testWidgets('caseColor overrides the seed', (tester) async {
      await _pump(
        tester,
        const CassetteTile(
          width: 60,
          seedId: 'session-abc',
          caseColor: Color(0xFF112233),
        ),
        theme: MixtapeTheme.light(),
      );

      expect(_painter(tester).caseColor, const Color(0xFF112233));
    });

    testWidgets('the seed reaches the painter', (tester) async {
      await _pump(
        tester,
        const CassetteTile(width: 60, seedId: 'session-abc'),
        theme: MixtapeTheme.light(),
      );

      expect(
        _painter(tester).caseColor,
        CassetteTile.caseColorFor('session-abc'),
      );
    });
  });

  group('CassetteTile hubs', () {
    testWidgets('still hubs under reduced motion', (tester) async {
      await _pump(
        tester,
        const CassetteTile(width: 60, spinning: true),
        theme: MixtapeTheme.light(),
        disableAnimations: true,
      );

      // The controller must never start: a ticking hub under reduced motion
      // would still burn frames even with the painted turn pinned to zero.
      expect(_state(tester).isSpinning, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(_state(tester).isSpinning, isFalse);
      expect(_painter(tester).turn, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning hubs advance while spinning', (tester) async {
      await _pump(
        tester,
        const CassetteTile(width: 60, spinning: true),
        theme: MixtapeTheme.light(),
      );

      expect(_state(tester).isSpinning, isTrue);
      expect(_painter(tester).turn, 0);
      await tester.pump(const Duration(milliseconds: 525));
      expect(_painter(tester).turn, greaterThan(0));
    });

    testWidgets('a still tile keeps the hubs at rest', (tester) async {
      await _pump(
        tester,
        const CassetteTile(width: 60),
        theme: MixtapeTheme.light(),
      );

      await tester.pump(const Duration(seconds: 2));

      expect(_state(tester).isSpinning, isFalse);
      expect(_painter(tester).turn, 0);
    });
  });

  group('CassetteTile crops (reel loader, 2026-11-16)', () {
    testWidgets('the icon crop is square and paints the app icon\'s window', (
      tester,
    ) async {
      await _pump(
        tester,
        const CassetteTile(width: 112, crop: CassetteCrop.icon),
        theme: MixtapeTheme.dark(),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CassetteTile)), const Size(112, 112));
      expect(_painter(tester).viewport, const Rect.fromLTWH(108, 22, 78, 78));
    });

    testWidgets('the row crop keeps a tape\'s own size, zoomed on a hub', (
      tester,
    ) async {
      await _pump(
        tester,
        const CassetteTile(width: 68, crop: CassetteCrop.row, shadow: true),
        theme: MixtapeTheme.light(),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(CassetteTile)),
        const Size(68, 68 * 128 / 200),
      );
      expect(_painter(tester).viewport, const Rect.fromLTWH(96, 29, 100, 64));
    });

    testWidgets('a close-up paints no label', (tester) async {
      await _pump(
        tester,
        const CassetteTile(
          width: 68,
          crop: CassetteCrop.row,
          title: 'Sunday kitchen soul',
        ),
        theme: MixtapeTheme.light(),
      );
      // Only the foot of its letters would show at the crop's top edge.
      expect(_painter(tester).paintsLabel, isFalse);
    });

    testWidgets('the whole cassette is the default', (tester) async {
      await _pump(
        tester,
        const CassetteTile(width: 68),
        theme: MixtapeTheme.light(),
      );
      expect(_painter(tester).viewport, CassetteCrop.whole.viewport);
    });

    testWidgets('a crop turns, and stands still under reduced motion', (
      tester,
    ) async {
      await _pump(
        tester,
        const CassetteTile(width: 34, crop: CassetteCrop.icon, spinning: true),
        theme: MixtapeTheme.light(),
      );
      expect(_state(tester).isSpinning, isTrue);
      await _pump(
        tester,
        const CassetteTile(width: 34, crop: CassetteCrop.icon, spinning: true),
        theme: MixtapeTheme.light(),
        disableAnimations: true,
      );
      expect(_state(tester).isSpinning, isFalse);
    });
  });
}
