import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The bearer token plus whether it belongs to an anonymous session.
///
/// The flag is persisted next to the token rather than re-read from `GET /me`
/// on restore, so a cold start knows anonymous from account without a
/// network call (the root switch and the You row read it offline).
abstract class TokenStore {
  Future<String?> read();

  /// True only while the stored token is an anonymous session's. Clearing or
  /// writing an account token resets it.
  Future<bool> readAnonymous();
  Future<void> write(String token, {bool anonymous = false});
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );
  final FlutterSecureStorage _storage;
  static const _key = 'auth_token';
  static const _anonymousKey = 'auth_token_anonymous';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<bool> readAnonymous() async =>
      await _storage.read(key: _anonymousKey) == 'true';

  // Two keychain items can't be written atomically, so each write orders them
  // so an interruption errs towards "anonymous": that state still offers
  // sign-in, whereas an anonymous token mistaken for an account has no way
  // back to linking.
  @override
  Future<void> write(String token, {bool anonymous = false}) async {
    if (anonymous) {
      await _storage.write(key: _anonymousKey, value: 'true');
      await _storage.write(key: _key, value: token);
    } else {
      await _storage.write(key: _key, value: token);
      await _storage.delete(key: _anonymousKey);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _anonymousKey);
  }
}

class InMemoryTokenStore implements TokenStore {
  String? _token;
  bool _anonymous = false;
  @override
  Future<String?> read() async => _token;
  @override
  Future<bool> readAnonymous() async => _anonymous;
  @override
  Future<void> write(String token, {bool anonymous = false}) async {
    _token = token;
    _anonymous = anonymous;
  }

  @override
  Future<void> clear() async {
    _token = null;
    _anonymous = false;
  }
}
