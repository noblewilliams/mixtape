/// The tape strip at the top of the conversation's bottom panel
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Bottom panel; `.strip` on the board, section 1): a 48 pt cassette in the
/// tape colour, the title, "Version n · N songs", and under them the mix
/// actions on a row of their own (strip layout A,
/// `docs/mockups/approved/2026-11-09-one-platform-play.md`). Tapping
/// anywhere but an action opens the tape.
///
/// At the largest text sizes the title may wrap to two lines and the actions
/// stack, each full width (the actions do that themselves).
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
    required this.actions,
    this.reason,
  });

  final String title;
  final int version;
  final int songs;
  final Color caseColor;
  final VoidCallback onOpen;

  /// The mix actions (`MixActions`), built by the host so they keep the
  /// host's handoff state. They fill the row under the title.
  final Widget actions;

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
                      maxLines: stacked ? 2 : 1,
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
            details,
            // `.strip { gap: 10px }` plus `.acts { margin-top: 4px }`: the
            // 44 pt row above already carries about 4 pt below its text.
            const SizedBox(height: 10),
            actions,
            ?reason,
          ],
        ),
      ),
    );
  }
}
