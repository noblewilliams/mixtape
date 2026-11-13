/// The tape screen's cassette header and its sticky bottom bar
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` → Tape
/// screen; `.thead` and `.sticky` on the board, section 2). The versions
/// preview reuses both, so the two read as the same object.
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../data/dj/dj_models.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';

/// "Tap a song for its note", under the last song.
const String tapeHint = 'Tap a song for its note';

/// "13 songs · 46 min · version 2". The duration is left out when unknown.
String tapeMetaLine(int songs, String? duration, int version) => [
  '$songs song${songs == 1 ? '' : 's'}',
  ?duration,
  'version $version',
].join(' · ');

/// "46 min", "1 h 12": a mix's running time, or null when any song's length
/// is unknown (never reported short).
String? tapeDurationLabel(List<QueueTrack> queue) {
  if (queue.isEmpty || queue.any((t) => t.durationMs == null)) return null;
  final minutes = queue.fold<int>(0, (sum, t) => sum + t.durationMs!) ~/ 60000;
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

/// A 150 pt cassette in the tape colour, tilted −4°, then the title (up to
/// two lines) and the meta line.
class TapeHeader extends StatelessWidget {
  const TapeHeader({
    super.key,
    required this.caseColor,
    required this.title,
    required this.meta,
    this.byline,
    this.cassetteWidth = defaultCassetteWidth,
    this.titleStyle,
  });

  final Color caseColor;
  final String title;
  final String meta;

  /// A plum line between the title and [meta]: "From Ada" on a shared mix.
  final String? byline;
  final double cassetteWidth;
  final TextStyle? titleStyle;

  /// `.thead .cs { width: 150px }`.
  static const double defaultCassetteWidth = 150;

  static const Key cassetteKey = Key('tape-header-cassette');
  static const Key titleKey = Key('tape-header-title');
  static const Key metaKey = Key('arrangement-meta');
  static const Key bylineKey = Key('tape-header-byline');

  /// `.thead .cs { transform: rotate(-4deg) }`.
  static const double tilt = -4 * math.pi / 180;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: tilt,
            child: ExcludeSemantics(
              child: CassetteTile(
                key: cassetteKey,
                width: cassetteWidth,
                caseColor: caseColor,
                shadow: true,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(
              title,
              key: titleKey,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  titleStyle ??
                  tokens.largeTitle.copyWith(fontSize: 24, height: 1.12),
            ),
          ),
          const SizedBox(height: 4),
          if (byline != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                byline!,
                key: bylineKey,
                textAlign: TextAlign.center,
                style: tokens.secondary.copyWith(
                  color: tokens.plum,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Text(
            meta,
            key: metaKey,
            textAlign: TextAlign.center,
            style: tokens.meta.copyWith(color: tokens.muted),
          ),
        ],
      ),
    );
  }
}

/// `.sticky`: a frosted bar at the bottom edge holding the tape's actions,
/// with an optional line above them.
///
/// The primary action takes the width beside the secondary one; at the
/// largest text sizes the two stack.
class TapeBar extends StatelessWidget {
  const TapeBar({
    super.key,
    required this.primary,
    this.secondary,
    this.reason,
  });

  final Widget primary;
  final Widget? secondary;

  /// A muted line above the actions (why Play cannot work, say); a widget
  /// that draws nothing is fine.
  final Widget? reason;

  static const Key barKey = Key('tape-bar');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final stacked = MediaQuery.textScalerOf(context).scale(100) / 100 >= 1.5;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: DecoratedBox(
          key: barKey,
          decoration: BoxDecoration(
            color: tokens.panel,
            border: Border(top: BorderSide(color: tokens.hairline)),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, bottom + 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (reason != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Center(child: reason),
                  ),
                if (stacked) ...[
                  primary,
                  if (secondary != null) ...[
                    const SizedBox(height: 6),
                    Center(child: secondary),
                  ],
                ] else
                  Row(
                    children: [
                      Expanded(child: primary),
                      if (secondary != null) ...[
                        const SizedBox(width: 10),
                        secondary!,
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
