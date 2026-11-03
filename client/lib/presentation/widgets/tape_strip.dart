/// The tape strip at the top of the conversation's bottom panel
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Bottom panel; `.strip` on the board, section 1): a 48 pt cassette in the
/// tape colour, the title, "Version n · N songs" and split Play. Tapping
/// anywhere but Play opens the tape.
///
/// At the largest text sizes it stacks: the title wraps beside the cassette
/// and Play takes a full row.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';

class TapeStrip extends StatelessWidget {
  const TapeStrip({
    super.key,
    required this.title,
    required this.version,
    required this.songs,
    required this.caseColor,
    required this.onOpen,
    required this.play,
    this.reason,
  });

  final String title;
  final int version;
  final int songs;
  final Color caseColor;
  final VoidCallback onOpen;

  /// Split Play (or the transfer handoff), built by the host so it keeps the
  /// host's handoff state.
  final Widget Function({required bool expand}) play;

  /// Why Play cannot work, under the strip; may draw nothing.
  final Widget? reason;

  static const Key stripKey = Key('tape-strip');
  static const Key openKey = Key('tape-strip-open');

  /// `.strip .cs { width: 48px }`, 52 pt when stacked.
  static const double cassetteWidth = 48;
  static const double stackedCassetteWidth = 52;

  /// From here on the strip stacks.
  static const double stackScale = 1.5;

  static String meta(int version, int songs) =>
      'Version $version · $songs song${songs == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stacked =
        MediaQuery.textScalerOf(context).scale(100) / 100 >= stackScale;
    final details = Semantics(
      button: true,
      label: '$title, version $version, $songs song${songs == 1 ? '' : 's'}',
      hint: 'Opens the tape',
      onTap: onOpen,
      excludeSemantics: true,
      child: GestureDetector(
        key: openKey,
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Row(
            children: [
              Transform.rotate(
                angle: -5 * math.pi / 180,
                child: CassetteTile(
                  width: stacked ? stackedCassetteWidth : cassetteWidth,
                  caseColor: caseColor,
                  shadow: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: stacked ? 3 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.rowTitle.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta(version, songs),
                      key: const Key('tape-strip-meta'),
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return GestureDetector(
      key: stripKey,
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.fromLTRB(2, 2, 4, 10),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.hairline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stacked) ...[
              details,
              const SizedBox(height: 8),
              play(expand: true),
            ] else
              Row(
                children: [
                  Expanded(child: details),
                  const SizedBox(width: 10),
                  play(expand: false),
                ],
              ),
            ?reason,
          ],
        ),
      ),
    );
  }
}
