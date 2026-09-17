/// The composer's prism stripe (`.composer .stripe` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// A rounded bar of the five-stop vertical prism. Decorative, so it is hidden
/// from assistive technology.
class PrismStripe extends StatelessWidget {
  const PrismStripe({super.key, this.width = 4, this.height = 26});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: context.tokens.prismVertical,
        borderRadius: const BorderRadius.all(Radius.circular(2)),
      ),
      child: SizedBox(width: width, height: height),
    ),
  );
}
