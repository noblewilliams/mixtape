/// The background every screen sits on
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Background).
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Paints the token background behind [child]: the vertical fall, then the
/// glow tints as radial gradients.
///
/// Pass [artworkColors] on Now Playing — two dominant artwork colours replace
/// the three token glows over the same base fall.
class GradientBackground extends StatelessWidget {
  const GradientBackground({
    super.key,
    required this.child,
    this.artworkColors,
  });

  final Widget child;

  /// Dominant artwork colours. Two or more swaps the glows for the Now Playing
  /// pair; null or one keeps the token glows.
  final List<Color>? artworkColors;

  /// Now Playing's first glow.
  static const Alignment artworkCenterA = Alignment(-0.4, -0.5);

  /// Now Playing's second glow.
  static const Alignment artworkCenterB = Alignment(0.6, 0.6);

  /// The glows painted over the base fall, for [tokens] and [artworkColors].
  ///
  /// Public so tests can assert the approved geometry without reading pixels.
  @visibleForTesting
  static List<GlowTint> glowsFor(
    MixtapeTokens tokens,
    List<Color>? artworkColors,
  ) {
    final artwork = artworkColors;
    if (artwork == null || artwork.length < 2) {
      return [tokens.violetGlow, tokens.pinkGlow, tokens.blueGlow];
    }
    return [
      GlowTint(
        color: artwork[0].withValues(alpha: 0.55),
        center: artworkCenterA,
        radiusX: 0.9,
        radiusY: 0.6,
      ),
      GlowTint(
        color: artwork[1].withValues(alpha: 0.40),
        center: artworkCenterB,
        radiusX: 0.8,
        radiusY: 0.6,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Stack(
      fit: StackFit.passthrough,
      // A screen's dock shadow and overscroll must not be cut off; the painter
      // stays inside the background's own rect regardless.
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: GradientBackgroundPainter(
                base: tokens.backgroundGradient,
                glows: GradientBackground.glowsFor(tokens, artworkColors),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Paints [base] then [glows]. Its fields are public so widget tests can read
/// the configuration off the [CustomPaint] instead of sampling pixels.
@visibleForTesting
class GradientBackgroundPainter extends CustomPainter {
  const GradientBackgroundPainter({required this.base, required this.glows});

  final LinearGradient base;
  final List<GlowTint> glows;

  /// The board's `transparent 70%` falloff: alpha reaches 0 at 70% of the
  /// ellipse radii, not at the edge.
  static const List<double> falloffStops = [0, 0.7];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    canvas.drawRect(rect, Paint()..shader = base.createShader(rect));

    for (final glow in glows) {
      final radiusX = glow.radiusX * size.width;
      final radiusY = glow.radiusY * size.height;
      if (radiusX <= 0 || radiusY <= 0) continue;

      final center = Offset(
        rect.center.dx + glow.center.x * size.width / 2,
        rect.center.dy + glow.center.y * size.height / 2,
      );

      // Draw a circle of radius `radiusX` and squash it vertically, so the
      // tint is the ellipse the board specifies.
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(1, radiusY / radiusX);
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          radiusX,
          [glow.color, glow.color.withValues(alpha: 0)],
          falloffStops,
          TileMode.clamp,
        );
      canvas.drawRect(
        Rect.fromCircle(center: Offset.zero, radius: radiusX),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(GradientBackgroundPainter oldDelegate) =>
      oldDelegate.base != base || !listEquals(oldDelegate.glows, glows);
}
