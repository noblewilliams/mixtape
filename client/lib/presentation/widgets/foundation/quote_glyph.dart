/// The quote mark, drawn in code: a speech bubble with two quote marks in it.
///
/// Drawn rather than taken from `CupertinoIcons` because an over-the-air
/// patch cannot add glyphs to the release's icon font (Flutter subsets it per
/// build), and the 1.1.1 (14) release never used the quote bubble: from the
/// font it would draw as an empty box (backlog, "Patch lesson").
library;

import 'package:flutter/widgets.dart';

class QuoteGlyph extends StatelessWidget {
  const QuoteGlyph({
    super.key,
    required this.color,
    this.size = 16,
    this.filled = false,
  });

  final Color color;
  final double size;

  /// Filled bubble with the marks cut out, else an outline with solid marks.
  final bool filled;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _QuoteGlyphPainter(color, filled)),
  );
}

class _QuoteGlyphPainter extends CustomPainter {
  const _QuoteGlyphPainter(this.color, this.filled);

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // The bubble: a rounded body over the top 80%, its tail at lower left.
    final body = RRect.fromLTRBR(
      s * 0.06,
      s * 0.08,
      s * 0.94,
      s * 0.76,
      Radius.circular(s * 0.22),
    );
    final bubble = Path()
      ..addRRect(body)
      ..moveTo(s * 0.24, s * 0.70)
      ..lineTo(s * 0.18, s * 0.94)
      ..lineTo(s * 0.46, s * 0.74)
      ..close();

    // Two quote marks: a dot with a tail curling down to the left.
    Path mark(double cx) {
      final r = s * 0.085;
      final cy = s * 0.38;
      return Path()
        ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r))
        ..moveTo(cx + r, cy)
        ..quadraticBezierTo(
          cx + r * 1.1,
          cy + r * 2.6,
          cx - r * 1.2,
          cy + r * 3,
        )
        ..quadraticBezierTo(cx + r * 0.2, cy + r * 1.8, cx - r * 0.2, cy + r)
        ..close();
    }

    final marks = Path()
      ..addPath(mark(s * 0.38), Offset.zero)
      ..addPath(mark(s * 0.62), Offset.zero);

    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (filled) {
      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawPath(bubble, fill);
      canvas.drawPath(marks, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    } else {
      canvas.drawPath(
        bubble,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.09
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      canvas.drawPath(marks, fill);
    }
  }

  @override
  bool shouldRepaint(_QuoteGlyphPainter old) =>
      old.color != color || old.filled != filled;
}
