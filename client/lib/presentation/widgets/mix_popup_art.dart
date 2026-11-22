/// The picture at the top of a mix's pop-ups (Save as playlist, Rename;
/// decision 2026-11-22): the mix's own cassette, tilted, in front of two
/// soft paper cards tinted with its colour. With a [label] the cassette
/// wears it, so a rename shows the new name on the tape as it is typed.
///
/// Built only from widgets the 1.2.0 release already has (no new glyphs or
/// images), so an over-the-air patch can carry it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'foundation/cassette_tile.dart';
import 'foundation/mixtape_sheet.dart';

class MixPopupArt extends StatelessWidget {
  const MixPopupArt({
    super.key = artKey,
    this.caseColor,
    this.label,
    this.compact = false,
  });

  static const Key artKey = Key('mix-popup-art');

  final Color? caseColor;

  /// Written on the cassette's label.
  final String? label;

  /// Smaller, while the keyboard is up.
  final bool compact;

  static const double height = 92;
  static const double compactHeight = 58;
  static const Duration resize = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tape = caseColor ?? const Color(0xFF5A4957);
    Widget card(double angle, Offset offset, double alpha) =>
        Transform.translate(
          offset: offset,
          child: Transform.rotate(
            angle: angle,
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  tape.withValues(alpha: alpha),
                  dark ? const Color(0xFF2A2630) : const Color(0xFFFBF8F5),
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: tokens.text.withValues(alpha: dark ? 0.3 : 0.08),
                    offset: const Offset(0, 6),
                    blurRadius: 14,
                  ),
                ],
              ),
            ),
          ),
        );
    return MediaQuery.withNoTextScaling(
      child: AnimatedContainer(
        duration: resize,
        curve: Curves.easeOut,
        height: compact ? compactHeight : height,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 200,
            height: height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                card(-10 * math.pi / 180, const Offset(-36, -2), 0.14),
                card(8 * math.pi / 180, const Offset(36, -4), 0.24),
                Transform.translate(
                  offset: const Offset(0, 8),
                  child: Transform.rotate(
                    angle: -4 * math.pi / 180,
                    child: CassetteTile(
                      width: 96,
                      caseColor: tape,
                      title: label,
                      shadow: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
