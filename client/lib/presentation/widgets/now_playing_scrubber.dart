/// Now Playing's progress bar: the prism as playback progress
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Now Playing, Prism;
/// `.scrub` in `docs/mockups/2026-09-17-mobile-shell-r3.html`).
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';

/// A 7 pt bar with a prism fill, elapsed and remaining times underneath.
///
/// [onSeek] carries the seek position in SECONDS, matching the player
/// channel's own unit. A null [onSeek] — no duration yet, a track the player
/// cannot play, a command already in flight — draws the same bar and simply
/// ignores touch, so progress never disappears while the controls rest.
class NowPlayingScrubber extends StatefulWidget {
  const NowPlayingScrubber({
    super.key,
    required this.positionMs,
    required this.durationMs,
    this.onSeek,
  });

  /// Where the player says it is, in milliseconds.
  final double positionMs;

  /// The song's length. Zero or less means unknown: no fill, no dragging.
  final int durationMs;

  /// Called once, with seconds, when a drag or tap settles.
  final ValueChanged<double>? onSeek;

  /// The board's bar.
  static const double barHeight = 7;
  static const double barRadius = 4;

  /// The unplayed remainder: white at 22%.
  static const double trackOpacity = 0.22;

  /// The gap between the bar and its times.
  static const double timeGap = 8;

  static const Key targetKey = Key('now-playing-scrub-target');
  static const Key barKey = Key('now-playing-scrub-bar');
  static const Key fillKey = Key('now-playing-scrub-fill');

  /// The mono times under the bar (`.scrub .t`).
  static const TextStyle timeStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Courier', 'monospace'],
  );

  /// The played fraction, clamped into 0–1. Unknown durations read as 0.
  static double fractionFor(double positionMs, int durationMs) =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  /// `m:ss`, the only clock a song needs.
  static String clock(double ms) {
    final total = (ms < 0 ? 0 : ms) ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  State<NowPlayingScrubber> createState() => _NowPlayingScrubberState();
}

class _NowPlayingScrubberState extends State<NowPlayingScrubber> {
  /// Where the finger is, while it is down. The player keeps reporting its own
  /// position during a drag; the draft wins until the seek is sent.
  double? _draft;

  bool get _interactive => widget.onSeek != null && widget.durationMs > 0;

  @override
  void didUpdateWidget(NowPlayingScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Seeking went away mid-drag (a command in flight, a track the player
    // cannot play). Nothing will settle the draft, so drop it rather than
    // freeze the thumb where the finger last was.
    if (!_interactive && _draft != null) _draft = null;
  }

  /// The position the times and the fill describe: the draft, or the player's
  /// own position clamped into the song.
  double get _shown {
    if (widget.durationMs <= 0) return 0;
    return (_draft ?? widget.positionMs).clamp(
      0.0,
      widget.durationMs.toDouble(),
    );
  }

  void _drag(double dx, double width) {
    if (width <= 0) return;
    setState(
      () => _draft = (dx / width).clamp(0.0, 1.0) * widget.durationMs,
    );
  }

  void _settle() {
    final draft = _draft;
    setState(() => _draft = null);
    if (draft != null) widget.onSeek!(draft / 1000);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final shown = _shown;
    final fraction = NowPlayingScrubber.fractionFor(shown, widget.durationMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Semantics(
              slider: true,
              label: 'Playback position',
              value: NowPlayingScrubber.clock(shown),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _interactive
                    ? (details) => _drag(details.localPosition.dx, width)
                    : null,
                onTapUp: _interactive ? (_) => _settle() : null,
                onTapCancel: _interactive
                    ? () => setState(() => _draft = null)
                    : null,
                onHorizontalDragStart: _interactive
                    ? (details) => _drag(details.localPosition.dx, width)
                    : null,
                onHorizontalDragUpdate: _interactive
                    ? (details) => _drag(details.localPosition.dx, width)
                    : null,
                onHorizontalDragEnd: _interactive ? (_) => _settle() : null,
                onHorizontalDragCancel: _interactive
                    ? () => setState(() => _draft = null)
                    : null,
                // The bar is 7 pt; the target around it is the 44 pt rule.
                child: SizedBox(
                  key: NowPlayingScrubber.targetKey,
                  height: MixtapeMetrics.minTarget,
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        NowPlayingScrubber.barRadius,
                      ),
                      child: Container(
                        key: NowPlayingScrubber.barKey,
                        height: NowPlayingScrubber.barHeight,
                        // Without a width the bar would shrink to its fill,
                        // and an unplayed song would have no bar at all.
                        width: double.infinity,
                        color: Colors.white.withValues(
                          alpha: NowPlayingScrubber.trackOpacity,
                        ),
                        child: FractionallySizedBox(
                          key: NowPlayingScrubber.fillKey,
                          alignment: Alignment.centerLeft,
                          widthFactor: fraction,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: tokens.prismGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: NowPlayingScrubber.timeGap),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              NowPlayingScrubber.clock(shown),
              style: NowPlayingScrubber.timeStyle.copyWith(
                color: tokens.muted,
              ),
            ),
            Text(
              '-${NowPlayingScrubber.clock(widget.durationMs - shown)}',
              style: NowPlayingScrubber.timeStyle.copyWith(
                color: tokens.muted,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
