/// The app's one segmented control (founder, smoke round five, note 3).
///
/// A pill track holding a sliding thumb, hugging its own labels rather than
/// stretching across the screen. It replaces `CupertinoSlidingSegmentedControl`
/// on "Add your music" (Apple Music | Spotify) and on the Mixes tab
/// (Active | Archived), so both read as the same control.
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
  }) : assert(options.length > 1, 'a toggle needs at least two segments');

  final List<SegmentedOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// The track's resting height.
  static const double trackHeight = 32;

  /// The gap between the track's edge and the thumb.
  static const double inset = 4;

  /// The track's hairline.
  static const double borderWidth = 1;

  /// Everything between a segment and the outside world, per side — what a
  /// hugging control adds to the sum of its segments.
  static const double chrome = inset + borderWidth;

  /// A segment's own height inside that chrome, which the thumb matches. A
  /// floor, not a fixed height: labels grow with the text scale.
  static const double segmentHeight = trackHeight - chrome * 2;

  /// The label's own side padding.
  static const double segmentPadding = 14;

  /// How long the thumb takes to slide. Instant under reduced motion.
  static const Duration thumbDuration = Duration(milliseconds: 180);

  /// `0 1 3 rgba(39,32,39,.18)` under the thumb.
  static const Color thumbShadow = Color.fromRGBO(39, 32, 39, 0.18);

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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return IntrinsicWidth(
      child: Container(
        key: trackKey,
        decoration: BoxDecoration(
          color: tokens.field,
          borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
          border: Border.all(color: tokens.hairline, width: borderWidth),
        ),
        padding: const EdgeInsets.all(inset),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Positioned, so the track still sizes itself to the segments.
            Positioned.fill(
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
                        color: _thumbColor(context, tokens),
                        borderRadius: BorderRadius.circular(
                          MixtapeMetrics.pillRadius,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: thumbShadow,
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(child: _segment(context, tokens, i)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's own surface in light. In dark that token is darker than the
  /// track, which would read as a hole rather than a raised thumb, so the dark
  /// thumb is the raised white the app's other dark chrome uses.
  Color _thumbColor(BuildContext context, MixtapeTokens tokens) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color.fromRGBO(255, 255, 255, 0.22)
      : tokens.sheetSurface;

  Widget _segment(BuildContext context, MixtapeTokens tokens, int index) {
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: segmentHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: segmentPadding),
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
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? tokens.text : tokens.smoke,
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
