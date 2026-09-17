/// Status as a coloured word, never a box (`.status` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Which status ink the word carries.
enum StatusKind { ok, warn, err }

/// An inline coloured word with an optional 14 pt mark.
///
/// Warn carries no mark by default: the board reserves the icon for the states
/// a reader must act on.
class StatusWord extends StatelessWidget {
  const StatusWord({
    super.key,
    required this.label,
    required this.kind,
    this.icon = true,
  });

  final String label;
  final StatusKind kind;
  final bool icon;

  Color _ink(MixtapeTokens tokens) => switch (kind) {
    StatusKind.ok => tokens.okInk,
    StatusKind.warn => tokens.warnInk,
    StatusKind.err => tokens.errInk,
  };

  IconData? get _glyph => switch (kind) {
    StatusKind.ok => CupertinoIcons.check_mark_circled,
    StatusKind.err => CupertinoIcons.exclamationmark_circle,
    StatusKind.warn => null,
  };

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context.tokens);
    final glyph = icon ? _glyph : null;

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[
            Icon(glyph, size: 14, color: ink),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
