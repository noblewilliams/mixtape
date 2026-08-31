import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native library paging filters unsupported Apple catalog IDs', () {
    final source = File('ios/Runner/MusicKitBridge.swift').readAsStringSync();

    expect(source, contains(r'^[A-Za-z0-9._~-]{1,128}$'));
    expect(source, contains('isSupportedAppleSongID'));
    expect(
      source,
      contains(r'isSupportedAppleSongID($0.playbackStoreID)'),
    );
  });
}
