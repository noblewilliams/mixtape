import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/push/push_ask_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const keychain = FlutterSecureStorage();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('push_ask_store_test');
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  FilePushAskStore store() =>
      FilePushAskStore(directory: () async => dir, legacy: keychain);

  test('a fresh install has not asked and has not opted out', () async {
    expect(await store().asked(), isFalse);
    expect(await store().optedOut(), isFalse);
  });

  test('both flags persist across launches of the same install', () async {
    await store().markAsked();
    await store().setOptedOut(true);
    expect(await store().asked(), isTrue);
    expect(await store().optedOut(), isTrue);
    await store().setOptedOut(false);
    expect(await store().optedOut(), isFalse);
  });

  test(
    'a reinstall (the container emptied) asks again: the Keychain flag does not carry over',
    () async {
      // What a build before this one left in the Keychain, which iOS keeps
      // across a delete and reinstall.
      FlutterSecureStorage.setMockInitialValues({
        SecurePushAskStoreKeys.asked: '1',
      });
      expect(await store().asked(), isFalse);
      // And it is gone, so no later reinstall finds it either.
      expect(await keychain.read(key: SecurePushAskStoreKeys.asked), isNull);
    },
  );

  test(
    "the listener's own off in You carries over from the Keychain once",
    () async {
      FlutterSecureStorage.setMockInitialValues({
        SecurePushAskStoreKeys.optedOut: '1',
      });
      expect(await store().optedOut(), isTrue);
      expect(await keychain.read(key: SecurePushAskStoreKeys.optedOut), isNull);
      // Read from the file afterwards.
      expect(await store().optedOut(), isTrue);
    },
  );

  test('an unreadable file reads as a fresh install', () async {
    File(
      '${dir.path}/${FilePushAskStore.fileName}',
    ).writeAsStringSync('not json');
    expect(await store().asked(), isFalse);
    await store().markAsked();
    expect(await store().asked(), isTrue);
  });
}
