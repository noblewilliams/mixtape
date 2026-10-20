import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('SecureTokenStore', () {
    test('an anonymous token survives a cold start with its flag', () async {
      await SecureTokenStore().write('anon-token', anonymous: true);

      // A fresh instance over the same keychain stands in for a relaunch.
      final relaunched = SecureTokenStore();
      expect(await relaunched.read(), 'anon-token');
      expect(await relaunched.readAnonymous(), isTrue);
    });

    test('an account token replaces an anonymous one and drops the flag',
        () async {
      final store = SecureTokenStore();
      await store.write('anon-token', anonymous: true);
      await store.write('account-token');

      final relaunched = SecureTokenStore();
      expect(await relaunched.read(), 'account-token');
      expect(await relaunched.readAnonymous(), isFalse);
    });

    test('clear removes the token and the flag', () async {
      final store = SecureTokenStore();
      await store.write('anon-token', anonymous: true);
      await store.clear();

      expect(await store.read(), isNull);
      expect(await store.readAnonymous(), isFalse);
    });
  });

  group('InMemoryTokenStore', () {
    test('tracks the anonymous flag alongside the token', () async {
      final store = InMemoryTokenStore();
      expect(await store.readAnonymous(), isFalse);
      await store.write('anon-token', anonymous: true);
      expect(await store.readAnonymous(), isTrue);
      await store.write('account-token');
      expect(await store.readAnonymous(), isFalse);
      await store.write('anon-token', anonymous: true);
      await store.clear();
      expect(await store.readAnonymous(), isFalse);
    });
  });
}
