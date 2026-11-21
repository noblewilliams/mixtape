import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';

void main() {
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  test('the bridge speaks the mixtape/haptics contract', () {
    expect(appDelegate, contains('"${Haptics.channelName}"'));
    expect(appDelegate, contains('hapticsBridge = HapticsBridge('));
    expect(appDelegate, contains('call.method == "play"'));
  });

  test('every style Dart sends is one the bridge plays', () {
    for (final style in HapticStyle.values) {
      expect(
        appDelegate,
        contains('"${style.name}"'),
        reason: '${style.name} is handled natively',
      );
    }
  });
}
