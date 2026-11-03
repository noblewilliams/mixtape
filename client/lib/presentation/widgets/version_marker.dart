/// A version marker in the transcript
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Version markers; `.vmark` on the board, section 1): one line with a 34 pt
/// cassette in the mix's tape colour, "Version n" and the song count.
///
/// An earlier version carries a chevron and opens history at that version.
/// The current one reads "current", has no chevron and opens nothing: the
/// strip below already holds it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';

class VersionMarker extends StatelessWidget {
  const VersionMarker({
    super.key,
    required this.version,
    required this.caseColor,
    this.songs,
    this.current = false,
    this.onOpen,
  });

  final int version;
  final Color caseColor;

  /// The version's song count, when known. The conversation only knows the
  /// current version's; earlier markers say just "Version n".
  final int? songs;
  final bool current;

  /// Earlier versions only: opens history at this version.
  final VoidCallback? onOpen;

  /// `.vmark .cs { width: 34px }`.
  static const double cassetteWidth = 34;

  static Key keyFor(int version) => ValueKey('version-marker-$version');

  /// "13 songs · current", "12 songs", "current", or nothing.
  static String? detail({int? songs, required bool current}) {
    final parts = [
      if (songs != null) '$songs song${songs == 1 ? '' : 's'}',
      if (current) 'current',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final line = detail(songs: songs, current: current);
    final tappable = !current && onOpen != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: -4 * math.pi / 180,
            child: CassetteTile(
              width: cassetteWidth,
              caseColor: caseColor,
              shadow: true,
            ),
          ),
          const SizedBox(width: 10),
          // One wrapping run, so a large text size wraps the song count
          // under the number rather than overflowing the line.
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Version $version',
                    style: tokens.meta.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: tokens.text,
                    ),
                  ),
                  if (line != null)
                    TextSpan(
                      text: '  $line',
                      style: tokens.meta.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: tokens.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, size: 18, color: tokens.muted),
          ],
        ],
      ),
    );
    final label = ['Version $version', ?line].join(', ');
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: tappable,
        label: label,
        onTap: tappable ? onOpen : null,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tappable ? onOpen : null,
          child: row,
        ),
      ),
    );
  }
}
