/// The plain text action from the approved shell board (`.tbtn` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// A borderless word-sized action; [quiet] drops it to secondary ink.
class TextAction extends StatelessWidget {
  const TextAction({
    super.key,
    required this.label,
    this.onPressed,
    this.quiet = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;

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
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMetrics.minTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              // Shrink-wrap: the target is 44 pt tall, not wider than the word.
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: quiet ? FontWeight.w500 : FontWeight.w600,
                    color: quiet ? tokens.smoke : tokens.plum,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
