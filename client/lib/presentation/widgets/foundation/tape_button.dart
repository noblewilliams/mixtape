/// The cassette-shell button from the approved shell board
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`, `.tape` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The primary mix action: 40 pt of tape shell with a turning reel.
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

  /// Replaces the reel glyph when a different leading mark is wanted.
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
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: 8,
                  right: playing ? _playingRightPadding : 14,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    leading ??
                        const SizedBox.square(
                          dimension: 20,
                          child: CustomPaint(painter: _ReelPainter()),
                        ),
                    const SizedBox(width: 7),
                    // Loose, so the label shrink-wraps when there is room and
                    // ellipsizes when there is not; reel and meter never
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

/// The tape reel: a dark disc behind eight light spokes inside a 2.5 px ring.
class _ReelPainter extends CustomPainter {
  const _ReelPainter();

  static const Color _disc = Color(0xFF262329);
  static const Color _spoke = Color(0xFFE4E1DD);
  static const double _ring = 2.5;
  static const int _spokes = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = _disc);
    final inner = Rect.fromCircle(center: center, radius: radius - _ring);
    final paint = Paint()..color = _spoke;
    const sweep = 24 * math.pi / 180;
    const step = 2 * math.pi / _spokes;
    for (var i = 0; i < _spokes; i++) {
      canvas.drawArc(inner, i * step, sweep, true, paint);
    }
  }

  @override
  bool shouldRepaint(_ReelPainter oldDelegate) => false;
}
