import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/format/relative_time.dart';

void main() {
  final now = DateTime(2026, 9, 4, 12);

  test('elapsedWait counts in full words and never collapses to a date', () {
    String since(Duration ago) => elapsedWait(now.subtract(ago), now: now);

    expect(since(Duration.zero), 'just now');
    expect(since(const Duration(seconds: 59)), 'just now');
    expect(since(const Duration(minutes: 1)), '1 minute ago');
    expect(since(const Duration(minutes: 45)), '45 minutes ago');
    expect(since(const Duration(hours: 1)), '1 hour ago');
    expect(since(const Duration(hours: 23, minutes: 59)), '23 hours ago');
    expect(since(const Duration(days: 1)), '1 day ago');
    expect(since(const Duration(days: 2, hours: 3)), '2 days ago');
    expect(since(const Duration(days: 40)), '40 days ago');
  });
}
