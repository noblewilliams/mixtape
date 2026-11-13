import 'package:flutter/material.dart';

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../screens/shared_mix_screen.dart' show sharedMixByline;
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/flush_row.dart';
import 'foundation/mixtape_menu.dart';
import 'foundation/swipe_actions.dart';
import 'mix_home_row.dart';
import 'tape_palette.dart';

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
  });

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

  /// The Remove panel: the menu's destructive red, darkened in dark mode so
  /// the white label keeps its contrast.
  static const Color _removeFillLight = MixtapeMenuItem.destructiveLight;
  static const Color _removeFillDark = Color(0xFFB0362A);

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

  Widget _row(BuildContext context, {required bool lifted}) => FlushRow(
    leading: _tile,
    leadingSize: MixHomeRow.artSize,
    verticalPadding: MixHomeRow.verticalPadding,
    showChevron: false,
    title: mix.title,
    subtitleWidget: _subtitle(context),
    isFirst: lifted ? true : isFirst,
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
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SwipeActions(
      key: ValueKey('shared-swipe-${mix.token}'),
      // As the mix rows: the row slides out to the screen edge.
      bleed: MixtapeMetrics.screenSidePadding,
      actions: [
        SwipeAction(
          key: removeActionKey(mix.token),
          label: removeLabel,
          icon: MixMenuIcons.eject,
          color: dark ? _removeFillDark : _removeFillLight,
          commits: true,
          onPressed: onRemove,
        ),
      ],
      child: Builder(
        builder: (context) => GestureDetector(
          onLongPress: () => _openMenu(context),
          child: _row(context, lifted: false),
        ),
      ),
    );
  }
}
