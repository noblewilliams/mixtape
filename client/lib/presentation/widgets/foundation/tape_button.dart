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
    this.fill = false,
    this.semanticsLabel,
    this.semanticsHint,
    this.wrap = false,
    this.minHeight,
    this.leadingPadding,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool playing;

  /// A leading mark, when a caller wants one. Nothing is drawn by default —
  /// the reel the board once showed is gone (smoke round two, note 2).
  final Widget? leading;

  /// Fills the width it is given, 44 pt tall, the label centred: the mix
  /// actions' `.strip .acts .tape` / `.sticky .tape` (`flex: 1;
  /// min-height: 44px`). Otherwise it shrink-wraps its label at 40 pt.
  final bool fill;

  /// What assistive technology reads instead of [label], when the visible
  /// word leans on a mark ("Create playlist" beside the Spotify mark).
  final String? semanticsLabel;

  /// Read after the label, e.g. "Opens Now Playing".
  final String? semanticsHint;

  /// Lets the label wrap, centred, instead of ellipsizing on one line: the
  /// music door's Remake, which must read in full at accessibility sizes.
  final bool wrap;

  /// The shell's floor when a caller needs a taller one (the door's 52 pt at
  /// large text); otherwise 40 pt, or 44 pt when it fills.
  final double? minHeight;

  /// The inset before the leading mark when it is not the usual 14 pt: the
  /// reel sits 8 pt in (`.tape { padding: 0 14px 0 8px }`).
  final double? leadingPadding;

  /// The Playing meter, for tests.
  static const Key meterKey = Key('tape-button-meter');

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
      constraints: BoxConstraints(
        minHeight:
            minHeight ??
            (fill ? MixtapeMetrics.minTarget : MixtapeMetrics.tapeButtonHeight),
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
                  left: leadingPadding ?? _sidePadding,
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
                        maxLines: wrap ? null : 1,
                        overflow: wrap ? null : TextOverflow.ellipsis,
                        textAlign: wrap ? TextAlign.center : null,
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
                    key: meterKey,
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
      label: semanticsLabel ?? label,
      hint: semanticsHint,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Disabled, it still claims the tap rather than passing it to
        // whatever it sits on (the tape strip opens the tape).
        onTap: onPressed ?? () {},
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            // Shrink-wrap: the target is at least 44 pt tall but never wider
            // than the control itself — unless it fills its row.
            widthFactor: fill ? null : 1,
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: fill
                  ? SizedBox(width: double.infinity, child: shell)
                  : shell,
            ),
          ),
        ),
      ),
    );
  }
}
