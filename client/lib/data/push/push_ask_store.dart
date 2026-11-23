// The device's two notification flags (spec 2026-11-21 durable mix turns →
// Asking for permission; `docs/mockups/approved/2026-11-21-push-permission-modal.md`).
//
// `asked`: the pop-up has appeared on this install, however it was closed,
// so it never appears again. `optedOut`: the listener turned "Mix ready
// notifications" off in You, so a launch does not register the phone again
// behind their back. Neither is cleared at sign-out.
//
// Install-scoped, in a file in the app's container (decision 2026-11-23):
// iOS forgets an app's notification permission when it is deleted but keeps
// its Keychain, so a Keychain flag told a reinstalled app it had already
// asked, and it never asked again (nor registered for pushes).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

abstract class PushAskStore {
  Future<bool> asked();
  Future<void> markAsked();
  Future<bool> optedOut();
  Future<void> setOptedOut(bool value);
}

/// Where builds before 2026-11-23 kept the flags.
abstract final class SecurePushAskStoreKeys {
  static const String asked = 'push_ask_shown';
  static const String optedOut = 'push_opted_out';
}

/// The flags as a small JSON file in Application Support, which goes with
/// the app. The first read moves the Keychain's flags out: the listener's
/// own off carries over; `asked` does not, since a Keychain flag cannot tell
/// this install's pop-up from an earlier install's (someone who tapped Not
/// now on this install sees it once more).
class FilePushAskStore implements PushAskStore {
  FilePushAskStore({
    Future<Directory> Function()? directory,
    FlutterSecureStorage? legacy,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _legacy =
           legacy ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock,
             ),
           );

  static const String fileName = 'push_flags.json';
  static const String _askedKey = 'asked';
  static const String _optedOutKey = 'optedOut';

  final Future<Directory> Function() _directory;
  final FlutterSecureStorage _legacy;
  Future<Map<String, bool>>? _flags;

  @override
  Future<bool> asked() async => (await _read())[_askedKey] ?? false;
  @override
  Future<void> markAsked() => _write(_askedKey, true);
  @override
  Future<bool> optedOut() async => (await _read())[_optedOutKey] ?? false;
  @override
  Future<void> setOptedOut(bool value) => _write(_optedOutKey, value);

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  Future<Map<String, bool>> _read() => _flags ??= _load();

  Future<Map<String, bool>> _load() async {
    final file = await _file();
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries)
              if (entry.key is String && entry.value is bool)
                entry.key as String: entry.value as bool,
          };
        }
      } catch (_) {}
      return {};
    }
    // No file: a fresh install, or the first launch of this build.
    var optedOut = false;
    try {
      optedOut =
          await _legacy.read(key: SecurePushAskStoreKeys.optedOut) == '1';
      await _legacy.delete(key: SecurePushAskStoreKeys.asked);
      await _legacy.delete(key: SecurePushAskStoreKeys.optedOut);
    } catch (_) {}
    final flags = {if (optedOut) _optedOutKey: true};
    await _save(file, flags);
    return flags;
  }

  Future<void> _write(String key, bool value) async {
    final flags = {...await _read(), key: value};
    _flags = Future.value(flags);
    await _save(await _file(), flags);
  }

  Future<void> _save(File file, Map<String, bool> flags) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(flags), flush: true);
  }
}

class InMemoryPushAskStore implements PushAskStore {
  InMemoryPushAskStore({bool asked = false, bool optedOut = false})
    : _asked = asked,
      _optedOut = optedOut;
  bool _asked;
  bool _optedOut;

  /// How many times the pop-up marked itself shown, for tests.
  int marks = 0;

  @override
  Future<bool> asked() async => _asked;
  @override
  Future<void> markAsked() async {
    marks++;
    _asked = true;
  }

  @override
  Future<bool> optedOut() async => _optedOut;
  @override
  Future<void> setOptedOut(bool value) async => _optedOut = value;
}
