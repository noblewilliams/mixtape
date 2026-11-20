// Over-the-air patches (Shorebird code push). A patch downloads in the
// background and only runs from the next process start, so the app tells the
// listener when one is ready and offers to close so it can apply (decision
// 2026-11-20, OTA updates). Auto-update is off in shorebird.yaml: this file
// owns every check and download, so the UI always knows where things stand.
import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

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
