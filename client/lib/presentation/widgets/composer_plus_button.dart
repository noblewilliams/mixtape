/// `.plus`: the round button beside the composer that opens its + menu,
/// anchored to itself. A mix's conversation has had one since the
/// conversation redesign; Home has one too since the device smoke of
/// 2026-11-13, so a playlist can be attached before the first prompt.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'mix_prompt_input.dart';

class ComposerPlusButton extends StatelessWidget {
  const ComposerPlusButton({super.key, required this.onPressed});

  /// Opens the menu, given the button's own context to anchor it. Null draws
  /// the button dimmed and inert.
  final void Function(BuildContext anchor)? onPressed;

  /// The drawn circle: a quiet key beside the field rather than a second
  /// field-sized control (Home panel tidy, 2026-11-17).
  static const double size = 28;

  /// The space it takes in the row: as tall as the composer's surface, which
  /// it sits level with and is centred on, and a little wider than the circle
  /// so the touch target stays generous.
  static const double extent = 34;

  /// The gap between it and the composer's focus ring.
  static const double gap = 6;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    return Builder(
      builder: (anchor) => Semantics(
        button: true,
        enabled: enabled,
        label: 'Add',
        onTap: enabled ? () => onPressed!(anchor) : null,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onPressed!(anchor) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: SizedBox(
              width: extent,
              height: MixPromptInput.minHeight,
              child: Center(
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tokens.field,
                    border: Border.all(color: tokens.hairline),
                  ),
                  child: Icon(Icons.add_rounded, size: 18, color: tokens.plum),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
