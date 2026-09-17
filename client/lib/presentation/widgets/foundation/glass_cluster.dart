/// The floating glass button cluster from the approved shell board
/// (`.glassbtns` / `.glassbtn` in `docs/mockups/2026-09-17-mobile-shell-r3.html`).
///
/// Used beside the Library large title and for the conversation's back and
/// action clusters (`docs/mockups/approved/2026-09-17-mobile-shell.md`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'frosted_surface.dart';

/// A glass pill holding one or more [GlassButton]s side by side.
///
/// The board's pill is 46 pt tall around 40 pt buttons. The buttons here carry
/// a 44 pt hit target, so the pill pads 3 pt across and 1 pt down — the same
/// 46 pt of glass, with the target the accessibility rule asks for.
class GlassCluster extends StatelessWidget {
  const GlassCluster({super.key, required this.children});

  final List<Widget> children;

  /// The gap between buttons, per the board.
  static const double gap = 2;

  @override
  Widget build(BuildContext context) {
    return FrostedSurface(
      borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// A single round glyph button inside a [GlassCluster].
///
/// 40 pt of visible circle inside a 44 pt target, so neighbouring buttons stay
/// separable while every control still meets the board's 44 pt rule.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;

  /// The accessibility label; the button itself is a glyph.
  final String label;
  final VoidCallback? onPressed;

  /// The painted circle. The tap target is [MixtapeMetrics.minTarget].
  static const double diameter = 40;
  static const double iconSize = 20;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: MixtapeMetrics.minTarget,
          child: Center(
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: SizedBox.square(
                dimension: diameter,
                child: Center(
                  child: Icon(icon, size: iconSize, color: tokens.text),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
