import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The quiet band under a track row that says why the song is there.
///
/// It bleeds past the screen's side padding on both sides, so the wash runs
/// edge to edge while the text still lines up with the rows above it. This
/// assumes the caller's own horizontal padding is exactly
/// [MixtapeMetrics.screenSidePadding]; under anything else the wash stops
/// short of the screen edge or runs past it.
class ReasonBand extends StatelessWidget {
  const ReasonBand({super.key, required this.text});

  final String text;

  /// The painted wash, for tests.
  static const Key fillKey = Key('reason-band-fill');

  /// The board's band: light white at 40%, dark white at 6%.
  static Color fillColorFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color.fromRGBO(255, 255, 255, 0.06)
      : const Color.fromRGBO(255, 255, 255, 0.40);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const bleed = MixtapeMetrics.screenSidePadding;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Negative insets: Container's margin cannot go negative, so the wash
        // is positioned past the band's own box instead.
        Positioned(
          left: -bleed,
          right: -bleed,
          top: 0,
          bottom: 0,
          child: ColoredBox(
            key: fillKey,
            color: fillColorFor(Theme.of(context).brightness),
          ),
        ),
        // The band's own box is already inset by the screen padding, so the
        // board's 20 pt horizontal padding is what the bleed gives back.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            text,
            style: tokens.secondary.copyWith(
              fontSize: 12.5,
              color: tokens.smoke,
            ),
          ),
        ),
      ],
    );
  }
}
