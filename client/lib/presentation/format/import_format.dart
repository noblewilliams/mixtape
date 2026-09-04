// Number, size, and date formatting for the import sheet and the sources
// screen. No locale package: the app is English-only and these read the
// same on every device.

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
];

/// `4812` → `4,812`.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    buffer.write(digits[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return value < 0 ? '-$buffer' : buffer.toString();
}

/// `40265318` → `38.4 MB`; whole kilobytes below a megabyte.
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

/// A ledger day (`YYYY-MM-DD`) as `Mar 2018`; anything else is returned as is.
String ledgerMonth(String day) {
  final match = RegExp(r'^(\d{4})-(\d{2})-\d{2}$').firstMatch(day);
  if (match == null) return day;
  final month = int.parse(match.group(2)!);
  if (month < 1 || month > 12) return day;
  return '${_months[month - 1]} ${match.group(1)}';
}

/// `Mar 2018 → Aug 2026`; a range inside one month reads as that month
/// (`Aug 2026`), a missing end stands in as the start, and no start is
/// null. Mirrors the web's `ledgerRangeLabel` so both surfaces agree.
String? ledgerRange(String? from, String? to) {
  if (from == null) return null;
  final start = ledgerMonth(from);
  final end = to == null ? start : ledgerMonth(to);
  return start == end ? start : '$start → $end';
}

/// `2018 – 2026` from the ledger bounds; one year reads as that year, a
/// missing end stands in as the start, and no start is null. Mirrors the
/// web's `yearsLabel`.
String? yearsRange(String? from, String? to) {
  if (from == null) return null;
  final start = _year(from);
  final end = to == null ? start : _year(to);
  return start == end ? start : '$start – $end';
}

String _year(String day) => day.length > 4 ? day.substring(0, 4) : day;

/// The inventory's skipped-row line: `12 podcasts · 3 local files`, zero
/// parts left out, `None` when nothing was skipped.
String skippedRowsLabel({required int podcasts, required int localFiles}) {
  final parts = [
    if (podcasts > 0) plural(podcasts, 'podcast'),
    if (localFiles > 0) plural(localFiles, 'local file'),
  ];
  return parts.isEmpty ? 'None' : parts.join(' · ');
}

/// The private-sessions switch's hint: how many plays the default keeps out.
String privateSessionsHint(int privatePlays) {
  if (privatePlays == 0) return 'No private-session plays in this file.';
  final verb = privatePlays == 1 ? 'stays' : 'stay';
  return '${plural(privatePlays, 'play')} hidden from followers $verb out unless you choose otherwise.';
}

/// `4 Sep`, with the year when it is not the current one.
String shortDate(DateTime date, {DateTime? now}) {
  final local = date.toLocal();
  final today = now ?? DateTime.now();
  final base = '${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? base : '$base ${local.year}';
}

String plural(int count, String unit, [String? units]) =>
    '${formatCount(count)} ${count == 1 ? unit : (units ?? '${unit}s')}';
