import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Holds the app awake for the extra time iOS grants after the listener
/// leaves it (about 30 s), so a mix turn's stream stays open and the turn
/// can land. Over `mixtape/background` (AppDelegate.swift).
abstract class BackgroundTaskHolder {
  Future<void> begin();
  Future<void> end();
}

/// Off iOS, and in tests: holds nothing.
class NoBackgroundTaskHolder implements BackgroundTaskHolder {
  const NoBackgroundTaskHolder();

  @override
  Future<void> begin() async {}

  @override
  Future<void> end() async {}
}

class ChannelBackgroundTaskHolder implements BackgroundTaskHolder {
  const ChannelBackgroundTaskHolder();

  static const MethodChannel _channel = MethodChannel('mixtape/background');

  // Never fails a turn: without the task the turn simply runs as it always
  // did, until iOS suspends the app.
  @override
  Future<void> begin() async {
    try {
      await _channel.invokeMethod<void>('begin');
    } catch (_) {}
  }

  @override
  Future<void> end() async {
    try {
      await _channel.invokeMethod<void>('end');
    } catch (_) {}
  }
}

/// "Your mix is ready", for a mix that lands while the app is in the
/// background.
abstract class MixReadyAlerts {
  /// Asks for notification permission (iOS shows its prompt only once);
  /// whether notifications are allowed.
  Future<bool> requestPermission();

  Future<void> showMixReady();
}

class NoMixReadyAlerts implements MixReadyAlerts {
  const NoMixReadyAlerts();

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> showMixReady() async {}
}

/// [MixReadyAlerts] over `flutter_local_notifications`. Fixed copy only: no
/// mix title, nothing the listener said, since it shows on a lock screen.
class LocalNotificationMixReadyAlerts implements MixReadyAlerts {
  LocalNotificationMixReadyAlerts({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// The Spotify request reminder is 1 (reminder_scheduler.dart).
  static const int mixReadyId = 2;
  static const String title = 'Your mix is ready';
  static const String body = 'Tap to listen.';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<IOSFlutterLocalNotificationsPlugin?> _ios() async {
    if (!_initialized) {
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
    return _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final ios = await _ios();
      return await ios?.requestPermissions(alert: true, sound: true) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> showMixReady() async {
    try {
      await _ios();
      await _plugin.show(
        id: mixReadyId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
