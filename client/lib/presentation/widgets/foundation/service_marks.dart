/// The two service marks, drawn single-tone in the caller's ink
/// (founder, 2026-09-18: "single-tone service marks" — a glyph in the row's
/// ink, never the app icons).
///
/// They started life private to `choose_service_screen.dart`; the Library
/// tab's Sync button carries the Apple Music note too (smoke round four,
/// note 3), so they live here as foundation widgets.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The default side both marks are drawn at.
const double kServiceMarkSize = 28;

/// Apple Music: the beamed double eighth note from the app icon, drawn alone
/// in [color] (the ambient text ink when none is given).
class AppleMusicMark extends StatelessWidget {
  const AppleMusicMark({super.key, this.size = kServiceMarkSize, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ExcludeSemantics(
      child: CustomPaint(
        painter: _AppleMusicMarkPainter(color ?? context.tokens.text),
      ),
    ),
  );
}

/// Spotify: the disc with its three waves knocked out, in [color].
class SpotifyMark extends StatelessWidget {
  const SpotifyMark({super.key, this.size = kServiceMarkSize, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ExcludeSemantics(
      child: CustomPaint(
        painter: _SpotifyMarkPainter(color ?? context.tokens.text),
      ),
    ),
  );
}

/// Both marks are drawn in a 24 × 24 box and scaled to the mark's size, the
/// same way `sign_in_screen.dart` draws the Apple and Google marks.
const double _viewBox = 24;

class _AppleMusicMarkPainter extends CustomPainter {
  const _AppleMusicMarkPainter(this.ink);

  final Color ink;

  /// The glyph's share of the box: the same optical size as the disc beside it.
  static const double _glyphFraction = 0.82;

  /// Left stem, right stem — the right one is shorter, as the mark draws it.
  static const Rect _leftStem = Rect.fromLTRB(8.6, 4.3, 10.6, 18.0);
  static const Rect _rightStem = Rect.fromLTRB(19.4, 6.4, 21.4, 16.2);

  /// The beam joining the stem tops, slanting down to the right.
  static const List<Offset> _beam = [
    Offset(8.6, 2.7),
    Offset(21.4, 5.1),
    Offset(21.4, 8.7),
    Offset(8.6, 6.3),
  ];

  /// Note heads: centre, radii, and the tilt every music face gives them.
  static const Offset _leftHead = Offset(6.6, 17.6);
  static const Offset _rightHead = Offset(17.6, 15.8);
  static const Size _leftHeadRadii = Size(4.0, 3.15);
  static const Size _rightHeadRadii = Size(3.8, 3.0);
  static const double _headTilt = -0.33;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final glyph = side * _glyphFraction;
    canvas.save();
    canvas.translate((side - glyph) / 2, (side - glyph) / 2);
    canvas.scale(glyph / _viewBox);

    final paint = Paint()..color = ink;
    canvas.drawPath(
      Path()
        ..addRect(_leftStem)
        ..addRect(_rightStem)
        ..addPolygon(_beam, true),
      paint,
    );
    _drawHead(canvas, paint, _leftHead, _leftHeadRadii);
    _drawHead(canvas, paint, _rightHead, _rightHeadRadii);

    canvas.restore();
  }

  void _drawHead(Canvas canvas, Paint ink, Offset center, Size radii) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(_headTilt);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: radii.width * 2,
        height: radii.height * 2,
      ),
      ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleMusicMarkPainter oldDelegate) =>
      oldDelegate.ink != ink;
}

class _SpotifyMarkPainter extends CustomPainter {
  const _SpotifyMarkPainter(this.ink);

  /// One tone: the disc is [ink] and the waves are cut out of it.
  final Color ink;

  /// Every wave bows the same share of its own width, so the three read as
  /// one family rather than as nested rings — concentric arcs about a single
  /// centre make the short bottom one curl up like a wifi glyph, which the
  /// logo's does not.
  static const double _bow = 0.30;

  /// Where each wave's apex sits, half the chord it spans, and its stroke —
  /// the official proportions, as fractions of the 24 pt disc: the top wave
  /// is the widest (66% of the diameter) and the thickest (9%), the bottom
  /// the shortest (46%) and the thinnest (7%), the apexes evenly spaced and
  /// the group centred a touch above the disc's own centre.
  static const List<(double, double, double)> _waves = [
    (6.6, 7.92, 2.16),
    (10.3, 6.72, 1.92),
    (14.0, 5.52, 1.68),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // A layer, so the waves knock through to whatever is behind the mark.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.scale(size.shortestSide / _viewBox);
    canvas.drawCircle(const Offset(12, 12), 12, Paint()..color = ink);
    for (final (apex, halfChord, stroke) in _waves) {
      // Bowed upward in the middle: the apex is the top of a circle whose
      // centre hangs below the disc, far enough that the wave rises [_bow]
      // of its half-chord above the line joining its ends.
      final sagitta = halfChord * _bow;
      final radius =
          (halfChord * halfChord + sagitta * sagitta) / (2 * sagitta);
      final sweep = 2 * math.asin(halfChord / radius);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(12, apex + radius), radius: radius),
        -math.pi / 2 - sweep / 2,
        sweep,
        false,
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotifyMarkPainter oldDelegate) => oldDelegate.ink != ink;
}
