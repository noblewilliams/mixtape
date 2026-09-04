/// Shared "Xm/Xh/Xd ago" formatting — originally home_screen.dart's private
/// `_relativeTime` (sessions list subtitles), pulled out here so
/// memory_screen.dart can render the same relative timestamps on memory
/// notes without duplicating (and risking drift from) the logic.
String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  final local = dt.toLocal();
  return '${local.month}/${local.day}/${local.year}';
}

/// The waiting state's elapsed wait ("Requested 2 days ago"): full words,
/// unlike [relativeTime]'s compact list-row form, and never collapsing to a
/// date — a wait is a count of days however long it runs. [now] is
/// injectable so tests pin exact boundaries.
String elapsedWait(DateTime since, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(since);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return _ago(diff.inMinutes, 'minute');
  if (diff.inDays < 1) return _ago(diff.inHours, 'hour');
  return _ago(diff.inDays, 'day');
}

String _ago(int count, String unit) => '$count ${count == 1 ? unit : '${unit}s'} ago';
