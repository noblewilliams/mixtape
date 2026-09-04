// The per-user, per-device "already posted" flags for the two funnel
// milestones the client fires once (`first_personal_mix`, `first_output`;
// plan: funnel events). The server tolerates duplicates, so this is a
// courtesy filter, not a guarantee: a flag is keyed by user id so a device
// shared between accounts never silences one listener because of the
// other, and every flag is cleared on sign-out with the service flag.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../listening/listening_models.dart';

abstract class FunnelOnceStore {
  /// Whether [userId] already posted [type] from this device.
  Future<bool> has(String userId, FunnelEventType type);
  Future<void> mark(String userId, FunnelEventType type);
  Future<void> clear();
}

/// Keychain-backed, mirroring [SecureServicePreferenceStore]: one key per
/// milestone and listener, so [clear] drops only this store's keys.
class SecureFunnelOnceStore implements FunnelOnceStore {
  SecureFunnelOnceStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );
  final FlutterSecureStorage _storage;

  @override
  Future<bool> has(String userId, FunnelEventType type) async =>
      await _storage.read(key: funnelOnceKey(type, userId)) != null;
  @override
  Future<void> mark(String userId, FunnelEventType type) =>
      _storage.write(key: funnelOnceKey(type, userId), value: '1');
  @override
  Future<void> clear() async {
    final all = await _storage.readAll();
    for (final key in all.keys.where(isFunnelOnceKey)) {
      await _storage.delete(key: key);
    }
  }
}

/// Same keys as the keychain store, so tests exercise the user-id match.
class InMemoryFunnelOnceStore implements FunnelOnceStore {
  final Set<String> _keys = {};
  @override
  Future<bool> has(String userId, FunnelEventType type) async =>
      _keys.contains(funnelOnceKey(type, userId));
  @override
  Future<void> mark(String userId, FunnelEventType type) async =>
      _keys.add(funnelOnceKey(type, userId));
  @override
  Future<void> clear() async => _keys.clear();
}

const _prefix = 'funnel:';

/// `funnel:<type>:<userId>` — the wire name of the event, then the id (which
/// may itself contain any character; nothing ever parses this back).
String funnelOnceKey(FunnelEventType type, String userId) => '$_prefix${type.wire}:$userId';

bool isFunnelOnceKey(String key) => key.startsWith(_prefix);
