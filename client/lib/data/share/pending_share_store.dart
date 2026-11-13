/// A shared mix opened before this device had a session (spec 2026-11-13
/// shared-mixes, Recipient in the app): its token waits here until a
/// session exists, then it is saved to that listener's Mixes.
///
/// One token, the latest opened: a second link opened before first run
/// replaces the first. A device preference, not user-scoped: it belongs to
/// whichever session appears next.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class PendingShareStore {
  /// The waiting token, or null.
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

/// Keychain-backed, like the music platform store.
class SecurePendingShareStore implements PendingShareStore {
  SecurePendingShareStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mixtape_pending_share_save';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryPendingShareStore implements PendingShareStore {
  InMemoryPendingShareStore([this._token]);
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
