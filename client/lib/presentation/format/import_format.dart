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

/// `Mar 2018 → Aug 2026`, or null unless both bounds are known.
String? ledgerRange(String? from, String? to) =>
    from == null || to == null ? null : '${ledgerMonth(from)} → ${ledgerMonth(to)}';

/// `4 Sep`, with the year when it is not the current one.
String shortDate(DateTime date, {DateTime? now}) {
  final local = date.toLocal();
  final today = now ?? DateTime.now();
  final base = '${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? base : '$base ${local.year}';
}

String plural(int count, String unit, [String? units]) =>
    '${formatCount(count)} ${count == 1 ? unit : (units ?? '${unit}s')}';
