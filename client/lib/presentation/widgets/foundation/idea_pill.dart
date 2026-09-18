/// The Home idea pill from the approved Home states board (`.pill` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// 34 pt of starter prompt or routine suggestion, as wide as its own label.
///
/// [dimmed] is the typing state (the field already has text); [skeleton] is
/// the routine slot while it loads, which carries the label for VoiceOver but
/// no visible text.
class IdeaPill extends StatelessWidget {
  const IdeaPill({
    super.key,
    required this.label,
    this.onPressed,
    this.dimmed = false,
    this.skeleton = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool dimmed;
  final bool skeleton;

  /// What VoiceOver hears while the routine slot loads.
  static const String skeletonLabel = 'Checking your usual moments';

  static const Color _skeletonFill = Color.fromRGBO(127, 120, 130, 0.14);
  static const double _skeletonMinWidth = 120;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onPressed != null && !skeleton;

    final pill = Container(
      // A floor, not a fixed height: the label must grow at 200% text.
      constraints: BoxConstraints(
        minHeight: MixtapeMetrics.pillHeight,
        minWidth: skeleton ? _skeletonMinWidth : 0,
      ),
      padding: skeleton ? null : const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: skeleton
            ? _skeletonFill
            : Colors.white.withValues(alpha: isDark ? 0.10 : 0.55),
        borderRadius: const BorderRadius.all(
          Radius.circular(MixtapeMetrics.pillRadius),
        ),
        border: skeleton ? null : Border.all(color: tokens.hairline),
      ),
      // `Align` with a width factor rather than the container's own
      // `alignment`, which would expand the pill to the whole row: the board's
      // pills take only the width their label needs (smoke round two, note 6).
      child: Align(
        alignment: Alignment.center,
        widthFactor: 1,
        child: skeleton
            ? const SizedBox.shrink()
            : Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
      ),
    );

    return Semantics(
      button: !skeleton,
      enabled: enabled,
      label: skeleton ? skeletonLabel : label,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            // Shrink-wrap: the target is 44 pt tall but never wider than the
            // control itself.
            widthFactor: 1,
            child: Opacity(opacity: dimmed ? 0.45 : 1, child: pill),
          ),
        ),
      ),
    );
  }
}
