/// Status as a coloured word, never a box (`.status` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`). Since the add your music
/// board (`docs/mockups/2026-11-21-add-your-music-restyle-r3.html`, `.sg`)
/// ok and warn carry SF-style filled glyphs in their own green and amber,
/// while the word keeps its status ink.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Which status ink the word carries. Accent is the theme's plum ink, for a
/// word that marks rather than warns (the arrangement's "New to you").
enum StatusKind { ok, warn, err, muted, accent }

/// The filled check's green, light and dark (board r3 `.sg.okf`); also the
/// done disc and meter on Add your music.
Color statusOkGlyph(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF4CD07A)
    : const Color(0xFF34A853);

/// The filled triangle's amber, light and dark (board r3 `.sg.wf`); also the
/// needs-attention disc on Add your music.
Color statusWarnGlyph(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFF1C04A)
    : const Color(0xFFE0A020);

/// An inline coloured word with an optional 14 pt mark.
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
    StatusKind.muted => tokens.muted,
    StatusKind.accent => tokens.plum,
  };

  IconData? get _glyph => switch (kind) {
    StatusKind.ok => CupertinoIcons.checkmark_circle_fill,
    StatusKind.err => CupertinoIcons.exclamationmark_circle,
    StatusKind.warn => CupertinoIcons.exclamationmark_triangle_fill,
    StatusKind.muted => null,
    StatusKind.accent => null,
  };

  @override
  Widget build(BuildContext context) {
    final ink = _ink(context.tokens);
    final glyph = icon ? _glyph : null;
    final glyphInk = switch (kind) {
      StatusKind.ok => statusOkGlyph(context),
      StatusKind.warn => statusWarnGlyph(context),
      _ => ink,
    };

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[
            Icon(glyph, size: 14, color: glyphInk),
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
