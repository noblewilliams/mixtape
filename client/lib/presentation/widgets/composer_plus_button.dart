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

  /// As tall as the composer's surface, which it sits level with.
  static const double size = MixPromptInput.minHeight;

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
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.field,
                border: Border.all(color: tokens.hairline),
              ),
              child: Icon(Icons.add_rounded, size: 22, color: tokens.plum),
            ),
          ),
        ),
      ),
    );
  }
}
