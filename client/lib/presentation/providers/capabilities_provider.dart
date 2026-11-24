// What this listener's server offers, read from `GET /me` once per auth
// generation (album picks spec 2026-10-20 → the capability flag).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/account_api.dart';
import '../../data/auth/album_picks_memory.dart';
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

final albumPicksMemoryProvider = Provider<AlbumPicksMemory>(
  (ref) => FileAlbumPicksMemory(),
);

/// The album-picks answer this device last had from `/me`, read at launch,
/// so a cold start draws Home's composer row in its final layout instead of
/// the Mix-only row and then the toggle two seconds later (launch glitch,
/// 2026-11-24). Every `/me` answer for an account replaces it; signing out
/// forgets it, so the next account starts from nothing.
class RememberedAlbumPicks extends Notifier<bool?> {
  /// Set once `/me` or a sign-out has spoken: a slow launch read must not
  /// overwrite either.
  bool _settled = false;

  @override
  bool? build() {
    final memory = ref.watch(albumPicksMemoryProvider);
    unawaited(
      memory.read().then((value) {
        if (ref.mounted && !_settled) state = value;
      }),
    );
    ref.listen(authProvider, (_, next) {
      if (next != AuthStatus.noSession) return;
      _settled = true;
      state = null;
      unawaited(memory.clear());
    });
    ref.listen(meProvider, (_, next) {
      // A reload still carries the last answer; only a fresh one counts,
      // and only while signed in (a sign-out reloads `/me` to null).
      if (next.isLoading || ref.read(authProvider) != AuthStatus.session) {
        return;
      }
      final me = next.value;
      if (me == null || me.isAnonymous) return;
      _settled = true;
      if (state != me.albumPicks) state = me.albumPicks;
      unawaited(memory.write(me.albumPicks));
    });
    return null;
  }
}

final rememberedAlbumPicksProvider =
    NotifierProvider<RememberedAlbumPicks, bool?>(RememberedAlbumPicks.new);

/// Album picks are offered only to a signed-in account (never anonymous,
/// decision 2026-10-20) whose server says the flag is on. While the first
/// `/me` is loading it is the answer this device last had
/// ([rememberedAlbumPicksProvider]), or off with none; after a failed read
/// it is off: the Mix-only app is the safe default.
///
/// An explicit refresh (`ref.invalidate(meProvider)` after a name save) keeps
/// the last answer while it rereads, and if the reread fails, so saving a
/// name never drops the listener out of Albums. A rebuild from an auth
/// change (reloading) does not carry it over; sign-out passes through a null
/// `/me` anyway.
final albumPicksEnabledProvider = Provider<bool>((ref) {
  if (ref.watch(authProvider) != AuthStatus.session) return false;
  if (ref.watch(isAnonymousProvider)) return false;
  final me = ref.watch(meProvider);
  final current = me.isReloading ? me.unwrapPrevious() : me;
  if (current.hasValue) return current.value?.albumPicks ?? false;
  if (current.isLoading)
    return ref.watch(rememberedAlbumPicksProvider) ?? false;
  return false;
});
