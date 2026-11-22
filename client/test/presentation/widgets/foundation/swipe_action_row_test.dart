import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/quote_glyph.dart';
import 'package:mixtape/presentation/widgets/foundation/swipe_action_row.dart';

Widget _row() => MaterialApp(
  theme: MixtapeTheme.light(),
  home: Scaffold(
    body: SwipeActionRow(
      reducedMotion: true,
      leading: SwipeAction(
        icon: const QuoteGlyph(size: 18, color: Colors.white, filled: true),
        label: 'Quote',
        color: const Color(0xFF5A4957),
        onTrigger: () {},
      ),
      child: const SizedBox(height: 72, child: Text('4EVER')),
    ),
  ),
);

void main() {
  // A drawn glyph takes whatever size it is given: the capsule must not force
  // its own width and height on it (device screenshot, 2026-11-22).
  testWidgets('the action glyph keeps its own size however wide the capsule', (
    tester,
  ) async {
    await tester.pumpWidget(_row());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('4EVER')),
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(QuoteGlyph)), const Size(18, 18));

    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(QuoteGlyph)), const Size(18, 18));
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
