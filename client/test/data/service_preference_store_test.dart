import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';

void main() {
  test('a stored choice reads back only for the account that made it', () async {
    final store = InMemoryServicePreferenceStore();
    expect(await store.read('a'), isNull);

    await store.write('a', 'apple');
    expect(await store.read('a'), 'apple');
    expect(await store.read('b'), isNull);

    // One flag per device: the next account's choice replaces the last.
    await store.write('b', 'spotify');
    expect(await store.read('b'), 'spotify');
    expect(await store.read('a'), isNull);

    await store.clear();
    expect(await store.read('b'), isNull);
  });

  test('the keychain encoding is <userId>:<service>, split at the last colon', () {
    expect(encodeServicePreference('user-1', 'apple'), 'user-1:apple');
    expect(decodeServicePreference('user-1:apple', 'user-1'), 'apple');
    expect(decodeServicePreference('user-1:apple', 'user-2'), isNull);
    expect(decodeServicePreference('x:y:spotify', 'x:y'), 'spotify');
    expect(decodeServicePreference('x:y:spotify', 'x'), isNull);
    expect(decodeServicePreference(null, 'user-1'), isNull);
    expect(decodeServicePreference('apple', 'apple'), isNull, reason: 'no id');
    expect(decodeServicePreference(':apple', ''), isNull, reason: 'empty id');
    expect(decodeServicePreference('user-1:', 'user-1'), isNull, reason: 'empty service');
  });
}
