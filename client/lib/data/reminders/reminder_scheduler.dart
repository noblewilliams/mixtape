import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// The one local reminder this app sends: after "I've requested it" on the
/// Spotify request screen, a nudge to check the inbox and confirm the
/// request. Screens depend on this interface (via `reminderSchedulerProvider`)
/// so widget tests inject a fake and never touch a platform channel.
abstract class ReminderScheduler {
  Future<void> scheduleRequestReminder({required Duration after});
}

/// [ReminderScheduler] over `flutter_local_notifications`. Initializes the
/// plugin lazily and asks for notification permission at the first
/// schedule — that is, at the tap that needs it, never at launch. The
/// notification carries fixed copy only: no names, nothing from the
/// listener's data.
class LocalNotificationReminderScheduler implements ReminderScheduler {
  LocalNotificationReminderScheduler({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const int requestReminderId = 1;
  static const String requestReminderTitle = 'Your Spotify data';
  static const String requestReminderBody =
      "Check your inbox for Spotify's email, and confirm the request if you haven't yet.";

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _initialized = true;
  }

  @override
  Future<void> scheduleRequestReminder({required Duration after}) async {
    await _ensureInitialized();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios == null) return; // iOS is the only platform this app ships on
    final granted = await ios.requestPermissions(alert: true, sound: true);
    if (granted != true) return;
    // Scheduling by id replaces any earlier reminder; a UTC instant needs no
    // time-zone database, and the plugin converts it on the native side.
    await _plugin.zonedSchedule(
      id: requestReminderId,
      title: requestReminderTitle,
      body: requestReminderBody,
      scheduledDate: tz.TZDateTime.now(tz.UTC).add(after),
      notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails()),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }
}
