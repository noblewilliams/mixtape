// AI consent (plan `docs/superpowers/plans/2026-11-02-ai-consent-and-privacy.md`):
// whether this listener still has to agree before the app sends anything to
// the DJ, read from the one `GET /me` reader ([meProvider]).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/account_api.dart';
import 'account_provider.dart';
import 'auth_provider.dart';
import 'capabilities_provider.dart';

class AiConsentState {
  const AiConsentState({
    this.granted = false,
    this.dismissed = false,
    this.required = false,
  });

  /// The server answered `403 ai_consent_required` to a send: whatever `/me`
  /// said, every later send asks first until a grant.
  final bool required;

  /// Agreed on this device during this auth generation. Overrides a `/me`
  /// read made before the grant, so the app never refetches `/me` (which
  /// would consume `merged`) just to learn what it already knows.
  final bool granted;

  /// Not now on the one-time sheet: it stays down for this launch (until
  /// the next auth transition). A send still asks again.
  final bool dismissed;
}

/// User-scoped: watches [authProvider], so a sign-in, sign-out or the
/// anonymous-to-account link starts from a clean state.
class AiConsentNotifier extends Notifier<AiConsentState> {
  @override
  AiConsentState build() {
    ref.watch(authProvider);
    return const AiConsentState();
  }

  /// Whether a send must ask first. With a session, `/me` decides; a failed
  /// read never gates (the contract fails open). Without one, only the first
  /// run asks ([beforeSession]): its listener does not exist yet, and so
  /// cannot have agreed.
  Future<bool> isRequired({bool beforeSession = false}) async {
    if (state.required) return true;
    if (state.granted) return false;
    if (ref.read(authProvider) != AuthStatus.session) return beforeSession;
    final me = await _me();
    return me != null && !me.aiConsent;
  }

  /// Records consent for [aiConsentVersion]. Needs a session (the first run
  /// creates the anonymous listener before calling this). Skips the POST
  /// when `/me` already says granted, which includes an older Worker that
  /// cannot record it. Throws when the server did not confirm.
  Future<void> grant() async {
    final api = ref.read(accountApiProvider);
    final me = state.required ? null : await _me();
    if (me == null || !me.aiConsent) await api.grantAiConsent();
    if (!ref.mounted) return;
    state = const AiConsentState(granted: true);
  }

  void dismiss() {
    state = AiConsentState(
      granted: state.granted,
      dismissed: true,
      required: state.required,
    );
  }

  /// The server refused a send for want of consent (`403
  /// ai_consent_required`), which also covers a `/me` read that failed under
  /// enforcement.
  void markRequired() {
    state = AiConsentState(dismissed: state.dismissed, required: true);
  }

  Future<Me?> _me() async {
    try {
      return await ref.read(meProvider.future);
    } catch (_) {
      return null;
    }
  }
}

final aiConsentProvider = NotifierProvider<AiConsentNotifier, AiConsentState>(
  AiConsentNotifier.new,
);

/// The shell's one-time sheet: a session whose `/me` says not yet. False
/// while `/me` is loading or failed, and once granted here.
final aiConsentNeededProvider = Provider<bool>((ref) {
  if (ref.watch(authProvider) != AuthStatus.session) return false;
  if (ref.watch(aiConsentProvider).granted) return false;
  return ref.watch(meProvider).unwrapPrevious().value?.aiConsent == false;
});
