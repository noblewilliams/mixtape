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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderCustomSingleChildLayoutBox;

import '../../../data/api/failure_kind.dart';

import '../../theme/mixtape_theme.dart';
import 'cassette_tile.dart';
import 'large_title_scaffold.dart';
import 'tape_button.dart';
import 'haptics.dart';

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

/// The one load-failure state: the unplugged-cable illustration, what did
/// not load, one line, and a tape "Try again" (founder smoke, 2026-11-03:
/// Library's bare line and Mixes' outlined button were two designs for one
/// thing). Put it in an [EmptyStateSliver] on a tab or list screen, or centre
/// it on a pushed one.
///
/// A tap shows the retry is working: the button carries a spinner for as
/// long as [onRetry]'s future runs, and at least [minBusy], so an instant
/// failure still reads as a fresh attempt (founder smoke, 2026-11-15: the
/// button gave no response, then the screen suddenly loaded). Given the
/// failure as [error], the line under the title says which of offline,
/// server-not-answering or something else it was ([FailureKind]).
class LoadErrorState extends StatefulWidget {
  const LoadErrorState({
    super.key,
    required this.title,
    required this.onRetry,
    this.body,
    this.error,
    this.actionLabel = 'Try again',
    this.retryKey,
  });

  /// What did not load, as a heading: "Couldn’t load your mixes".
  final String title;

  /// The line under the title when the failure is not one the state names
  /// itself; [defaultBody] when null. An offline [error] shows [offlineBody]
  /// and a server that did not answer [unreachableBody] instead, so a
  /// screen's own line never claims a cause.
  final String? body;

  /// The failure being shown, when the screen has it.
  final Object? error;
  final String actionLabel;
  final FutureOr<void> Function() onRetry;

  /// The button's key, for the screen's own tests.
  final Key? retryKey;

  static const String defaultBody =
      'Something went wrong. Try again in a moment.';
  static const String offlineBody =
      'You’re offline. Check your connection and try again.';
  static const String unreachableBody =
      'Mixtape isn’t responding right now. Try again in a moment.';

  /// The button's label while a retry runs.
  static const String busyLabel = 'Trying again…';

  /// The shortest time the spinner shows.
  static const Duration minBusy = Duration(milliseconds: 600);

  @override
  State<LoadErrorState> createState() => _LoadErrorStateState();
}

class _LoadErrorStateState extends State<LoadErrorState> {
  bool _busy = false;

  /// Holds the spinner for [LoadErrorState.minBusy]; cancelled on dispose,
  /// since a retry that works usually replaces this state outright.
  Timer? _floor;

  Future<void> _retry() async {
    if (_busy) return;
    unawaited(Haptics.play(HapticKind.primary));
    setState(() => _busy = true);
    final floor = Completer<void>();
    _floor = Timer(LoadErrorState.minBusy, floor.complete);
    try {
      await Future<void>.sync(widget.onRetry);
    } catch (_) {
      // The screen owns the failure; this only ends the spinner.
    }
    if (!mounted) return;
    await floor.future;
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _floor?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final body = switch (failureKindOf(widget.error)) {
      FailureKind.offline => LoadErrorState.offlineBody,
      FailureKind.unreachable => LoadErrorState.unreachableBody,
      FailureKind.other => widget.body ?? LoadErrorState.defaultBody,
    };
    return Semantics(
      liveRegion: true,
      child: EmptyState(
        title: widget.title,
        body: body,
        artwork: EmptyStateArtwork.connection,
        action: TapeButton(
          key: widget.retryKey,
          label: _busy ? LoadErrorState.busyLabel : widget.actionLabel,
          leading: _busy
              ? CupertinoActivityIndicator(radius: 7, color: tokens.tapeInk)
              : null,
          // Swallowed while busy rather than disabled, so the button keeps
          // full strength and the spinner reads clearly.
          onPressed: _busy ? () {} : _retry,
        ),
      ),
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
        child: _CassetteAnchoredLayout(
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

/// A [CustomSingleChildLayout] that reports its child's own height as its
/// intrinsic height. The plain one reports 0, so on a short screen (the
/// closed iPhone Duo in landscape) [SliverFillRemaining] never grew past the
/// space left under the header and the block overflowed instead of scrolling.
class _CassetteAnchoredLayout extends SingleChildRenderObjectWidget {
  const _CassetteAnchoredLayout({required this.delegate, super.child});

  final SingleChildLayoutDelegate delegate;

  @override
  RenderCustomSingleChildLayoutBox createRenderObject(BuildContext context) =>
      _RenderCassetteAnchored(delegate: delegate);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderCustomSingleChildLayoutBox renderObject,
  ) {
    renderObject.delegate = delegate;
  }
}

class _RenderCassetteAnchored extends RenderCustomSingleChildLayoutBox {
  _RenderCassetteAnchored({required super.delegate});

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;
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
