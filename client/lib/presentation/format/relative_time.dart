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
