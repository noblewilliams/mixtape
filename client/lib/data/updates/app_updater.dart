// Over-the-air patches (Shorebird code push). A patch downloads in the
// background and only runs from the next process start, so the app tells the
// listener when one is ready and offers to close so it can apply (decision
// 2026-11-20, OTA updates; the countdown, reopen notice and quiet apply are
// decision 2026-11-24). Auto-update is off in shorebird.yaml: this file
// owns every check and download, so the UI always knows where things stand.
import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:timezone/timezone.dart' as tz;

/// The device side of code push, faked in tests.
abstract class AppUpdater {
  /// False in debug and in any build not made with `shorebird release`.
  bool get isAvailable;

  /// The patch running now; null for the release as shipped.
  Future<int?> currentPatch();

  /// Checks for a newer patch and downloads it. Returns the number of the
  /// patch that runs from the next start when one is waiting, else null.
  /// Never throws: a failed check or download is "nothing new".
  Future<int?> downloadNewPatch();

  /// Ends the process so the next open boots the new patch. iOS cannot
  /// relaunch an app, so the listener opens it again themselves.
  Future<void> close();
}

class ShorebirdAppUpdater implements AppUpdater {
  ShorebirdAppUpdater([ShorebirdUpdater? updater]) : _given = updater;

  final ShorebirdUpdater? _given;

  // Shorebird only patches release builds. Debug runs and tests never touch
  // its engine bindings (which print a banner when absent).
  late final ShorebirdUpdater? _shorebird =
      _given ?? (kReleaseMode ? ShorebirdUpdater() : null);
  ShorebirdUpdater get _updater => _shorebird!;

  @override
  bool get isAvailable => _shorebird?.isAvailable ?? false;

  @override
  Future<int?> currentPatch() async {
    if (!isAvailable) return null;
    try {
      return (await _updater.readCurrentPatch())?.number;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> downloadNewPatch() async {
    if (!isAvailable) return null;
    try {
      final status = await _updater.checkForUpdate();
      if (status == UpdateStatus.outdated) await _updater.update();
      if (status == UpdateStatus.upToDate ||
          status == UpdateStatus.unavailable) {
        return null;
      }
      final current = (await _updater.readCurrentPatch())?.number;
      final next = (await _updater.readNextPatch())?.number;
      // restartRequired also follows a rollback, where the next patch is
      // older (or none): that is not an update worth announcing.
      if (next == null || (current != null && next <= current)) return null;
      return next;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() async => exit(0);
}

/// The "tap to reopen" banner the app leaves behind when it closes to update
/// (approval docs/mockups/approved/2026-11-24-ota-restart-countdown.md).
abstract class UpdateReopenNotice {
  /// Schedules the banner [after] from now, but only when notifications are
  /// already allowed: the app never asks for permission for this.
  Future<void> schedule({required Duration after});

  /// Drops a banner still waiting (a launch before it went off).
  Future<void> cancel();
}

/// [UpdateReopenNotice] over `flutter_local_notifications`. Fixed copy only.
class LocalUpdateReopenNotice implements UpdateReopenNotice {
  LocalUpdateReopenNotice({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// The Spotify request reminder is 1, the mix-ready alert 2.
  static const int id = 3;
  static const String title = 'mixtape is up to date';
  static const String body = 'Tap to jump back in.';

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
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
  }

  @override
  Future<void> schedule({required Duration after}) async {
    final ios = await _ios();
    if (ios == null) return;
    final allowed = await ios.checkPermissions();
    if (allowed == null || !allowed.isEnabled || !allowed.isAlertEnabled) {
      return;
    }
    // A UTC instant needs no time-zone database (as the request reminder).
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.now(tz.UTC).add(after),
      notificationDetails: const NotificationDetails(
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancel() async {
    await _ios();
    await _plugin.cancel(id: id);
  }
}

/// The patch the app last told the listener it was closing (or would next
/// start) to apply. Read and cleared once at launch: when the patch running
/// matches, the launch shows "Updated".
abstract class PendingPatchStore {
  Future<int?> read();
  Future<void> write(int patch);
  Future<void> clear();
}

class SecurePendingPatchStore implements PendingPatchStore {
  SecurePendingPatchStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _storage;
  static const String key = 'ota_pending_patch';

  @override
  Future<int?> read() async =>
      int.tryParse(await _storage.read(key: key) ?? '');
  @override
  Future<void> write(int patch) => _storage.write(key: key, value: '$patch');
  @override
  Future<void> clear() => _storage.delete(key: key);
}

class InMemoryPendingPatchStore implements PendingPatchStore {
  int? value;
  @override
  Future<int?> read() async => value;
  @override
  Future<void> write(int patch) async => value = patch;
  @override
  Future<void> clear() async => value = null;
}
