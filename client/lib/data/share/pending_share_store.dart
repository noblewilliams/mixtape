/// A shared mix opened before this device had a session (spec 2026-11-13
/// shared-mixes, Recipient in the app): its token waits here until a
/// session exists, then it is saved to that listener's Mixes.
///
/// One token, the latest opened: a second link opened before first run
/// replaces the first. A device preference, not user-scoped: it belongs to
/// whichever session appears next — unless a session held it (a save that
/// failed and waits for a retry), which a sign-out or a later launch with no
/// session drops, so the next account on the device does not inherit it.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A waiting token, and whether a session held it when it was kept.
class PendingShare {
  const PendingShare(this.token, {this.heldWithSession = false});

  final String token;

  /// Kept while a session existed (a save to retry), not opened before one:
  /// it belongs to that session and goes when it does.
  final bool heldWithSession;
}

abstract class PendingShareStore {
  /// The waiting token, or null.
  Future<PendingShare?> read();
  Future<void> write(PendingShare share);
  Future<void> clear();
}

/// Keychain-backed, like the music platform store.
class SecurePendingShareStore implements PendingShareStore {
  SecurePendingShareStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mixtape_pending_share_save';
  final FlutterSecureStorage _storage;

  @override
  Future<PendingShare?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final token = json['token'];
      if (token is! String || token.isEmpty) return null;
      return PendingShare(
        token,
        heldWithSession: json['heldWithSession'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(PendingShare share) => _storage.write(
    key: _key,
    value: jsonEncode({
      'token': share.token,
      'heldWithSession': share.heldWithSession,
    }),
  );

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryPendingShareStore implements PendingShareStore {
  InMemoryPendingShareStore([this._share]);
  PendingShare? _share;

  @override
  Future<PendingShare?> read() async => _share;

  @override
  Future<void> write(PendingShare share) async => _share = share;

  @override
  Future<void> clear() async => _share = null;
}
