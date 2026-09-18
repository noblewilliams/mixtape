/// The tape card: the arrangement one DJ reply produced, drawn under that
/// reply (`docs/mockups/approved/2026-09-17-mobile-conversation-states.md`;
/// `.tapecard` and frame C1 on
/// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
///
/// Only the latest reply whose version is the current one carries it; earlier
/// versions are "Version n" chips into history.
library;

import 'package:flutter/material.dart';

import '../../data/dj/dj_models.dart';
import '../screens/queue_screen.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/label_chip.dart';

class QueueCard extends StatelessWidget {
  const QueueCard({
    super.key,
    required this.sessionId,
    required this.queue,
    required this.version,
  });

  final String sessionId;
  final List<QueueTrack> queue;

  /// The version this arrangement is, written into the meta line.
  final int version;

  /// `.tapecard .cs { width: 52px }` — kept at 52 pt even at 200% text, per
  /// the board's large-text variant.
  static const double cassetteWidth = 52;

  static const Key cardKey = Key('queue-card');
  static const Key openKey = Key('queue-card-open');

  /// "18 songs · 1 h 12 · version 2". The duration is dropped when any track's
  /// length is unknown rather than reported short — the same rule the
  /// arrangement's own meta line uses.
  static String metaLine(List<QueueTrack> queue, int version) => [
    '${queue.length} song${queue.length == 1 ? '' : 's'}',
    if (durationLabel(queue) != null) durationLabel(queue)!,
    'version $version',
  ].join(' · ');

  static String? durationLabel(List<QueueTrack> queue) {
    if (queue.isEmpty || queue.any((t) => t.durationMs == null)) return null;
    final minutes = queue.fold<int>(0, (sum, t) => sum + t.durationMs!) ~/ 60000;
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: cardKey,
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Row(
        children: [
          // The same case colour this mix wears everywhere else.
          CassetteTile(width: cassetteWidth, seedId: sessionId),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The tape',
                  style: tokens.rowTitle.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  metaLine(queue, version),
                  key: const Key('queue-card-meta'),
                  style: tokens.meta.copyWith(color: tokens.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          LabelChip(
            key: openKey,
            label: 'Open',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => QueueScreen(sessionId: sessionId),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
