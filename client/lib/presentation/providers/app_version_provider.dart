/// The build line at the foot of You ("Mixtape 1.2.0 (15) · 3"), so a
/// tester can tell which binary and over-the-air patch is running.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_update_provider.dart';
import 'push_provider.dart';

/// Null when the binary cannot say (off iOS, or a build older than 1.2.0
/// (15), whose native side has no version call): the line is then left out.
final appVersionLabelProvider = FutureProvider<String?>((ref) async {
  final String? version;
  try {
    version = await ref.watch(pushChannelProvider).appVersion();
  } catch (_) {
    return null;
  }
  if (version == null || version.isEmpty) return null;
  final patch = await ref.watch(appUpdaterProvider).currentPatch();
  return patch == null ? 'Mixtape $version' : 'Mixtape $version · $patch';
});
