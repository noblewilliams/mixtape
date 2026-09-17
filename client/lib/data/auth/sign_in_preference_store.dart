import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'account_api.dart';

/// A convenience hint, never proof of authentication or account identity.
abstract class SignInPreferenceStore {
  Future<AccountProvider?> read();
  Future<void> write(AccountProvider provider);

  static AccountProvider? parse(String? value) => switch (value) {
    'apple' => AccountProvider.apple,
    'google' => AccountProvider.google,
    _ => null,
  };
}

class SecureSignInPreferenceStore implements SignInPreferenceStore {
  SecureSignInPreferenceStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'last_sign_in_provider';

  @override
  Future<AccountProvider?> read() async =>
      SignInPreferenceStore.parse(await _storage.read(key: _key));

  @override
  Future<void> write(AccountProvider provider) =>
      _storage.write(key: _key, value: provider.name);
}

class InMemorySignInPreferenceStore implements SignInPreferenceStore {
  AccountProvider? _provider;
  @override
  Future<AccountProvider?> read() async => _provider;
  @override
  Future<void> write(AccountProvider provider) async => _provider = provider;
}
