import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';

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
        reason: 'the board fixes the five case colours',
      );
    });

    test('ids spread across the whole set', () {
      final seen = {
        for (var i = 0; i < 300; i++) CassetteTile.caseColorFor('mix-$i'),
      };

      expect(seen, hasLength(CassetteTile.caseColors.length));
      expect(seen, containsAll(CassetteTile.caseColors));
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
}
