// The build line at the foot of You: which binary and patch is running, so a
// tester can tell builds apart.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/app_update_provider.dart';
import 'package:mixtape/presentation/providers/app_version_provider.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';

import '../../helpers/fake_push_channel.dart';
import 'app_update_provider_test.dart' show FakeAppUpdater;

class _ThrowingChannel extends FakePushChannel {
  @override
  Future<String?> appVersion() async =>
      throw MissingPluginException('no channel in this binary');
}

class _SilentChannel extends FakePushChannel {
  @override
  Future<String?> appVersion() async => null;
}

Future<String?> _label({FakePushChannel? channel, int? patch}) {
  final container = ProviderContainer(
    overrides: [
      pushChannelProvider.overrideWithValue(channel ?? FakePushChannel()),
      appUpdaterProvider.overrideWithValue(FakeAppUpdater(running: patch)),
    ],
  );
  addTearDown(container.dispose);
  return container.read(appVersionLabelProvider.future);
}

void main() {
  test('the release as shipped reads its version and build', () async {
    expect(await _label(), 'Mixtape 1.2.0 (15)');
  });

  test('a running patch is named after the build', () async {
    expect(await _label(patch: 3), 'Mixtape 1.2.0 (15) · patch 3');
  });

  test('no version from the binary hides the line', () async {
    expect(await _label(channel: _SilentChannel()), isNull);
  });

  test('a binary without the channel hides the line', () async {
    expect(await _label(channel: _ThrowingChannel()), isNull);
  });
}
