/// The composer's voice level meter (`.listen i` in
/// `docs/mockups/2026-09-17-mobile-home-states.html`, frame V1).
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';

/// Five prism bars that ride the microphone's level while the composer is
/// listening.
///
/// Decorative: the field's own label says "Listening", so the meter is hidden
/// from assistive technology rather than read out five times a second.
class VoiceLevelMeter extends StatelessWidget {
  const VoiceLevelMeter({super.key, required this.level});

  /// Input level, 0–1. Anything outside is clamped.
  final double level;

  /// The board's bar heights at full level, left to right.
  static const List<double> barHeights = [14, 20, 9, 16, 11];

  static const double barWidth = 3;

  /// A silent room still shows a bar rather than a gap.
  static const double minBarHeight = 4;

  static const double barGap = 2;

  /// One amplitude sample, matching `VoiceCaptureService.amplitudeInterval`.
  static const Duration sample = Duration(milliseconds: 120);

  /// Where the bars sit when motion is off: the board's shape, held still.
  static const double _stillLevel = 0.5;

  static Key barKey(int index) => Key('voice-level-bar-$index');

  static double barHeight(double level, int index) =>
      (barHeights[index] * level.clamp(0.0, 1.0)).clamp(
        minBarHeight,
        barHeights[index],
      );

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final at = still ? _stillLevel : level;
    final gradient = context.tokens.prismVertical;

    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < barHeights.length; i++)
            Padding(
              padding: EdgeInsets.only(
                right: i == barHeights.length - 1 ? 0 : barGap,
              ),
              child: AnimatedContainer(
                key: barKey(i),
                duration: still ? Duration.zero : sample,
                curve: Curves.easeOut,
                width: barWidth,
                height: barHeight(at, i),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
