/// The secondary mix action from the approved shell board (`.chip` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// 36 pt of pale tape label, optionally marked with a reel hole.
class LabelChip extends StatelessWidget {
  const LabelChip({
    super.key,
    required this.label,
    this.onPressed,
    this.leading,
    this.hole = true,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Replaces the reel hole when a different leading mark is wanted.
  final Widget? leading;
  final bool hole;

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  /// The board's warm paper, not plain white.
  static const Color _lightFill = Color.fromRGBO(247, 244, 239, 0.60);
  static const Color _lightBorder = Color.fromRGBO(73, 64, 72, 0.22);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onPressed != null;
    final glyph =
        leading ??
        (hole
            ? SizedBox.square(
                dimension: 11,
                child: CustomPaint(painter: _HolePainter(tokens.plum)),
              )
            : null);

    final chip = Container(
      // A floor, not a fixed height: the label must grow at 200% text.
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.chipHeight),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.08) : _lightFill,
        borderRadius: _radius,
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.16) : _lightBorder,
        ),
      ),
      // The board's `inset 0 0 0 2px rgba(255,255,255,.3)` ring, light only.
      foregroundDecoration: isDark
          ? null
          : BoxDecoration(
              borderRadius: _radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[glyph, const SizedBox(width: 6)],
          // Loose, so the label shrink-wraps when there is room and ellipsizes
          // when there is not; the hole never shrinks.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: tokens.plum,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            // Shrink-wrap: the target is 44 pt tall but never wider than the
            // control itself.
            widthFactor: 1,
            child: Opacity(opacity: enabled ? 1 : 0.5, child: chip),
          ),
        ),
      ),
    );
  }
}

/// The reel hole: spokes under a thin ring, inside a hairline circle.
class _HolePainter extends CustomPainter {
  const _HolePainter(this.ink);

  final Color ink;

  static const Color _edge = Color.fromRGBO(73, 64, 72, 0.35);
  static const int _spokes = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final wedge = Rect.fromCircle(center: center, radius: radius - 1);
    final paint = Paint()..color = ink;
    const sweep = 18 * math.pi / 180;
    const step = 2 * math.pi / _spokes;
    for (var i = 0; i < _spokes; i++) {
      canvas.drawArc(wedge, i * step, sweep, true, paint);
    }
    canvas.drawCircle(
      center,
      radius * 0.35,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.2,
    );
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..color = _edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HolePainter oldDelegate) => oldDelegate.ink != ink;
}
