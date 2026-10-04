/// The one empty state, and the one place it sits
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`; smoke round three,
/// note 7).
///
/// Mixes and Library each grew their own: a cassette, a title and a line, all
/// at slightly different sizes, centred against slightly different insets, so
/// switching tabs made the block jump. There is one block here now, and one
/// placement rule — [EmptyStateSliver] — so every tab puts it at the same
/// height on the same screen.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'cassette_tile.dart';
import 'large_title_scaffold.dart';

enum EmptyStateArtwork { cassette, memory, connection }

/// A contextual object, a title, one line under it, and at most one action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.action,
    this.artwork = EmptyStateArtwork.cassette,
  });

  final EmptyStateArtwork artwork;
  final String title;
  final String body;

  /// Normally a `TapeButton`. Nothing is drawn when there is nothing to do.
  final Widget? action;

  /// The illustration, one size everywhere.
  static const double cassetteWidth = 150;

  /// What that width paints, on the cassette's 200 × 128 viewBox.
  static const double cassetteHeight = cassetteWidth * 128 / 200;

  // The block's own rhythm.
  static const double titleGap = 18;
  static const double bodyGap = 6;
  static const double actionGap = 14;

  /// The cassette itself, so a test can measure where the block landed.
  static const Key cassetteKey = Key('empty-state-cassette');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (artwork == EmptyStateArtwork.cassette)
          const CassetteTile(key: cassetteKey, width: cassetteWidth)
        else
          Image.asset(
            'assets/illustrations/${artwork == EmptyStateArtwork.memory ? 'memory' : 'connection'}-object.png',
            width: cassetteWidth,
            height: cassetteHeight,
            excludeFromSemantics: true,
          ),
        const SizedBox(height: titleGap),
        Text(title, textAlign: TextAlign.center, style: tokens.smallTitle),
        const SizedBox(height: bodyGap),
        Text(body, textAlign: TextAlign.center, style: tokens.secondary),
        if (action != null) ...[const SizedBox(height: actionGap), action!],
      ],
    );
  }
}

/// The placement: the cassette centred in what the title chrome and the dock
/// leave, in a sliver that still pulls to refresh.
///
/// The band is measured on the screen, not on whatever each tab's own title
/// row happened to leave: under the collapsed title bar, above the dock. One
/// tab carries a segmented control beside its title and another a glass
/// cluster, and the founder should not be able to tell from where the block
/// sits. The cassette, not the whole block, is what the eye centres on, so a
/// second line of copy never lifts it off its neighbour's height.
class EmptyStateSliver extends StatelessWidget {
  const EmptyStateSliver({super.key, required this.child});

  final Widget child;

  /// The gap under the block, on top of the dock's own height.
  static const double bottomGap = 16;

  /// The title chrome the block clears: the large title's collapsed bar.
  static const double topOffset = LargeTitleScaffold.barHeight;

  /// What a tab leaves free at the bottom for the floating dock.
  static double dockInsetOf(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + bottomGap;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dockInset = dockInsetOf(context);
    final bandTop = media.padding.top + topOffset;
    final bandBottom = media.size.height - media.padding.bottom;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: EdgeInsets.only(top: topOffset, bottom: dockInset),
        child: CustomSingleChildLayout(
          delegate: _CassetteAnchored(
            anchor: EmptyState.cassetteHeight,
            // Where this box's own bottom falls on the screen, which is the
            // one thing that ties its local coordinates to the band.
            boxBottom: media.size.height - dockInset,
            target: (bandTop + bandBottom) / 2,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Puts the block's first [anchor] pixels — the cassette — across [target] on
/// the screen, and falls back to centring the whole block in the space it has
/// when the block is too tall for that (200% text on a short phone).
class _CassetteAnchored extends SingleChildLayoutDelegate {
  const _CassetteAnchored({
    required this.anchor,
    required this.boxBottom,
    required this.target,
  });

  /// The height of the block's illustration.
  final double anchor;

  /// Where the laid-out box's bottom edge falls on the screen.
  final double boxBottom;

  /// Where the cassette's own centre should fall on the screen.
  final double target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final boxTop = boxBottom - size.height;
    var top = target - boxTop - anchor / 2;
    if (top < 0 || top + childSize.height > size.height) {
      top = (size.height - childSize.height) / 2;
    }
    return Offset((size.width - childSize.width) / 2, math.max(0, top));
  }

  @override
  bool shouldRelayout(_CassetteAnchored oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.boxBottom != boxBottom ||
      oldDelegate.target != target;
}
