// The device's two notification flags (spec 2026-11-21 durable mix turns →
// Asking for permission; `docs/mockups/approved/2026-11-21-push-permission-modal.md`).
//
// `push_ask_shown`: the pop-up has appeared on this device, however it was
// closed, so it never appears again. `push_opted_out`: the listener turned
// "Mix ready notifications" off in You, so a launch does not register the
// phone again behind their back. Both are device-scoped, like the name
// page's flag beside them, and neither is cleared at sign-out.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class PushAskStore {
  Future<bool> asked();
  Future<void> markAsked();
  Future<bool> optedOut();
  Future<void> setOptedOut(bool value);
}

/// Keychain-backed, as [SecureNamePageStore].
class SecurePushAskStore implements PushAskStore {
  SecurePushAskStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );
  final FlutterSecureStorage _storage;

  static const String askedKey = 'push_ask_shown';
  static const String optedOutKey = 'push_opted_out';

  @override
  Future<bool> asked() async => await _storage.read(key: askedKey) == '1';
  @override
  Future<void> markAsked() => _storage.write(key: askedKey, value: '1');
  @override
  Future<bool> optedOut() async => await _storage.read(key: optedOutKey) == '1';
  @override
  Future<void> setOptedOut(bool value) => value
      ? _storage.write(key: optedOutKey, value: '1')
      : _storage.delete(key: optedOutKey);
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
