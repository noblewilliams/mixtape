import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/format/import_format.dart';

void main() {
  test('formatCount groups thousands', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(4812), '4,812');
    expect(formatCount(1234567), '1,234,567');
  });

  test('formatBytes picks a unit and one decimal above KB', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1200), '1 KB');
    expect(formatBytes(40265318), '38.4 MB');
    expect(formatBytes(1300000), '1.2 MB');
    expect(formatBytes(2147483648), '2.0 GB');
  });

  test('ledgerMonth turns a ledger day into a month and year', () {
    expect(ledgerMonth('2018-03-02'), 'Mar 2018');
    expect(ledgerMonth('2026-08-30'), 'Aug 2026');
    expect(ledgerMonth('garbage'), 'garbage');
  });

  test('ledgerRange joins both bounds, collapses a same-month range, stands in for a missing '
      'end with the start, and is null without a start (the web\'s ledgerRangeLabel)', () {
    expect(ledgerRange('2018-03-02', '2026-08-30'), 'Mar 2018 → Aug 2026');
    expect(ledgerRange('2026-08-01', '2026-08-30'), 'Aug 2026');
    expect(ledgerRange('2018-03-02', null), 'Mar 2018');
    expect(ledgerRange(null, '2026-08-30'), isNull);
    expect(ledgerRange(null, null), isNull);
  });

  test('shortDate is day and month, with the year when it is not this one', () {
    final now = DateTime(2026, 9, 4);
    expect(shortDate(DateTime(2026, 9, 4), now: now), '4 Sep');
    expect(shortDate(DateTime(2025, 12, 25), now: now), '25 Dec 2025');
  });

  test('plural picks the unit by count', () {
    expect(plural(1, 'track'), '1 track');
    expect(plural(2, 'track'), '2 tracks');
    expect(plural(1903, 'day'), '1,903 days');
    expect(plural(3, 'entry', 'entries'), '3 entries');
  });
}
