// The name page (2026-11-02 profile name; board
// `docs/mockups/2026-11-02-profile-name-states.html` section 1): "What
// should we call you?", once per account after a sign-in that leaves no
// usable name, and once at launch for an existing account in that state.
// GET /me's askName decides; the client never recomputes the name rule.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/name_page_store.dart';
import '../widgets/merge_notice.dart';
import 'account_provider.dart';
import 'auth_provider.dart';
import 'capabilities_provider.dart';

final namePageStoreProvider = Provider<NamePageStore>(
  (ref) => SecureNamePageStore(),
);

/// The device flag ([NamePageStore]): null while it loads. Device-scoped on
/// purpose, like the token beside it: [reset] at every sign-in is what keeps
/// it from carrying over between accounts. A flag that cannot be read counts
/// as settled, so a failing keychain never holds the shell on an image; the
/// page still appears if /me asks.
class NamePageSettledNotifier extends Notifier<bool?> {
  int _operation = 0;

  @override
  bool? build() {
    final operation = ++_operation;
    unawaited(_load(operation));
    return null;
  }

  Future<void> _load(int operation) async {
    bool settled;
    try {
      settled = await ref.read(namePageStoreProvider).read();
    } catch (_) {
      settled = true;
    }
    if (!ref.mounted || operation != _operation) return;
    state = settled;
  }

  /// The question is answered for this account on this device: /me said no,
  /// or the listener chose Continue or Skip.
  void markSettled() {
    _operation++;
    if (state == true) return;
    state = true;
    _write((store) => store.markSettled());
  }

  /// A sign-in: whoever it is, wait for /me before showing the shell.
  void reset() {
    _operation++;
    state = false;
    _write((store) => store.clear());
  }

  void _write(Future<void> Function(NamePageStore store) write) {
    final store = ref.read(namePageStoreProvider);
    unawaited(
      Future.sync(() => write(store)).catchError((Object _) {
        if (kDebugMode) debugPrint('name page flag write failed');
      }),
    );
  }
}

final namePageSettledProvider =
    NotifierProvider<NamePageSettledNotifier, bool?>(
      NamePageSettledNotifier.new,
    );

/// The page's own actions and whether it has been closed in this auth
/// generation. User-scoped: an auth transition reopens the question for
/// whoever is signed in next. The writes live here, not in the widget, so a
/// save that Skip leaves running still refreshes `/me` after the page is
/// gone.
class NamePageNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(authProvider);
    return false;
  }

  /// Continue: the name and the asked flag, then the stored name from `/me`
  /// (Account, You and the save dialog derive from it), then the shell.
  /// Throws when the write fails; the page stays open with the text.
  Future<void> save(String name) async {
    final api = ref.read(accountApiProvider);
    await api.updateUser(name: name);
    if (!ref.mounted) return;
    if (!state) {
      // The reread below consumes nothing new, but the server cleared
      // `merged` on the first read: keep it for Home, which has not mounted.
      ref
          .read(heldMergeProvider.notifier)
          .hold(ref.read(meProvider).value?.merged);
    }
    ref.invalidate(meProvider);
    try {
      await ref.read(meProvider.future);
    } catch (_) {
      // The write landed; a failed reread only leaves the name stale.
    }
    if (!ref.mounted) return;
    _close();
  }

  /// Continue on the page Share opens (spec 2026-11-13 shared-mixes, rule
  /// 3): the name and the asked flag, then `/me` again so the name shows
  /// where the app reads it. Anonymous listeners may save one too. It
  /// answers the question for this account, so the first-run ask does not
  /// follow. Throws when the write fails; the page stays open with the text.
  Future<void> saveForShare(String name) async {
    final api = ref.read(accountApiProvider);
    await api.updateUser(name: name);
    if (!ref.mounted) return;
    ref.invalidate(meProvider);
    try {
      await ref.read(meProvider.future);
    } catch (_) {
      // The write landed; a failed reread only leaves the name stale.
    }
    if (!ref.mounted) return;
    _close();
  }

  /// Skip: moves on at once and records that it was asked. The device is
  /// settled only once that write lands; if it fails, the next launch waits
  /// for `/me` again and the page may show once more, as on web.
  void skip() {
    final api = ref.read(accountApiProvider);
    final settled = ref.read(namePageSettledProvider.notifier);
    state = true;
    unawaited(
      Future.sync(() => api.updateUser()).then(
        (_) => settled.markSettled(),
        onError: (Object _) {
          if (kDebugMode) debugPrint('name page skip flag write failed');
        },
      ),
    );
  }

  void _close() {
    ref.read(namePageSettledProvider.notifier).markSettled();
    state = true;
  }
}

final namePageProvider = NotifierProvider<NamePageNotifier, bool>(
  NamePageNotifier.new,
);

/// How long the sign-in image may wait for `/me` before the shell shows
/// anyway (web's hold is the same). A `/me` that asks later still opens the
/// page over it.
const Duration nameHoldTimeout = Duration(milliseconds: 3500);

/// The hold ran out in this auth generation. Set by the root's timer.
class NameHoldExpiredNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(authProvider);
    return false;
  }

  void expire() => state = true;
}

final nameHoldExpiredProvider = NotifierProvider<NameHoldExpiredNotifier, bool>(
  NameHoldExpiredNotifier.new,
);

/// What the account root shows.
enum NameGate {
  /// The device flag is still loading: the launch placeholder continues.
  wait,

  /// `/me` has not answered and this device may be asked: the sign-in image
  /// alone, so the shell never flashes before the page.
  hold,

  /// The page.
  ask,

  /// The shell.
  off,
}

final nameGateProvider = Provider<NameGate>((ref) {
  if (ref.watch(authProvider) != AuthStatus.session) return NameGate.off;
  if (ref.watch(isAnonymousProvider)) return NameGate.off;
  if (ref.watch(namePageProvider)) return NameGate.off;
  final me = ref.watch(meProvider);
  // After an auth change `/me` reloads carrying the previous session's
  // answer (the anonymous listener's, or nothing): that is no answer for
  // this account. Continue's own reread is a refresh and keeps its value.
  if (!me.isReloading) {
    if (me.hasValue) {
      return me.value?.askName == true ? NameGate.ask : NameGate.off;
    }
    if (me.hasError) return NameGate.off;
  }
  if (ref.watch(nameHoldExpiredProvider)) return NameGate.off;
  return switch (ref.watch(namePageSettledProvider)) {
    null => NameGate.wait,
    true => NameGate.off,
    false => NameGate.hold,
  };
});
