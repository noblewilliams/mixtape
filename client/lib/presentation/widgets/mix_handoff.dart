/// The mix handoff: everything that takes a finished arrangement OUT of this
/// app — Play now (the app's own Apple player), Send to Music (Apple's
/// player), Create playlist (an Apple Music playlist with a remembered
/// author), and Send to a transfer tool (the Spotify listener's text handoff).
///
/// Locked by `docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`
/// (Locked behaviour → the actions row, Play now, Create playlist, the
/// Spotify listener) and drawn on two screens: the conversation
/// (`screens/chat_screen.dart`) and the arrangement
/// (`screens/queue_screen.dart`). Both carried byte-near copies of this until
/// plan task 5.3; the copy, the gating and the toasts now live here once so
/// they cannot drift apart again.
///
/// Three pieces:
///
/// * pure copy builders and gating rules ([mixPlaySuccessMessage] and
///   friends, [mixActionsDisabledReason], [mixHasAppleActions],
///   [mixHasSpotifyActions]) — no widgets, no providers;
/// * [MixHandoff], a mixin on `ConsumerState` holding the four actions
///   themselves, their in-flight guards and their toasts;
/// * [MixActionsRow] and [MixSaveDialog], the two surfaces they drive.
///
/// Each host screen keeps its own keys and its own toast geometry
/// ([MixHandoffKeys], `showMixSnack`) — the arrangement's toast sits inside
/// that screen's local SnackBar theme and the conversation's sets its own
/// margin, so the message is shared but the presentation stays where it was.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoAlertDialog,
        CupertinoTheme,
        CupertinoDialogAction,
        CupertinoTextField,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../../data/listening/listening_models.dart' show FunnelEventType;
import '../../data/musickit/musickit_bridge.dart';
import '../providers/device_providers.dart';
import '../providers/dj_providers.dart';
import '../providers/funnel_provider.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/playback_provider.dart';
import '../screens/playback_screen.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/label_chip.dart';
import 'foundation/tape_button.dart';
import 'foundation/text_action.dart';

/// The transfer tool the Spotify handoff opens, matching the web rail's
/// TRANSFER_TOOL_URL (`web/src/components/QueuePanel.tsx`). TuneMyMusic is
/// the tool of the two on the approved board whose transfer page accepts
/// pasted text without an account, so the listener lands where they can paste.
final mixTransferToolUrl = Uri.https('www.tunemymusic.com', '/transfer');

/// Written beside Play now / Create playlist when nothing in the mix has an
/// Apple Music match.
const mixNoAppleMatchReason = "these tracks aren't in Apple Music";

/// The whole-row line a Spotify-only mix carries instead of Play/Create.
const mixAppleNeededReason = 'Play now and Create playlist need Apple Music';

String mixPlaySuccessMessage(int skipped) => skipped > 0
    ? 'Playing in Apple Music · $skipped song${skipped == 1 ? '' : 's'} '
          'skipped (not in Apple Music)'
    : 'Playing in Apple Music';

String mixPlayFailureMessage(String reason) => "Couldn't play — $reason";

String mixSaveSuccessMessage(int added, int failed) => failed > 0
    ? 'Saved $added songs to Apple Music ($failed failed)'
    : 'Saved $added songs to Apple Music';

/// The bridge's message carries Apple's actual failure reason (see
/// `MusicKitBridge._fromPlatform`) — hiding it behind a generic string made
/// real device failures undiagnosable.
String mixSaveFailureMessage(String reason) =>
    "Couldn't save the playlist — $reason";

String mixShareSuccessMessage(int count) =>
    'Shared $count song${count == 1 ? '' : 's'} · '
    'TuneMyMusic makes the playlist in Spotify';

const mixShareFailureMessage = "couldn't open the share sheet";

/// Null when Play/Create are actionable; otherwise the reason they are not,
/// written beside them rather than hidden in a tooltip: a mix whose tracks
/// are ALL missing an Apple Music match can't be played or saved at all (a
/// partial match still works — the filtered track count is reported in the
/// success toast instead). An arrangement that does not exist yet needs no
/// reason: the arrangement screen doesn't build the row at all, and the
/// conversation draws the actions simply disabled.
String? mixActionsDisabledReason(List<QueueTrack> queue) =>
    queue.isNotEmpty && queue.every((t) => t.appleId == null)
    ? mixNoAppleMatchReason
    : null;

/// Each platform's controls appear when the mix has anything that platform
/// can act on (plan `2026-09-02-listening-export-p2-spotify-import.md`,
/// Outputs), so a mixed mix shows both — Apple first, since Play is still the
/// primary action for a mix Apple Music can play.
bool mixHasSpotifyActions(List<QueueTrack> queue) =>
    queue.any((t) => t.spotifyId != null);

/// A mix with no Spotify ids at all keeps the Apple pair (carrying
/// [mixActionsDisabledReason] when it has no matches either) rather than an
/// empty bar; only a mix Apple Music can do nothing with AND Spotify can
/// drops them for the transfer handoff alone.
bool mixHasAppleActions(List<QueueTrack> queue) =>
    queue.any((t) => t.appleId != null) || !mixHasSpotifyActions(queue);

/// The anchor the share sheet points at. On iPad the sheet is a popover and
/// UIKit raises without a source rect, so this is the share button's own rect
/// in global logical coordinates ([buttonContext] is the Builder wrapping it,
/// whose first render object is the button). A button that has left the tree
/// falls back to the whole screen, which centres it.
Rect mixShareOrigin(BuildContext buttonContext, BuildContext screenContext) {
  final box = buttonContext.findRenderObject();
  if (box is RenderBox && box.hasSize && !box.size.isEmpty) {
    return box.localToGlobal(Offset.zero) & box.size;
  }
  return Offset.zero & MediaQuery.sizeOf(screenContext);
}

/// The widget keys and the alert title each host screen puts on the shared
/// surfaces. Two screens draw the same row and the same alert; their keys
/// are what the two test suites (and VoiceOver's own ordering) already know
/// them by, so they travel with the screen rather than with the widget.
@immutable
class MixHandoffKeys {
  const MixHandoffKeys({
    required this.playNow,
    required this.createPlaylist,
    required this.sendToMusic,
    required this.share,
    required this.reason,
    required this.appleNeeded,
    required this.nameField,
    required this.authorField,
    required this.saveConfirm,
    required this.saveDialogTitle,
  });

  final Key playNow;
  final Key createPlaylist;
  final Key sendToMusic;
  final Key share;
  final Key reason;
  final Key appleNeeded;
  final Key nameField;
  final Key authorField;
  final Key saveConfirm;
  final String saveDialogTitle;

  /// `screens/queue_screen.dart`.
  static const arrangement = MixHandoffKeys(
    playNow: Key('play-here-button'),
    createPlaylist: Key('save-button'),
    sendToMusic: Key('play-button'),
    share: Key('share-button'),
    reason: Key('actions-reason'),
    appleNeeded: Key('apple-needed-reason'),
    nameField: Key('playlist-name-field'),
    authorField: Key('playlist-author-field'),
    saveConfirm: Key('save-confirm-button'),
    saveDialogTitle: 'Save as playlist',
  );

  /// `screens/chat_screen.dart`.
  static const conversation = MixHandoffKeys(
    playNow: Key('chat-play-now'),
    createPlaylist: Key('chat-create-playlist'),
    sendToMusic: Key('chat-send-to-music'),
    share: Key('chat-share'),
    reason: Key('chat-actions-reason'),
    appleNeeded: Key('chat-apple-needed-reason'),
    nameField: Key('chat-playlist-name'),
    authorField: Key('chat-playlist-author'),
    saveConfirm: Key('chat-playlist-save'),
    saveDialogTitle: 'Create playlist',
  );
}

/// The four handoff actions, mixed into the screen that draws them so they
/// keep that screen's `ref`, `context` and in-flight guards.
///
/// A host supplies [mixSessionId] (the mix these actions belong to) and
/// [showMixSnack] (its own toast geometry); everything else is shared.
mixin MixHandoff<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The session these actions act on — the id every event and playlist
  /// receipt is bound to.
  String get mixSessionId;

  /// The host's toast. Deliberately the host's own: the arrangement and the
  /// conversation each place the floating bar differently.
  void showMixSnack(String message);

  bool _sendingToMusic = false;
  bool _savingPlaylist = false;
  bool _sharingMix = false;

  /// True while the Send to Music bridge call is in flight.
  bool get sendingToMusic => _sendingToMusic;

  /// True from opening the save alert until it closes.
  bool get savingPlaylist => _savingPlaylist;

  /// True while the share sheet (and the tool's page) is being handed off.
  bool get sharingMix => _sharingMix;

  /// Fire-and-forget `POST /sessions/:id/events` — see
  /// `docs/superpowers/plans/2026-08-30-p4-taste-learning.md` Task 4. Posted
  /// exactly once per SUCCESSFUL play/save (never on failure, never on a
  /// rebuild), and any failure here is swallowed silently: the endpoint is
  /// purely a taste-learning signal, never allowed to degrade the handoff
  /// that already succeeded on the user's device. The save call site
  /// additionally only fires this when `result.added > 0` — a save that added
  /// zero tracks isn't evidence the user liked anything in this mix, and
  /// would be a false taste signal.
  void postMixEvent(String type) {
    unawaited(() async {
      try {
        await ref.read(djApiProvider).postSessionEvent(mixSessionId, type);
      } catch (_) {
        // Silent by design — no retry, no surfaced error.
      }
    }());
  }

  /// The once-only `first_output` funnel milestone: the FIRST SPOTIFY output
  /// action (plan: funnel events) — an "Open in Spotify" tap or a share the
  /// listener carried through. Play and Save are Apple outputs and post
  /// nothing here; they have their own session events. Same fire-and-forget
  /// contract as [postMixEvent]; the once-ness lives in [FunnelMilestones].
  void noteSpotifyOutput() =>
      ref.read(funnelMilestonesProvider).recordOnce(FunnelEventType.firstOutput);

  /// Whether the app's own player is on THIS mix — the Play now button then
  /// reads Playing and carries its meter.
  bool isPlayingThisMix() {
    final player = ref.read(playbackProvider);
    return player.sessionId == mixSessionId &&
        (player.sample.status == 'playing' || player.sample.status == 'waiting');
  }

  /// Play now: the app-owned Apple player takes the arrangement and the Now
  /// Playing screen opens over it. Nothing on the list changes.
  void playHere(ChatState state, List<QueueTrack> queue) {
    final player = ref.read(playbackProvider);
    unawaited(
      player.start(mixSessionId, state.queueVersion, state.session.title, queue),
    );
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const PlaybackScreen()),
    );
  }

  /// Send to Music: the mix goes to Apple Music's own player, which reports
  /// how many songs it had no match for.
  Future<void> sendToMusic(List<QueueTrack> queue) async {
    if (_sendingToMusic) return;
    setState(() => _sendingToMusic = true);
    try {
      final ids = [
        for (final t in queue)
          if (t.appleId != null) t.appleId!,
      ];
      final skipped = queue.length - ids.length;
      await ref.read(musicKitBridgeProvider).playQueue(ids);
      postMixEvent('played');
      if (!mounted) return;
      showMixSnack(mixPlaySuccessMessage(skipped));
    } on MusicKitException catch (e) {
      if (!mounted) return;
      showMixSnack(mixPlayFailureMessage(e.message));
    } finally {
      if (mounted) setState(() => _sendingToMusic = false);
    }
  }

  /// Create playlist: the shared [MixSaveDialog], prefilled and remembered.
  ///
  /// Author prefill: the name typed on this device last time wins, then the
  /// account's display name (GET /me — read non-blocking: the fetch was
  /// started by the host's `build`, and a still-loading/absent value just
  /// means an empty field; per dj_providers' warning we never await a
  /// provider future across auth transitions). Blank falls back to 'mixtape'
  /// on save.
  Future<void> createPlaylist({
    required List<QueueTrack> queue,
    required String defaultName,
    required MixHandoffKeys keys,
  }) async {
    if (_savingPlaylist) return;
    setState(() => _savingPlaylist = true);
    try {
      String? storedAuthor;
      try {
        storedAuthor = await ref.read(authorStoreProvider).read();
      } catch (_) {
        storedAuthor = null; // a device that can't remember is not a failure
      }
      if (!mounted) return;
      final accountName = ref.read(accountNameProvider).value;
      await showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => MixSaveDialog(
          keys: keys,
          defaultName: defaultName,
          defaultAuthor:
              (storedAuthor != null && storedAuthor.isNotEmpty
                  ? storedAuthor
                  : accountName) ??
              '',
          onConfirm: (name, author) => _confirmSave(
            dialogContext: dialogContext,
            queue: queue,
            rawName: name,
            defaultName: defaultName,
            rawAuthor: author,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingPlaylist = false);
    }
  }

  /// Runs the actual bridge call for a confirmed save — called by
  /// [MixSaveDialog] itself, which owns the double-tap guard on its Save
  /// button (each tap would otherwise create a NEW playlist; there's no way
  /// to dedupe after the fact). Always resolves the alert (pops it) on both
  /// success and failure, then reports the outcome as a toast on the screen
  /// underneath.
  Future<void> _confirmSave({
    required BuildContext dialogContext,
    required List<QueueTrack> queue,
    required String rawName,
    required String defaultName,
    required String rawAuthor,
  }) async {
    final trimmed = rawName.trim();
    final name = trimmed.isEmpty ? defaultName : trimmed;
    // Attribution: without an explicit author Apple shows the Xcode product
    // name ("Runner"). The user's typed name wins; blank falls back to the
    // app name. Remembered (even if the save then fails) so the next alert
    // prefills it — it's the user's name, not per-playlist data.
    final trimmedAuthor = rawAuthor.trim();
    final author = trimmedAuthor.isEmpty ? 'mixtape' : trimmedAuthor;
    if (trimmedAuthor.isNotEmpty) {
      try {
        await ref.read(authorStoreProvider).write(trimmedAuthor);
      } catch (_) {
        // Remembering the name is a nicety; never block the save on it.
      }
    }
    final ids = [
      for (final t in queue)
        if (t.appleId != null) t.appleId!,
    ];
    final creationApi = ref.read(djApiProvider);
    final creationSessionId = mixSessionId;
    try {
      final result = await ref
          .read(musicKitBridgeProvider)
          .createPlaylist(
            name,
            ids,
            author: author,
            description: 'made by mixtape',
            onCreated: (libraryId) {
              // Bind to the originating mix, not a screen/account that may
              // have changed while Apple was creating the playlist.
              unawaited(
                creationApi
                    .recordPlaylistCreation(creationSessionId, libraryId)
                    .catchError((Object _) {}),
              );
            },
          );
      // A zero-added save is a false taste signal, not evidence of a like —
      // see [postMixEvent].
      if (result.added > 0) postMixEvent('saved_playlist');
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!mounted) return;
      showMixSnack(mixSaveSuccessMessage(result.added, result.failed));
    } on MusicKitException catch (e) {
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!mounted) return;
      showMixSnack(mixSaveFailureMessage(e.message));
    }
  }

  /// Text handoff for a Spotify mix: one "Artist – Title" per track (en
  /// dash), every track — a transfer tool searches Spotify by name, so a
  /// track with no id at all still belongs in the list. Once the sheet
  /// reports the text went somewhere, the tool's own page opens, the same way
  /// the web rail opens it in a new tab.
  Future<void> shareToTransferTool(
    BuildContext buttonContext,
    List<QueueTrack> queue,
    String title,
  ) async {
    if (_sharingMix) return;
    setState(() => _sharingMix = true);
    try {
      final text = [
        for (final t in queue) '${t.artist} – ${t.title}',
      ].join('\n');
      final handedOff = await ref
          .read(textSharerProvider)
          .share(
            text,
            subject: 'Mixtape · $title',
            origin: mixShareOrigin(buttonContext, context),
          );
      if (!mounted || !handedOff) return; // a dismissed sheet is no output
      noteSpotifyOutput();
      try {
        await ref.read(linkOpenerProvider)(mixTransferToolUrl);
      } catch (_) {
        // The text is already in the listener's hands; a browser that won't
        // open isn't worth a second message on top of the confirmation.
      }
      if (!mounted) return;
      showMixSnack(mixShareSuccessMessage(queue.length));
    } catch (_) {
      if (!mounted) return;
      showMixSnack(mixShareFailureMessage);
    } finally {
      if (mounted) setState(() => _sharingMix = false);
    }
  }
}

/// The mix actions row: Play now, Create playlist, Send to Music — with the
/// Spotify variant's transfer-tool button and the muted reason line — wrapping
/// before any of them truncates.
class MixActionsRow extends ConsumerWidget {
  const MixActionsRow({
    super.key,
    required this.keys,
    required this.queue,
    required this.enabled,
    required this.padding,
    required this.isPlayingThisMix,
    required this.onPlayNow,
    required this.onCreatePlaylist,
    required this.onSendToMusic,
    required this.onShare,
    required this.saving,
    required this.sendingToMusic,
    required this.sharing,
  });

  /// The host screen's keys and alert title.
  final MixHandoffKeys keys;

  /// The arrangement this mix currently has; empty until the DJ makes one.
  final List<QueueTrack> queue;

  /// False while a turn, an arrangement op or an inspiration write is in
  /// flight — the whole row goes inert in place. The arrangement, which has
  /// no such gate, passes true.
  final bool enabled;

  /// The row's own padding: the two screens sit it differently in their
  /// layouts.
  final EdgeInsetsGeometry padding;

  final bool Function() isPlayingThisMix;
  final VoidCallback? onPlayNow;
  final VoidCallback? onCreatePlaylist;
  final VoidCallback? onSendToMusic;

  /// Takes the button's own context: the share sheet's iPad popover anchor.
  final void Function(BuildContext buttonContext)? onShare;

  final bool saving;
  final bool sendingToMusic;
  final bool sharing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final muted = tokens.meta.copyWith(color: tokens.muted);
    final reason = mixActionsDisabledReason(queue);
    final live = enabled && queue.isNotEmpty && reason == null;
    final appleActions = mixHasAppleActions(queue);

    return ListenableBuilder(
      listenable: ref.read(playbackProvider),
      builder: (context, _) {
        final playingHere = isPlayingThisMix();
        return Padding(
          padding: padding,
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (appleActions) ...[
                TapeButton(
                  key: keys.playNow,
                  label: playingHere ? 'Playing' : 'Play now',
                  playing: playingHere,
                  onPressed: live ? onPlayNow : null,
                ),
                LabelChip(
                  key: keys.createPlaylist,
                  label: 'Create playlist',
                  onPressed: live && !saving ? onCreatePlaylist : null,
                ),
                TextAction(
                  key: keys.sendToMusic,
                  label: 'Send to Music',
                  onPressed: live && !sendingToMusic ? onSendToMusic : null,
                ),
              ],
              // The Builder is the share sheet's popover anchor on iPad: its
              // context resolves to the button's own render object.
              if (mixHasSpotifyActions(queue))
                Builder(
                  builder: (buttonContext) => TapeButton(
                    key: keys.share,
                    label: 'Send to a transfer tool',
                    onPressed: enabled && !sharing && onShare != null
                        ? () => onShare!(buttonContext)
                        : null,
                  ),
                ),
              if (appleActions && reason != null)
                Text(key: keys.reason, reason, style: muted),
              if (!appleActions)
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    mixAppleNeededReason,
                    key: keys.appleNeeded,
                    style: muted,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// P3's native alert: the mix title as the default name, and "Your name"
/// remembered for next time.
class MixSaveDialog extends StatefulWidget {
  const MixSaveDialog({
    super.key,
    required this.keys,
    required this.defaultName,
    required this.defaultAuthor,
    required this.onConfirm,
  });

  final MixHandoffKeys keys;
  final String defaultName;
  final String defaultAuthor;
  final Future<void> Function(String name, String author) onConfirm;

  @override
  State<MixSaveDialog> createState() => _MixSaveDialogState();
}

class _MixSaveDialogState extends State<MixSaveDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );
  late final TextEditingController _author = TextEditingController(
    text: widget.defaultAuthor,
  );
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Guards a double-tap: each tap would otherwise create a NEW playlist.
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onConfirm(_name.text, _author.text);
    } catch (error, stack) {
      // onConfirm resolves both outcomes it knows about — a save and Apple's
      // refusal — by popping this alert itself. Anything else reaching here
      // is unexpected, and the button's callback discards this future, so
      // rethrowing would lose it as an unhandled async error: report it to
      // the app's error handler instead.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'mixtape',
          context: ErrorDescription('while saving a mix as a playlist'),
        ),
      );
    } finally {
      // onConfirm pops this alert itself on both the success and the
      // MusicKit-failure path, so normally this widget is already gone and
      // the line below never runs. It matters for the third path: anything
      // else thrown (an offline store, a programming error) leaves the alert
      // open, and without this the listener would be stranded on a dead
      // spinner with Cancel disabled and no way out.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Not `context.tokens`: this alert is pumped by hosts that build a bare
    // `MaterialApp`, and a helper line is not worth an assertion.
    final helper = CupertinoTheme.of(
      context,
    ).textTheme.tabLabelTextStyle.copyWith(fontSize: 12);
    return CupertinoAlertDialog(
      title: Text(widget.keys.saveDialogTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 14),
          CupertinoTextField(
            key: widget.keys.nameField,
            controller: _name,
            autofocus: true,
            enabled: !_submitting,
            placeholder: 'Playlist name',
          ),
          const SizedBox(height: 10),
          CupertinoTextField(
            key: widget.keys.authorField,
            controller: _author,
            enabled: !_submitting,
            placeholder: 'Your name',
          ),
          const SizedBox(height: 6),
          Text(
            'Shown under the playlist in Apple Music',
            textAlign: TextAlign.start,
            style: helper,
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          key: widget.keys.saveConfirm,
          isDefaultAction: true,
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CupertinoActivityIndicator(radius: 8),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
