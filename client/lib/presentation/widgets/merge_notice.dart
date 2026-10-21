/// The merge notice (board frame C4; first-run spec → The merge, Copy): how
/// an anonymous listener's mixes landed on the account they signed in with.
/// `GET /me` reports it once and the server clears it on read.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/account_api.dart';
import '../providers/auth_provider.dart';
import '../providers/capabilities_provider.dart';

abstract final class MergeNotice {
  static const String mixesOnly =
      'Your mixes are in. This account already had a library, so we kept '
      'that one.';
  static const String libraryKept =
      'This account already had a library, so we kept that one.';

  /// Two lines of reading, so longer than the app's 4 s toasts.
  static const Duration duration = Duration(seconds: 6);

  /// The sentence for [merged], or null when there is nothing to say (`all`
  /// moved everything into a new account; null is no link at all).
  static String? messageFor(MergedMode? merged) => switch (merged) {
    MergedMode.mixesOnly => mixesOnly,
    MergedMode.libraryKept => libraryKept,
    MergedMode.all || null => null,
  };
}

/// Reads `merged` from the one `GET /me` [meProvider] makes per auth
/// generation, so a capability read can't consume it first. Answers it once
/// per `/me` read, as the server does. A provider so tests can answer it.
final mergedModeReaderProvider = Provider<Future<MergedMode?> Function()>((
  ref,
) {
  ref.watch(authProvider);
  Me? answered;
  return () async {
    final me = await ref.read(meProvider.future);
    if (me == null || identical(me, answered)) return null;
    answered = me;
    return me.merged;
  };
});

/// The notice to show now, if any. Never throws: a failed read says nothing.
Future<String?> readMergeNotice(WidgetRef ref) async {
  try {
    return MergeNotice.messageFor(await ref.read(mergedModeReaderProvider)());
  } catch (_) {
    return null;
  }
}
