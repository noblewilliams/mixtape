/// The cassette-shell button from the approved shell board
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`, `.tape` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'prism_stripe.dart';

/// The primary mix action: 40 pt of tape shell with a centred label.
///
/// [playing] adds the prism meter on the trailing edge; the meter is static
/// here, animation arrives with the player so reduced motion is handled in one
/// place.
class TapeButton extends StatelessWidget {
  const TapeButton({
    super.key,
    required this.label,
    this.onPressed,
    this.playing = false,
    this.leading,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool playing;

  /// A leading mark, when a caller wants one. Nothing is drawn by default —
  /// the reel the board once showed is gone (smoke round two, note 2).
  final Widget? leading;

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  /// The meter overlaps the trailing inset, so the label needs the room.
  static const double _meterWidth = 8;
  static const double _playingRightPadding = 24;

  /// Balanced side padding around a label that now stands on its own.
  static const double _sidePadding = 14;

  /// The prism the dark shell wears along its bottom edge, full width and
  /// clipped by the shell's own radius (smoke round three, note 1).
  static const double stripeHeight = 3;

  /// That stripe, for tests.
  static const Key stripeKey = Key('tape-button-prism');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    final shell = ConstrainedBox(
      // A floor, not a fixed height: the label must grow at 200% text.
      constraints: const BoxConstraints(
        minHeight: MixtapeMetrics.tapeButtonHeight,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.tapeFill,
          borderRadius: _radius,
          border: Border.all(color: tokens.tapeEdge),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: tokens.tapeShadow,
                    offset: const Offset(0, 2),
                    blurRadius: 0,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: _radius,
          // Centred: the row fills the shell's height whatever the shell
          // grows to, so the label never hugs the top.
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: _sidePadding,
                  right: playing ? _playingRightPadding : _sidePadding,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 7),
                    ],
                    // Loose, so the label shrink-wraps when there is room and
                    // ellipsizes when there is not; mark and meter never
                    // shrink.
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: tokens.tapeInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // The board's `inset 0 1px 0 rgba(255,255,255,.13)` top highlight.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.13),
                ),
              ),
              // Full width along the bottom, under the label: the one
              // colourful mark on the app's primary action.
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PrismStripe(
                  key: stripeKey,
                  horizontal: true,
                  height: stripeHeight,
                  width: double.infinity,
                  borderRadius: BorderRadius.zero,
                ),
              ),
              if (playing)
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Blue at the top falling to pink: the prism reversed.
                        colors: tokens.prism
                            .take(5)
                            .toList()
                            .reversed
                            .toList(growable: false),
                      ),
                    ),
                    child: const SizedBox(width: _meterWidth),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

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
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            // Shrink-wrap: the target is at least 44 pt tall but never wider
            // than the control itself.
            widthFactor: 1,
            child: Opacity(opacity: enabled ? 1 : 0.5, child: shell),
          ),
        ),
      ),
    );
  }
}
