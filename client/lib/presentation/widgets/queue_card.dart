import 'package:flutter/material.dart';
import '../../data/dj/dj_models.dart';
import '../screens/queue_screen.dart';

/// Compact preview of the current tape, rendered inline in the chat
/// transcript (see `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`
/// Task 4). The whole card is one tap target that pushes [QueueScreen] for
/// the full reorder/remove/play/save experience (Task 5).
class QueueCard extends StatelessWidget {
  const QueueCard({super.key, required this.sessionId, required this.queue});

  final String sessionId;
  final List<QueueTrack> queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = queue.take(3).toList();
    final remaining = queue.length - preview.length;
    // Only worth summing/showing a duration when the queue isn't empty of
    // them entirely — a queue with zero known durations shouldn't render a
    // misleading "~0 min".
    final hasAnyDuration = queue.any((t) => t.durationMs != null);
    final totalMinutes = hasAnyDuration
        ? (queue.fold<int>(0, (sum, t) => sum + (t.durationMs ?? 0)) / 60000)
              .round()
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('queue-card'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => QueueScreen(sessionId: sessionId)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.queue_music,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text('The tape', style: theme.textTheme.labelLarge),
                ],
              ),
              const SizedBox(height: 8),
              for (final track in preview)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${track.position + 1}. ${track.title} — ${track.artist}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              if (remaining > 0) ...[
                const SizedBox(height: 6),
                Text(
                  totalMinutes != null
                      ? '+$remaining more · ~$totalMinutes min'
                      : '+$remaining more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
