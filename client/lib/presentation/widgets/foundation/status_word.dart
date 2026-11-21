/// Status as a coloured word, never a box (`.status` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`). Since the add your music
/// board (`docs/mockups/2026-11-21-add-your-music-restyle-r3.html`, `.sg`)
/// ok and warn carry SF-style filled glyphs in their own green and amber,
/// while the word keeps its status ink.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Which status ink the word carries. Accent is the theme's plum ink, for a
/// word that marks rather than warns (the arrangement's "New to you").
enum StatusKind { ok, warn, err, muted, accent }

/// The filled check's green, light and dark (board r3 `.sg.okf`); also the
/// done disc and meter on Add your music.
Color statusOkGlyph(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF4CD07A)
    : const Color(0xFF34A853);

/// The filled triangle's amber, light and dark (board r3 `.sg.wf`); also the
/// needs-attention disc on Add your music.
Color statusWarnGlyph(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFF1C04A)
    : const Color(0xFFE0A020);

/// An inline coloured word with an optional 14 pt mark.
class StatusWord extends StatelessWidget {
  const StatusWord({
    super.key,
    required this.label,
    required this.kind,
    this.icon = true,
  });

  final String label;
  final StatusKind kind;
  final bool icon;

  Color _ink(MixtapeTokens tokens) => switch (kind) {
    StatusKind.ok => tokens.okInk,
    StatusKind.warn => tokens.warnInk,
    StatusKind.err => tokens.errInk,
    StatusKind.muted => tokens.muted,
    StatusKind.accent => tokens.plum,
  };

  Widget? _glyph(Color ink, Color glyphInk) => switch (kind) {
    StatusKind.ok => FilledStatusGlyph.ok(size: 14, color: glyphInk),
    StatusKind.warn => FilledStatusGlyph.warn(size: 14, color: glyphInk),
    StatusKind.err => Icon(
      CupertinoIcons.exclamationmark_circle,
      size: 14,
      color: ink,
    ),
    StatusKind.muted => null,
    StatusKind.accent => null,
  };

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context.tokens);
    final glyphInk = switch (kind) {
      StatusKind.ok => statusOkGlyph(context),
      StatusKind.warn => statusWarnGlyph(context),
      _ => ink,
    };
    final glyph = icon ? _glyph(ink, glyphInk) : null;

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[glyph, const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The filled check circle and filled warning triangle, drawn rather than
/// taken from an icon font. Flutter subsets the icon fonts to the glyphs a
/// build uses, and an over-the-air patch cannot replace the release's fonts,
/// so a glyph the release never used would draw as an empty box. Shapes after
/// SF Symbols `checkmark.circle.fill` and `exclamationmark.triangle.fill`.
class FilledStatusGlyph extends StatelessWidget {
  const FilledStatusGlyph.ok({
    super.key,
    required this.size,
    required this.color,
  }) : warn = false;
  const FilledStatusGlyph.warn({
    super.key,
    required this.size,
    required this.color,
  }) : warn = true;

  final double size;
  final Color color;
  final bool warn;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _FilledGlyphPainter(color, warn: warn)),
    ),
  );
}

class _FilledGlyphPainter extends CustomPainter {
  _FilledGlyphPainter(this.color, {required this.warn});

  final Color color;
  final bool warn;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24;
    canvas.scale(s);
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    final mark = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    if (!warn) {
      canvas.drawCircle(const Offset(12, 12), 10.5, fill);
      mark.strokeWidth = 2.4;
      canvas.drawPath(
        Path()
          ..moveTo(7.6, 12.4)
          ..lineTo(10.6, 15.4)
          ..lineTo(16.4, 9.2),
        mark,
      );
      return;
    }
    final triangle = Path()
      ..moveTo(10.3, 3.6)
      ..quadraticBezierTo(12, 0.9, 13.7, 3.6)
      ..lineTo(21.8, 17.7)
      ..quadraticBezierTo(23.3, 20.7, 20.1, 20.7)
      ..lineTo(3.9, 20.7)
      ..quadraticBezierTo(0.7, 20.7, 2.2, 17.7)
      ..close();
    canvas.drawPath(triangle, fill);
    mark.strokeWidth = 2.2;
    canvas.drawLine(const Offset(12, 8.8), const Offset(12, 13.6), mark);
    canvas.drawCircle(
      const Offset(12, 17.1),
      1.3,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_FilledGlyphPainter old) =>
      old.color != color || old.warn != warn;
}
