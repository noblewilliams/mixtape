// The two funnel milestones the client posts once per listener (plan:
// funnel events): `first_personal_mix`, when a session's queue comes back
// personal after any completed import, and `first_output`, on the first
// Spotify output action (or Play). Fire-and-forget like session events:
// nothing here blocks the UI or surfaces an error, and the server tolerates
// a repeat, so the per-device flag is a courtesy filter rather than a lock.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/dj/dj_models.dart';
import '../../data/listening/listening_models.dart';
import '../../data/onboarding/funnel_once_store.dart';
import 'auth_provider.dart';
import 'device_providers.dart';
import 'onboarding_provider.dart';

class FunnelMilestones {
  FunnelMilestones(this._ref);

  final Ref _ref;

  /// Keys posted, or in flight, since this instance was built: two outputs
  /// in the same second would otherwise both pass the keychain check. Per
  /// instance, so it resets with the listener (the provider rebuilds on
  /// every auth transition).
  final Set<String> _settled = {};

  /// Posts [type] once for the signed-in listener: `first_output` from any
  /// of the queue screen's output actions.
  void recordOnce(FunnelEventType type) => unawaited(_recordOnce(type, gate: null));

  /// `first_personal_mix`: [session] came back with a queue built from the
  /// listener's own plays. Nothing before an import counts — an Apple
  /// listener's every mix is personal, but the funnel measures the Spotify
  /// import, so the gate is a completed import on any device.
  void notePersonalMix(DjSession session, List<QueueTrack> queue) {
    if (session.notPersonal || queue.isEmpty) return;
    unawaited(
      _recordOnce(FunnelEventType.firstPersonalMix, gate: (o) => o.hasCompletedImport),
    );
  }

  Future<void> _recordOnce(
    FunnelEventType type, {
    required bool Function(OnboardingState onboarding)? gate,
  }) async {
    String? key;
    try {
      // The onboarding read is the client's only source of the listener's
      // id; it is loaded before any signed-in screen shows, so this resolves
      // at once in practice. A sign-out mid-await rejects and is swallowed.
      final onboarding = await _ref.read(onboardingProvider.future);
      if (gate != null && !gate(onboarding)) return;
      key = funnelOnceKey(type, onboarding.userId);
      if (!_settled.add(key)) return;
      final store = _ref.read(funnelOnceStoreProvider);
      if (await store.has(onboarding.userId, type)) return;
      await _ref.read(listeningApiProvider).postFunnelEvent(type);
      await store.mark(onboarding.userId, type);
    } catch (_) {
      // Silent by design — no retry now, no surfaced error. Releasing the
      // key lets the next output try again (a dropped post, an unwritable
      // keychain); the server tolerates the repeat either way.
      if (key != null) _settled.remove(key);
    }
  }
}

final funnelMilestonesProvider = Provider<FunnelMilestones>((ref) {
  ref.watch(authProvider); // user-scoped: the in-flight set resets with the listener
  return FunnelMilestones(ref);
});
