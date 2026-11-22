/// Sending a turn to a mix's DJ from any screen that shows the mix: the
/// conversation, and the tape (so the listener can keep talking while looking
/// at the songs). Both bind to the mix's one [MixDraft]; this is the one copy
/// of the guards, the AI-consent ask, the shape that rides along, and what
/// goes back in the draft when a turn is stopped or refused.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/dj/dj_models.dart';
import '../providers/dj_providers.dart';
import '../providers/dj_status_provider.dart';
import '../providers/mix_operation_gate.dart';
import '../providers/playlist_context_provider.dart';
import 'ai_consent_sheet.dart';
import 'energy_journey.dart';
import 'foundation/mixtape_feedback.dart';
import 'mix_energy_summary.dart';
import 'mix_quote.dart';

mixin MixTurnSender<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The mix the turns go to.
  String get mixSessionId;

  /// The host's toast.
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info});

  /// The mix's shared draft. Watched by the host's build, so both composers
  /// keep it alive.
  MixDraft get mixDraft => ref.read(mixDraftProvider(mixSessionId));

  /// A send waiting on the AI-consent sheet.
  bool _askingConsent = false;

  /// Unforeseen-exception guard: [ChatNotifier.send] already resolves every
  /// error type it knows about into an error turn and never rethrows — this
  /// catch-all exists purely so an entirely unanticipated exception can't
  /// become an unhandled async error with a bricked composer.
  ///
  /// [fromComposer] says the draft is what is going out ([text] is then its
  /// [MixDraft.outgoing]): it is cleared once the turn goes, and put back if
  /// the turn is refused. False for a resend or a suggestion, which send a
  /// DIFFERENT text and must leave whatever the listener has started typing
  /// alone.
  ///
  /// [remake] posts the turn through [ChatNotifier.remake] ([text] is then
  /// [remakeText]): the door's Remake, the tape's, a Resend of a failed
  /// remake, and the consent retry of a refused one all go that way, since
  /// the text alone would post a plain turn. [countTap] is a Remake tap's:
  /// the notifier counts it as the remake goes out, so Not now, a guard or a
  /// second tap counts nothing, and the retry after a refusal (the same tap,
  /// already counted) drops it.
  Future<void> sendTurn(
    String text, {
    bool fromComposer = false,
    bool remake = false,
    bool countTap = false,
  }) async {
    final trimmed = text.trim();
    final chat = ref.read(chatProvider(mixSessionId)).value;
    // A stop still undoing the last turn holds the mix's gate; a send then
    // goes ahead and waits for it (see [ChatNotifier.stop]).
    final operation = ref.read(mixOperationProvider(mixSessionId));
    final heldByStop =
        operation == MixOperation.sending && (chat?.stopping ?? false);
    if (trimmed.isEmpty ||
        (operation != null && !heldByStop) ||
        ref.read(sessionPlaylistContextProvider(mixSessionId)).writing ||
        chat?.sending == true ||
        _askingConsent ||
        // The DJ is paused: nothing goes out, and the draft stays put.
        ref.read(djPausedProvider)) {
      return;
    }
    // Nothing reaches the DJ before the listener has agreed; Not now keeps
    // the draft in the composer.
    _askingConsent = true;
    final agreed = await confirmAiConsent(context);
    _askingConsent = false;
    if (!agreed || !mounted) return;
    final draft = mixDraft;
    if (fromComposer) draft.clear();
    try {
      final notifier = ref.read(chatProvider(mixSessionId).notifier);
      // The shape the control shows goes with every mix message.
      final mixShape = mixShapeOf(
        ref.read(chatProvider(mixSessionId)).value,
        watch: false,
      );
      await (remake
          ? notifier.remake(countTap: countTap, mixShape: mixShape)
          : notifier.send(trimmed, mixShape: mixShape));
    } on AiConsentRequiredException {
      // Enforcement is on and `/me` was out of date: the turn was taken
      // back. The text goes back in the composer, the sheet asks, and
      // Agree sends it again.
      if (!mounted) return;
      if (fromComposer) draft.restore(trimmed);
      _askingConsent = true;
      final again = await confirmAiConsentAfterRefusal(context);
      _askingConsent = false;
      if (!again || !mounted) return;
      await sendTurn(
        fromComposer ? draft.outgoing : trimmed,
        fromComposer: fromComposer,
        remake: remake,
      );
    } on DjPausedException {
      // Paused server-wide while this went out: the turn was taken back and
      // the app paused. The text goes back in the composer, which now shows
      // the paused state; no error, no toast.
      if (!mounted) return;
      if (fromComposer) draft.restore(trimmed);
    } catch (_) {
      if (!mounted) return;
      showMixSnack('something unexpected happened', kind: FeedbackKind.error);
    }
  }

  /// The stop key: the turn goes at once, and what the listener sent goes
  /// back in the draft (quotes and all) unless they have started typing
  /// something else meanwhile (stop a turn, 2026-11-15).
  void stopTurn() {
    final text = ref.read(chatProvider(mixSessionId).notifier).stop();
    if (text == null || !mounted) return;
    mixDraft.restore(text);
  }

  /// The shape the mix itself has: its current version's, once that detail
  /// is read; until then (or if it cannot be), the one its last turn carried.
  EnergyArc? mixShapeOf(ChatState? state, {required bool watch}) {
    if (state == null || state.kind == SessionKind.album) return null;
    final version = state.queueVersion;
    if (version <= 0) return state.landedShape;
    final provider = mixEnergyProvider((id: mixSessionId, version: version));
    final detail = watch ? ref.watch(provider) : ref.read(provider);
    final read = detail.value;
    if (read == null) return state.landedShape;
    return EnergyArc.values
        .where((arc) => arc.name == read['energyArc'])
        .firstOrNull;
  }
}
