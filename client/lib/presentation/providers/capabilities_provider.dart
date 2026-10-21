// What this listener's server offers, read from `GET /me` once per auth
// generation (album picks spec 2026-10-20 → the capability flag).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/account_api.dart';
import 'account_provider.dart';
import 'auth_provider.dart';

/// `GET /me` for the signed-in listener, fetched once per auth generation
/// (sign-in, sign-out and the anonymous-to-account link all rebuild it).
/// Null without a session. Reading `/me` consumes `merged` server-side, so
/// this is the app's only `/me` reader: the merge notice
/// (`mergedModeReaderProvider`) and the account name (`accountNameProvider`)
/// derive from it. A new `/me` consumer must too, never call the API itself.
///
/// No retry, as the onboarding read: a failed read leaves album picks off
/// until the next auth transition (or an explicit invalidate), and never
/// leaves a retry timer running behind a screen.
final meProvider = FutureProvider<Me?>((ref) async {
  if (ref.watch(authProvider) != AuthStatus.session) return null;
  return ref.watch(accountApiProvider).me();
}, retry: (_, _) => null);

/// Album picks are offered only to a signed-in account (never anonymous,
/// decision 2026-10-20) whose server says the flag is on. False while `/me`
/// is loading or after it failed: the Mix-only app is the safe default.
final albumPicksEnabledProvider = Provider<bool>((ref) {
  if (ref.watch(authProvider) != AuthStatus.session) return false;
  if (ref.watch(isAnonymousProvider)) return false;
  return ref.watch(meProvider).unwrapPrevious().value?.albumPicks ?? false;
});
