/// App-session state behind "Keep your mixes." (first-run spec → path A
/// step 3, "Cap reached"): the Keep this mix sheet's once-per-launch offer,
/// and the prompt a capped anonymous listener sent, kept for after sign-in.
///
/// Neither watches [authProvider]: both must survive the link from the
/// anonymous session to the account, which invalidates the auth provider
/// and remounts the root. They reset themselves on a sign-out instead.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/energy_journey.dart' show EnergyArc;
import 'auth_provider.dart';

/// Which mix the Keep this mix sheet is offered for, and whether it has
/// shown in this app session. Never persisted: a new launch may offer it
/// again (once), and Not now is final only until then.
class KeepSheetState {
  const KeepSheetState({this.offeredFor, this.shown = false});

  /// The new mix the conversation shows the sheet over, once it opens.
  final String? offeredFor;
  final bool shown;
}

class KeepSheetNotifier extends Notifier<KeepSheetState> {
  @override
  KeepSheetState build() {
    ref.listen<AuthStatus>(authProvider, (previous, next) {
      if (next == AuthStatus.noSession) state = const KeepSheetState();
    });
    return const KeepSheetState();
  }

  /// An anonymous listener's new mix [sessionId] landed with [queueLength]
  /// tracks. The first one with content this app session is offered the
  /// sheet; a refusal (an empty queue) never is, and an account never is.
  void noteMix(String sessionId, int queueLength) {
    if (queueLength == 0 || state.shown || state.offeredFor != null) return;
    if (ref.read(authProvider) != AuthStatus.session ||
        !ref.read(authProvider.notifier).isAnonymous) {
      return;
    }
    state = KeepSheetState(offeredFor: sessionId);
  }

  /// The conversation for [sessionId] opened: true once, when the sheet
  /// should show over it now (and is then marked shown for the session).
  bool take(String sessionId) {
    if (state.shown || state.offeredFor != sessionId) return false;
    if (!ref.read(authProvider.notifier).isAnonymous) {
      state = const KeepSheetState();
      return false;
    }
    state = const KeepSheetState(shown: true);
    return true;
  }
}

final keepSheetProvider = NotifierProvider<KeepSheetNotifier, KeepSheetState>(
  KeepSheetNotifier.new,
);

/// What a capped anonymous listener sent: the draft as typed and, apart from
/// it, the Shape chip's arc. The shape is never written into the draft
/// (house rule); Home composes the two at send, as its own send does.
class KeptPrompt {
  const KeptPrompt(this.draft, {this.arc});

  final String draft;
  final EnergyArc? arc;

  @override
  bool operator ==(Object other) =>
      other is KeptPrompt && other.draft == draft && other.arc == arc;

  @override
  int get hashCode => Object.hash(draft, arc);

  @override
  String toString() => 'KeptPrompt($draft, $arc)';
}

/// The prompt a capped anonymous listener sent. Kept when the cap pushes the
/// sign-in page, dropped by Back (the field still holds it), and taken once
/// by Home after the sign-in has remounted the shell as the account.
class KeptPromptNotifier extends Notifier<KeptPrompt?> {
  @override
  KeptPrompt? build() {
    ref.listen<AuthStatus>(authProvider, (previous, next) {
      if (next == AuthStatus.noSession) state = null;
    });
    return null;
  }

  void keep(KeptPrompt prompt) => state = prompt;

  void clear() => state = null;

  /// Returns the kept prompt once and clears it.
  KeptPrompt? take() {
    final prompt = state;
    state = null;
    return prompt;
  }
}

final keptPromptProvider =
    NotifierProvider<KeptPromptNotifier, KeptPrompt?>(KeptPromptNotifier.new);
