/// One song in the arrangement
/// (`docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`; `.trow`
/// in `docs/mockups/2026-09-17-mobile-arrangement-states.html`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../data/dj/dj_models.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/reason_band.dart';
import 'foundation/square_art.dart';
import 'playlist_artwork.dart' show playlistArtworkColor, playlistArtworkUrl;

/// Number, 48 pt square art, title, artist and a drag grip; tapping reveals
/// the DJ's note on a [ReasonBand] underneath.
///
/// The row is presentational: it neither owns the expanded flag nor posts the
/// move — [QueueScreen] holds both, because a move has to resolve against the
/// server's queue rather than the visible list.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.number,
    required this.track,
    required this.expanded,
    this.onTap,
    this.isFirst = false,
    this.lifted = false,
    this.dragIndex,
    this.onOpenInSpotify,
    this.onMoveUp,
    this.onMoveDown,
  });

  /// 1-based, as drawn. The screen numbers by the queue's own order, so the
  /// list never renumbers before the server confirms an edit.
  final int number;

  final QueueTrack track;
  final bool expanded;
  final VoidCallback? onTap;

  /// Whether this row opens the list, and so draws no hairline above itself.
  final bool isFirst;

  /// The dragged row's raised treatment, painted by the list's proxy.
  final bool lifted;

  /// The row's index in the enclosing [ReorderableListView]. Null outside one
  /// (or in the Spotify variant) and the grip simply doesn't start a drag.
  final int? dragIndex;

  /// Set only for a track with a Spotify id: the row then trades the grip for
  /// an Open in Spotify button.
  final VoidCallback? onOpenInSpotify;

  /// The VoiceOver rotor's Move up / Move down, which stand in for dragging.
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  /// The board's fixed columns: a 22 pt number gutter, 48 pt art, a 36 × 44
  /// grip, and a hairline inset past both leading columns.
  static const double numberWidth = 22;
  static const double artSize = 48;
  static const double gripWidth = 36;
  static const double gripHeight = 44;
  static const double gap = 12;
  static const double hairlineInset = numberWidth + gap + artSize;

  /// The lifted row's corner and its raised fill.
  static const double liftRadius = 10;

  static const String noReasonText = 'no notes from the DJ';
  static const String unavailableText = 'Not in Apple Music · skipped on play';

  static const Key numberKey = Key('track-row-number');
  static const Key artKey = Key('track-row-art');
  static const Key hairlineKey = Key('track-row-hairline');
  static const Key liftKey = Key('track-row-lift');

  static const CustomSemanticsAction moveUpAction = CustomSemanticsAction(
    label: 'Move up',
  );
  static const CustomSemanticsAction moveDownAction = CustomSemanticsAction(
    label: 'Move down',
  );

  /// Keys carried over from the screen's first implementation, so anything
  /// already driving a row by id keeps working.
  static Key rowKey(String trackId) => Key('queue-row-$trackId');
  static Key gripKey(String trackId) => Key('drag-handle-$trackId');
  static Key spotifyKey(String trackId) => Key('open-in-spotify-$trackId');
  static Key reasonKey(String trackId) => Key('queue-row-reason-$trackId');

  /// The board's lifted row: white at 85%, dark `rgba(60,56,66,.95)`.
  static Color liftColorFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color.fromRGBO(60, 56, 66, 0.95)
      : const Color.fromRGBO(255, 255, 255, 0.85);

  /// Titles wrap rather than ellipsise from this text scale up, as [FlushRow].
  static const double wrapScale = 1.5;

  bool get _unavailable => track.appleId == null;

  Widget _grip(MixtapeTokens tokens) {
    final bar = Container(
      width: 16,
      height: 2,
      decoration: BoxDecoration(
        color: tokens.muted.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(1),
      ),
    );
    final grip = SizedBox(
      key: gripKey(track.trackId),
      width: gripWidth,
      height: gripHeight,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [bar, const SizedBox(height: 3), bar, const SizedBox(height: 3), bar],
        ),
      ),
    );
    final index = dragIndex;
    if (index == null) return grip;
    // Long-press to lift, per the approved record; the list's own handles are
    // switched off so this is the only one.
    return ReorderableDelayedDragStartListener(index: index, child: grip);
  }

  Widget _spotifyButton(MixtapeTokens tokens) => KeyedSubtree(
    key: spotifyKey(track.trackId),
    child: Semantics(
      button: true,
      label: 'Open in Spotify: ${track.title}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpenInSpotify,
        child: SizedBox(
          width: MixtapeMetrics.minTarget,
          height: MixtapeMetrics.minTarget,
          child: Icon(Icons.open_in_new, size: 18, color: tokens.muted),
        ),
      ),
    ),
  );

  Widget _art() {
    final base = playlistArtworkColor(track.artworkBgColor);
    return KeyedSubtree(
      key: artKey,
      child: Opacity(
        opacity: _unavailable ? 0.5 : 1,
        child: SquareArt(
          url: playlistArtworkUrl(track.artworkUrl, size: 144),
          size: artSize,
          placeholderGradient: base == null
              ? null
              : [base, Color.lerp(base, Colors.black, 0.35)!],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final brightness = Theme.of(context).brightness;
    final wraps = MediaQuery.textScalerOf(context).scale(100) / 100 >= wrapScale;
    final hasReason = track.reason != null && track.reason!.trim().isNotEmpty;

    final lines = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.title,
          style: tokens.rowTitle.copyWith(
            color: _unavailable ? tokens.muted : tokens.text,
          ),
          maxLines: wraps ? null : 1,
          overflow: wraps ? null : TextOverflow.ellipsis,
        ),
        Text(
          track.artist,
          style: tokens.meta.copyWith(color: tokens.muted),
          maxLines: wraps ? null : 1,
          overflow: wraps ? null : TextOverflow.ellipsis,
        ),
        if (_unavailable)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              unavailableText,
              style: tokens.meta.copyWith(color: tokens.smoke),
            ),
          ),
      ],
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // One announcement for the song itself; the trailing control
                // keeps its own node (see explicitChildNodes below).
                Expanded(
                  child: MergeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          key: numberKey,
                          width: numberWidth,
                          child: Text(
                            '$number',
                            textAlign: TextAlign.right,
                            style: tokens.meta.copyWith(color: tokens.muted),
                          ),
                        ),
                        const SizedBox(width: gap),
                        _art(),
                        const SizedBox(width: gap),
                        Expanded(child: lines),
                      ],
                    ),
                  ),
                ),
                if (onOpenInSpotify != null)
                  _spotifyButton(tokens)
                else
                  _grip(tokens),
              ],
            ),
          ),
        ),
        if (expanded)
          KeyedSubtree(
            key: reasonKey(track.trackId),
            child: ReasonBand(text: hasReason ? track.reason! : noReasonText),
          ),
      ],
    );

    Widget body = Stack(
      children: [
        if (!isFirst && !lifted && !expanded)
          Positioned(
            left: hairlineInset,
            right: 0,
            top: 0,
            child: Container(
              key: hairlineKey,
              height: 1,
              color: tokens.hairline,
            ),
          ),
        content,
      ],
    );

    if (lifted) {
      body = DecoratedBox(
        key: liftKey,
        decoration: BoxDecoration(
          color: liftColorFor(brightness),
          borderRadius: BorderRadius.circular(liftRadius),
          boxShadow: const [
            BoxShadow(
              color: Color.fromRGBO(30, 24, 30, 0.22),
              blurRadius: 30,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: body,
        ),
      );
    }

    return KeyedSubtree(
      key: rowKey(track.trackId),
      child: Semantics(
        container: true,
        // The trailing Open in Spotify button must keep its own labelled
        // node instead of being absorbed into the row's.
        explicitChildNodes: true,
        onTap: onTap,
        customSemanticsActions: {
          if (onMoveUp != null) moveUpAction: onMoveUp!,
          if (onMoveDown != null) moveDownAction: onMoveDown!,
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          excludeFromSemantics: true,
          child: body,
        ),
      ),
    );
  }
}
