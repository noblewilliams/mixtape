// The server flags the first-run flow reads before any session exists
// (everyone-gets-a-mix plan → Task 8).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/config/config_api.dart';
import 'auth_provider.dart';

final configApiProvider = Provider<ConfigApi>(
  (ref) => ConfigApi(ref.watch(apiClientProvider)),
);

/// `GET /health`'s flags, read once per first-run flow: the flow's pages keep it
/// alive while they are up, and it does not watch auth, so the anonymous
/// sign-in mid-flow does not refetch it. Disposed when the flow hands off,
/// so a later flow (after a sign-out, say) reads it afresh. Any failure is
/// every flag off.
final firstRunFlagsProvider = FutureProvider.autoDispose<FirstRunFlags>((
  ref,
) async {
  try {
    return await ref.watch(configApiProvider).flags();
  } catch (_) {
    return FirstRunFlags.off;
  }
}, retry: (_, _) => null);
