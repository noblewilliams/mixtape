// The per-user, per-device "service chosen" flag (plan: service gate
// persistence). Choosing Apple records nothing on the server, so the gate
// consults this alongside the onboarding read. It is keyed by user id so a
// device shared between accounts never shows one listener the other's
// choice, and it is cleared on sign-out.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class ServicePreferenceStore {
  /// The service [userId] chose on this device: null when nothing is stored
  /// or the stored choice belongs to another account.
  Future<String?> read(String userId);
  Future<void> write(String userId, String service);
  Future<void> clear();
}

/// Keychain-backed, mirroring [SecureTokenStore]: one key holding
/// `<userId>:<service>`.
class SecureServicePreferenceStore implements ServicePreferenceStore {
  SecureServicePreferenceStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );
  final FlutterSecureStorage _storage;
  static const _key = 'service_chosen';

  @override
  Future<String?> read(String userId) async =>
      decodeServicePreference(await _storage.read(key: _key), userId);
  @override
  Future<void> write(String userId, String service) =>
      _storage.write(key: _key, value: encodeServicePreference(userId, service));
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Same encoding as the keychain store, so tests exercise the user-id match.
class InMemoryServicePreferenceStore implements ServicePreferenceStore {
  String? _raw;
  @override
  Future<String?> read(String userId) async => decodeServicePreference(_raw, userId);
  @override
  Future<void> write(String userId, String service) async =>
      _raw = encodeServicePreference(userId, service);
  @override
  Future<void> clear() async => _raw = null;
}

String encodeServicePreference(String userId, String service) {
  assert(!service.contains(':'), 'service names never contain ":"');
  return '$userId:$service';
}

/// The service in [raw] when it was stored for [userId]. A service name never
/// contains ':', so the split is at the last one; the id may contain any.
String? decodeServicePreference(String? raw, String userId) {
  if (raw == null) return null;
  final split = raw.lastIndexOf(':');
  if (split <= 0 || split == raw.length - 1) return null;
  return raw.substring(0, split) == userId ? raw.substring(split + 1) : null;
}
