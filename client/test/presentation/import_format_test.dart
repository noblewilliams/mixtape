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

  test('yearsRange joins the ledger years, collapses one year, stands in for a missing end, '
      'and is null with no start', () {
    expect(yearsRange('2018-03-02', '2026-08-30'), '2018 – 2026');
    expect(yearsRange('2026-01-04', '2026-08-30'), '2026');
    expect(yearsRange('2024-03-02', null), '2024');
    expect(yearsRange(null, '2026-08-30'), isNull);
  });

  test('skippedRowsLabel joins the non-zero parts with a middle dot, in the singular or plural, '
      'and reads None when nothing was skipped', () {
    expect(skippedRowsLabel(podcasts: 12, localFiles: 3), '12 podcasts · 3 local files');
    expect(skippedRowsLabel(podcasts: 1, localFiles: 0), '1 podcast');
    expect(skippedRowsLabel(podcasts: 0, localFiles: 1), '1 local file');
    expect(skippedRowsLabel(podcasts: 0, localFiles: 0), 'None');
  });

  test('privateSessionsHint counts the plays the default keeps out, in the singular or plural, '
      'and says so when there are none', () {
    expect(privateSessionsHint(5), '5 plays hidden from followers stay out unless you choose otherwise.');
    expect(privateSessionsHint(1), '1 play hidden from followers stays out unless you choose otherwise.');
    expect(privateSessionsHint(0), 'No private-session plays in this file.');
  });

  test('plural picks the unit by count', () {
    expect(plural(1, 'track'), '1 track');
    expect(plural(2, 'track'), '2 tracks');
    expect(plural(1903, 'day'), '1,903 days');
    expect(plural(3, 'entry', 'entries'), '3 entries');
  });
}
