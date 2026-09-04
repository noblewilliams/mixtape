import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/reminders/reminder_scheduler.dart';

void main() {
  test('the request reminder text names no one and says what to do', () {
    expect(
      LocalNotificationReminderScheduler.requestReminderBody,
      "Check your inbox for Spotify's email, and confirm the request if you haven't yet.",
    );
  });

  test('the request reminder is a single, stable notification id', () {
    expect(LocalNotificationReminderScheduler.requestReminderId, 1);
  });
}
