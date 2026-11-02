// Whether this device has seen the name page question settled for the
// signed-in account (2026-11-02 profile name). Only a hint for the root: an
// unsettled device waits behind the sign-in image for GET /me's askName, so
// an account that will be asked never sees the shell flash first. /me still
// decides; the flag is reset at every sign-in, so it never carries over
// from one account to the next.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class NamePageStore {
  Future<bool> read();
  Future<void> markSettled();
  Future<void> clear();
}

/// Keychain-backed, as [SecureServicePreferenceStore].
class SecureNamePageStore implements NamePageStore {
  SecureNamePageStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );
  final FlutterSecureStorage _storage;
  static const _key = 'name_page_settled';

  @override
  Future<bool> read() async => await _storage.read(key: _key) == '1';
  @override
  Future<void> markSettled() => _storage.write(key: _key, value: '1');
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryNamePageStore implements NamePageStore {
  InMemoryNamePageStore({bool settled = false}) : _settled = settled;
  bool _settled;
  @override
  Future<bool> read() async => _settled;
  @override
  Future<void> markSettled() async => _settled = true;
  @override
  Future<void> clear() async => _settled = false;
}
