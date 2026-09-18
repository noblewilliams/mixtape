/// The composer's prism stripe (`.composer .stripe` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// A bar of the prism. Decorative, so it is hidden from assistive technology.
///
/// Upright by default — the composer's five-stop stripe. [horizontal] lays the
/// cassette's full six stops left to right, which is how the tape button wears
/// it along its bottom edge (smoke round three, note 1).
class PrismStripe extends StatelessWidget {
  const PrismStripe({
    super.key,
    this.width = 4,
    this.height = 26,
    this.horizontal = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(2)),
  });

  final double width;
  final double height;

  /// Six stops left to right, rather than five top to bottom.
  final bool horizontal;

  /// Left square when a clip above already owns the corners.
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: horizontal
              ? tokens.prismGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : tokens.prismVertical,
          borderRadius: borderRadius,
        ),
        child: SizedBox(width: width, height: height),
      ),
    );
  }
}
