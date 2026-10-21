/// The app's one segmented control (founder, smoke round five, note 3).
///
/// A pill track holding a sliding thumb, hugging its own labels rather than
/// stretching across the screen. It replaces `CupertinoSlidingSegmentedControl`
/// on "Add your music" (Apple Music | Spotify) and on the Mixes tab
/// (Active | Archived), so both read as the same control. Its compact form
/// holds Mix | Album on the Home panel's row above the composer (album picks
/// board H1): 26 pt drawn, 11.5 pt labels, 44 pt to touch.
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// One segment: the value it stands for and the word on it.
@immutable
class SegmentedOption<T> {
  const SegmentedOption({required this.value, required this.label, this.key});

  final T value;
  final String label;

  /// The segment's own key, when a caller's tests reach for it by name
  /// (`active-mixes`, `archived-mixes`). Absent, [SegmentedToggle.segmentKey]
  /// stands in.
  final Key? key;
}

/// A two-or-more segment toggle.
class SegmentedToggle<T> extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  }) : compact = false,
       assert(options.length > 1, 'a toggle needs at least two segments');

  /// The composer row's size (album picks board H1): drawn [compactTrackHeight]
  /// tall in [compactFontSize] labels, with an invisible hit area that makes
  /// every segment [MixtapeMetrics.minTarget] tall to touch. Labels still grow
  /// with the text scale; a caller caps that as the Mixes toggle does.
  const SegmentedToggle.compact({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  }) : compact = true,
       assert(options.length > 1, 'a toggle needs at least two segments');

  final List<SegmentedOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// The composer row's size rather than the screen-chrome size.
  final bool compact;

  /// When given, the control is one group with this name around its segments
  /// ("What to make"), which still read as "Mix, selected" and so on.
  final String? semanticLabel;

  /// The track's resting height.
  static const double trackHeight = 32;

  /// The gap between the track's edge and the thumb.
  static const double inset = 4;

  /// No hairline: the track is a flat tint and the thumb carries the state
  /// (founder, 2026-09-18 smoke round six: less shadow and border, a clearer
  /// active state).
  static const double borderWidth = 0;

  /// Everything between a segment and the outside world, per side — what a
  /// hugging control adds to the sum of its segments.
  static const double chrome = inset + borderWidth;

  /// A segment's own height inside that chrome, which the thumb matches. A
  /// floor, not a fixed height: labels grow with the text scale.
  static const double segmentHeight = trackHeight - chrome * 2;

  /// The label's own side padding.
  static const double segmentPadding = 14;

  /// The compact form's drawn track at 1x, inset, segment floor, label size
  /// and label padding (`.moderow .segc` on the album picks board).
  static const double compactTrackHeight = 26;
  static const double compactInset = 2;
  static const double compactSegmentHeight =
      compactTrackHeight - compactInset * 2;
  static const double compactFontSize = 11.5;
  static const double compactSegmentPadding = 10;

  /// The text scale past which the compact controls stop growing.
  static const double compactMaxTextScale = 1.5;

  /// How much the drawn height grows across 1x to [compactMaxTextScale]:
  /// 26 pt at 1x, 32 pt at 1.5x (the board's large-text frame draws a 28 pt
  /// segment in a 32 pt track, and a 32 pt chip).
  static const double compactTextGrowth = 6;

  /// The compact controls' drawn height under the ambient text scale, shared
  /// by this control and the compact Shape chip so the row stays level.
  static double compactDrawnHeight(BuildContext context) {
    final scale =
        MediaQuery.textScalerOf(context).scale(compactFontSize) /
        compactFontSize;
    final t = ((scale - 1) / (compactMaxTextScale - 1))
        .clamp(0.0, 1.0)
        .toDouble();
    return compactTrackHeight + compactTextGrowth * t;
  }

  /// The invisible band above and below a compact control drawn [drawn] pt
  /// tall that brings it to a 44 pt target.
  static double compactHitSlopFor(double drawn) =>
      ((MixtapeMetrics.minTarget - drawn) / 2).clamp(0.0, double.infinity);

  /// How long the thumb takes to slide. Instant under reduced motion.
  static const Duration thumbDuration = Duration(milliseconds: 180);

  /// The track and the thumb, for tests.
  static const Key trackKey = Key('segmented-toggle-track');
  static const Key thumbKey = Key('segmented-toggle-thumb');

  /// A segment's key when its option carries none.
  static Key segmentKey(int index) => ValueKey('segmented-toggle-$index');

  int get _selected {
    final index = options.indexWhere((option) => option.value == value);
    return index < 0 ? 0 : index;
  }

  /// Where the thumb sits, as an [Align] x: -1 over the first segment, +1 over
  /// the last. The thumb is exactly one segment wide, so these are the only
  /// stops it has.
  double get _thumbX => (2 * _selected / (options.length - 1)) - 1;

  double get _inset => compact ? compactInset : inset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final drawn = compact ? compactDrawnHeight(context) : trackHeight;
    final slop = compact ? compactHitSlopFor(drawn) : 0.0;
    final segmentFloor = compact ? drawn - compactInset * 2 : segmentHeight;

    final control = IntrinsicWidth(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The drawn track and its thumb, positioned so the control still
          // sizes itself to the segments. In the compact form it is inset
          // from the hit area above and below, which stays invisible.
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: slop),
              child: Container(
                key: trackKey,
                decoration: BoxDecoration(
                  color: _trackColor(tokens),
                  borderRadius: BorderRadius.circular(
                    MixtapeMetrics.pillRadius,
                  ),
                ),
                padding: EdgeInsets.all(_inset),
                child: IgnorePointer(
                  child: AnimatedAlign(
                    alignment: Alignment(_thumbX, 0),
                    duration: reduceMotion ? Duration.zero : thumbDuration,
                    curve: Curves.easeOut,
                    child: FractionallySizedBox(
                      widthFactor: 1 / options.length,
                      heightFactor: 1,
                      child: DecoratedBox(
                        key: thumbKey,
                        decoration: BoxDecoration(
                          color: tokens.tapeFill,
                          borderRadius: BorderRadius.circular(
                            MixtapeMetrics.pillRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            // Compact, the vertical inset moves inside each segment so its
            // tap area covers the whole hit band (see [_segment]); otherwise a
            // segment is exactly the thumb's size.
            padding: EdgeInsets.symmetric(
              horizontal: _inset,
              vertical: compact ? 0 : _inset,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(
                    child: _segment(
                      context,
                      tokens,
                      i,
                      slop: slop,
                      floor: segmentFloor,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    // Compact, the labels stop growing where the drawn height does, so the
    // control never outgrows the composer row.
    final sized = compact
        ? MediaQuery.withClampedTextScaling(
            maxScaleFactor: compactMaxTextScale,
            child: control,
          )
        : control;
    final label = semanticLabel;
    if (label == null) return sized;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: sized,
    );
  }

  /// A flat tint of the text ink: visible on the gradient in both themes,
  /// with no edge or shadow. The thumb is the tape fill, so the active
  /// segment reads like a pressed tape button.
  static Color _trackColor(MixtapeTokens tokens) =>
      tokens.text.withValues(alpha: 0.08);

  Widget _segment(
    BuildContext context,
    MixtapeTokens tokens,
    int index, {
    required double slop,
    required double floor,
  }) {
    final option = options[index];
    final selected = index == _selected;
    // Always reported, selected or not: a caller that cares whether the value
    // changed already compares it (both of ours do).
    void tap() => onChanged(option.value);

    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: tap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: KeyedSubtree(
          key: option.key ?? segmentKey(index),
          child: Padding(
            // Compact: the track's inset plus the invisible hit band, so the
            // segment answers taps over all of it.
            padding: EdgeInsets.symmetric(
              vertical: compact ? _inset + slop : 0,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: floor),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? compactSegmentPadding : segmentPadding,
                ),
                // `heightFactor`, or the segment would take every pixel of
                // height the track's parent happens to offer.
                child: Center(
                  heightFactor: 1,
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? compactFontSize : 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? tokens.tapeInk : tokens.smoke,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
