import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../screens/shared_mix_screen.dart' show sharedMixByline;
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/flush_row.dart';
import 'foundation/haptics.dart';
import 'foundation/mixtape_menu.dart';
import 'foundation/swipe_action_row.dart';
import 'mix_home_row.dart';
import 'tape_palette.dart';
import 'track_row.dart' show TrackRow;

/// A shared mix the listener saved, in Mixes (spec 2026-11-13 shared-mixes;
/// board M1–M3): the mix row's tape, size and padding, the cassette in the
/// share's colour, and "From Ada · 2h ago" with the name in plum. The swipe
/// and the long-press offer one action, Remove (the save, not the share).
/// No rename, no tape settings, no archive: the mix is the sender's.
class SharedMixHomeRow extends StatelessWidget {
  const SharedMixHomeRow({
    super.key,
    required this.mix,
    required this.onOpen,
    required this.onRemove,
    this.isFirst,
    this.onSlidingChanged,
  });

  /// As [MixHomeRow.onSlidingChanged].
  final ValueChanged<bool>? onSlidingChanged;

  final SharedMixRow mix;
  final VoidCallback onOpen;
  final Future<void> Function() onRemove;

  /// As [MixHomeRow.isFirst]: lazily built rows say whether they open the
  /// list.
  final bool? isFirst;

  static const String removeLabel = 'Remove';

  /// The row in Mixes, by token: the key Mixes gives it.
  static Key rowKey(String token) => ValueKey('shared-$token');

  /// The swipe's one panel, for tests.
  static Key removeActionKey(String token) =>
      ValueKey('shared-swipe-remove-$token');

  /// The Remove capsule: the queue's rose red and eject, as a song's remove
  /// (founder, 2026-11-23: a mix swipes as a song does).
  static const Color _removeColor = Color(0xFFC4566F);
  static const Widget _removeIcon = Icon(
    MixMenuIcons.eject,
    size: 17,
    color: Color(0xFFFFFFFF),
  );

  String get _byline => sharedMixByline(mix.sharerName);
  String get _when => relativeTime(mix.savedAt);

  Widget get _tile => CassetteTile(
    width: MixHomeRow.artSize,
    seedId: mix.token,
    title: mix.title,
    caseColor: tapeColor(mix.caseColor),
    shadow: true,
  );

  Widget _subtitle(BuildContext context) {
    final tokens = context.tokens;
    final wraps =
        MediaQuery.textScalerOf(context).scale(100) / 100 >= FlushRow.wrapScale;
    final style = tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: _byline,
            style: style.copyWith(color: tokens.plum),
          ),
          TextSpan(text: ' · $_when'),
        ],
      ),
      style: style,
      maxLines: wraps ? null : 1,
      overflow: wraps ? null : TextOverflow.ellipsis,
    );
  }

  Widget _row(
    BuildContext context, {
    required bool lifted,
    bool sliding = false,
  }) => FlushRow(
    leading: _tile,
    leadingSize: MixHomeRow.artSize,
    verticalPadding: MixHomeRow.verticalPadding,
    showChevron: false,
    title: mix.title,
    subtitleWidget: _subtitle(context),
    isFirst: lifted || sliding ? true : isFirst,
    onTap: lifted ? () {} : onOpen,
  );

  Future<void> _openMenu(BuildContext rowContext) async {
    final action = await showMixtapeMenu<String>(
      rowContext,
      actions: const [
        MixtapeMenuAction(
          value: 'remove',
          label: removeLabel,
          icon: MixMenuIcons.eject,
          isDestructive: true,
        ),
      ],
      lifted: (context) => MixtapeMenuLift(child: _row(context, lifted: true)),
    );
    if (action == 'remove') await onRemove();
  }

  @override
  Widget build(BuildContext context) => _SlidingRow(row: this);
}

/// Holds whether the row is sliding, so its own hairline rides away with it.
class _SlidingRow extends StatefulWidget {
  const _SlidingRow({required this.row});

  final SharedMixHomeRow row;

  @override
  State<_SlidingRow> createState() => _SlidingRowState();
}

class _SlidingRowState extends State<_SlidingRow> {
  bool _sliding = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final mix = row.mix;
    return SwipeActionRow(
      key: ValueKey('shared-swipe-${mix.token}'),
      reducedMotion: MediaQuery.disableAnimationsOf(context),
      liftColor: TrackRow.liftColorFor(Theme.of(context).brightness),
      // As the mix rows: the card lifts edge to edge.
      bleed: MixtapeMetrics.screenSidePadding,
      onActiveChanged: (active) {
        setState(() => _sliding = active);
        row.onSlidingChanged?.call(active);
      },
      trailing: SwipeAction(
        key: SharedMixHomeRow.removeActionKey(mix.token),
        label: SharedMixHomeRow.removeLabel,
        icon: SharedMixHomeRow._removeIcon,
        color: SharedMixHomeRow._removeColor,
        removes: true,
        onTrigger: row.onRemove,
      ),
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: SharedMixHomeRow.removeLabel):
              row.onRemove,
        },
        child: Builder(
          builder: (context) => GestureDetector(
            // The row lifts before its menu shows; the menu's open is
            // debounced into this one.
            onLongPress: Haptics.on(
              HapticKind.lift,
              () => row._openMenu(context),
            ),
            child: row._row(context, lifted: false, sliding: _sliding),
          ),
        ),
      ),
    );
  }
}
