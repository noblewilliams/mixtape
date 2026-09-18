/// The arrangement: the ordered mix behind one conversation
/// (`docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`, frames
/// R1–R3 / P1–P3 / E1–E4 in
/// `docs/mockups/2026-09-17-mobile-arrangement-states.html`).
///
/// Reorder, remove (with Undo), read the DJ's reasons, then play it here,
/// send it to Music, or turn it into a playlist. Server-canonical, like every
/// other queue mutation in this app: reorder/remove/insert post an op and
/// re-render from the response rather than editing local state optimistically.
///
/// Spotify listeners (plan `2026-09-02-listening-export-p2-spotify-import.md`,
/// Outputs): a row with a Spotify id trades its grip for "Open in Spotify";
/// any queue with a Spotify id gains "Send to a transfer tool" (and one Apple
/// Music can do nothing with drops Play/Create entirely, with the reason
/// written beside the action that remains); a corpus-mode session carries the
/// "Not personal yet" block above the list.
///
/// Every mutation goes through one FIFO of [_QueueIntent]s rather than
/// firing straight at the provider — see [_QueueScreenState._enqueue] for
/// the invariants that buys (one op in flight at a time, positions resolved
/// against the queue as it stands when the op is posted, and rows un-hidden
/// when their own op settles rather than on a version change).
library;

import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoTextField,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/mix_handoff.dart';
import '../widgets/track_row.dart';
import 'mix_history_screen.dart';
import '../widgets/foundation/mixtape_menu.dart';

/// The conflict copy from the approved board. The provider's own
/// [staleQueueTransientMessage] is shared with the conversation screen, so it
/// is translated here rather than changed underneath that screen.
const arrangementConflictMessage =
    'This mix changed elsewhere. Showing the latest version.';

/// The arrangement screen, pushed inside a tab [Navigator] (the shell hides
/// the dock for it), so it draws its own chrome and never assumes it is the
/// root route.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key, required this.sessionId});

  final String sessionId;

  /// The empty state's illustration size, as on Mixes.
  static const double emptyCassetteWidth = 140;

  /// How long Undo stays on screen after a removal.
  static const Duration undoDuration = Duration(seconds: 5);

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen>
    with MixHandoff<QueueScreen> {
  final Set<String> _expandedTrackIds = {};

  /// Rows filtered out of the render even though the server still has them.
  /// [Dismissible] requires a swiped item to be gone from the underlying
  /// list by the very next build or it asserts ("A dismissed Dismissible
  /// widget is still part of the tree") — but this screen is
  /// server-canonical (no optimistic data edits), so the REAL removal only
  /// lands once the queue-ops response comes back.
  ///
  /// Entries are per-track and SETTLE-BASED: one is added when a gesture
  /// enqueues an intent and removed in that intent's `finally`, whatever
  /// the outcome. Never cleared wholesale on a version change — a version
  /// bump from an unrelated source (a concurrent DJ turn) would otherwise
  /// resurrect a just-dismissed row in the same frame it was dismissed,
  /// tripping exactly the assertion above; and a non-stale applyOps failure
  /// leaves the version UNCHANGED, so version-triggered clearing would
  /// strand the row invisible forever while it still exists server-side.
  final Set<String> _hiddenTrackIds = {};

  /// Serialized queue mutations, oldest first. See [_enqueue] for why they
  /// run strictly one at a time and why they're expressed as intents
  /// (track ids) rather than as ready-made positional ops.
  final List<_QueueIntent> _intents = [];
  bool _draining = false;

  @override
  String get mixSessionId => widget.sessionId;

  @override
  void showMixSnack(String message) => _showSnack(context, message);

  void _toggleReason(String trackId) {
    setState(() {
      if (!_expandedTrackIds.add(trackId)) _expandedTrackIds.remove(trackId);
    });
  }

  /// Queue mutation invariants, all of which fall out of running intents
  /// through a single FIFO:
  ///
  /// * **One in flight at a time.** A second gesture never posts against a
  ///   version the first gesture is about to bump, so rapid swipes can't
  ///   409 and be silently discarded — the later intent simply waits and
  ///   uses the fresh version.
  /// * **Positions resolve at EXECUTION time, from the provider's current
  ///   queue** — never from the visible list at gesture time, which omits
  ///   hidden rows and would therefore point a 0-based server position at
  ///   the wrong track. If the intent's track is gone by then (a DJ turn
  ///   removed it, say), the intent is skipped rather than mis-targeted.
  /// * **Hiding is settle-based.** The gesture hides its row immediately
  ///   (Dismissible's hard requirement) and the intent un-hides that
  ///   specific id when it settles, so a failed removal reappears.
  void _enqueue(_QueueIntent intent) {
    _intents.add(intent);
    if (!_draining) _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_intents.isNotEmpty && mounted) {
        // Unforeseen-exception guard, same shape as ChatScreen's `_send`:
        // [ChatNotifier.applyOps] resolves every error it knows about into
        // a transientError and never rethrows, so this catch exists purely
        // so an entirely unanticipated one can't become an unhandled async
        // error that also strands every intent still queued behind it.
        try {
          await _run(_intents.removeAt(0));
        } catch (_) {
          if (mounted) _showSnack(context, 'something unexpected happened');
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(_QueueIntent intent) async {
    try {
      final queue = ref.read(chatProvider(widget.sessionId)).value?.queue;
      if (queue == null) return;
      final op = intent.resolve(queue);
      if (op == null) return; // the intent no longer means anything — drop it
      await ref.read(chatProvider(widget.sessionId).notifier).applyOps([op]);
    } finally {
      // Runs on success, failure, and the skipped-intent paths above: the
      // row this intent owned is either genuinely gone from the queue now
      // (so un-hiding is a harmless no-op) or was never removed, in which
      // case it has to come back rather than stay stuck invisible.
      if (mounted) {
        setState(() => _hiddenTrackIds.remove(intent.trackId));
      }
    }
  }

  /// A full swipe removes at once and the toast offers Undo, which re-adds
  /// the song where it was through the same versioned op — but only when the
  /// server understands `insert` ([ChatState.supportsInsert]); against an
  /// older deploy the toast simply names the song.
  void _handleDismiss(QueueTrack track, {required bool supportsInsert}) {
    final canonical =
        ref.read(chatProvider(widget.sessionId)).value?.queue ?? const <QueueTrack>[];
    final oldPosition = canonical.indexWhere((t) => t.trackId == track.trackId);
    // An ANCHOR, not a number: the song that followed this one (null when it
    // was last). An earlier removal still in flight would shift a bare
    // position, so [_InsertIntent] resolves this against the queue as it
    // stands when the Undo is actually posted, exactly as a move does.
    final followerId = (oldPosition >= 0 && oldPosition + 1 < canonical.length)
        ? canonical[oldPosition + 1].trackId
        : null;
    setState(() => _hiddenTrackIds.add(track.trackId));
    _enqueue(_RemoveIntent(track.trackId));

    final canUndo = supportsInsert && oldPosition >= 0;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed "${track.title}"'),
          duration: QueueScreen.undoDuration,
          action: canUndo
              ? SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _enqueue(
                    _InsertIntent(track.trackId, beforeTrackId: followerId),
                  ),
                )
              : null,
        ),
      );
  }

  /// [newIndex] arrives in [ReorderableListView]'s own pre-removal indexing:
  /// moving an item DOWN reports an index one past where it actually lands
  /// once the dragged item is taken out of the list, so it's decremented by
  /// one in that case.
  void _handleReorder(List<QueueTrack> visible, int oldIndex, int newIndex) {
    var adjusted = newIndex;
    if (adjusted > oldIndex) adjusted -= 1;
    _moveTo(visible, oldIndex, adjusted);
  }

  /// The move is expressed as an ANCHOR (the id of the row the dragged one
  /// should land in front of, or null for "at the end") rather than a bare
  /// index, because [visible] is the on-screen list — which omits any row
  /// hidden by an intent that hasn't settled yet — while the op needs a
  /// position in the server's full queue. [_MoveIntent] re-derives that
  /// position from the current queue when it runs.
  void _moveTo(List<QueueTrack> visible, int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    final rest = [
      for (var i = 0; i < visible.length; i++)
        if (i != oldIndex) visible[i].trackId,
    ];
    _enqueue(
      _MoveIntent(
        visible[oldIndex].trackId,
        beforeTrackId: newIndex < rest.length ? rest[newIndex] : null,
      ),
    );
  }

  /// `spotify:track:<id>` when the Spotify app answers the probe (the scheme
  /// is declared under LSApplicationQueriesSchemes in Info.plist, or iOS
  /// says no regardless), else the https link, which Safari or the App Store
  /// banner handles. A probe that throws counts as "cannot".
  Future<void> _openInSpotify(BuildContext screenContext, QueueTrack track) async {
    final id = track.spotifyId!;
    final app = Uri.parse('spotify:track:$id');
    var canOpenApp = false;
    try {
      canOpenApp = await ref.read(linkProbeProvider)(app);
    } catch (_) {
      canOpenApp = false;
    }
    if (!mounted) return;
    final target = canOpenApp ? app : Uri.https('open.spotify.com', '/track/$id');
    var opened = false;
    try {
      opened = await ref.read(linkOpenerProvider)(target);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) {
      if (screenContext.mounted) _showSnack(screenContext, "couldn't open Spotify");
      return;
    }
    noteSpotifyOutput();
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MixHistoryScreen(sessionId: widget.sessionId),
      ),
    );
  }

  /// The More menu the conversation already carries, minus Version history —
  /// which has its own button in the cluster here.
  Future<void> _openMore(BuildContext anchor) async {
    final archived =
        ref.read(chatProvider(widget.sessionId)).value?.session.status == 'archived';
    final action = await showMixtapeMenu<String>(
      context,
      actions: [
        const MixtapeMenuAction(value: 'rename', label: 'Rename'),
        MixtapeMenuAction(
          value: 'status',
          label: archived ? 'Restore' : 'Archive',
          isDestructive: !archived,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'rename') return _openRenameDialog();
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    final ok = await notifier.setArchived(!archived);
    if (!mounted) return;
    _showSnack(
      context,
      ok
          ? (archived ? 'Mix restored' : 'Mix archived')
          : "Couldn't update this mix. Try again.",
    );
  }

  Future<void> _openRenameDialog() async {
    final current = ref.read(chatProvider(widget.sessionId)).value?.session.title ?? '';
    final controller = TextEditingController(text: current);
    final name = await showCupertinoDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Rename mix'),
        content: Padding(
          padding: const EdgeInsets.only(top: 14),
          child: CupertinoTextField(
            key: const Key('rename-field'),
            controller: controller,
            autofocus: true,
            placeholder: 'Mix name',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            key: const Key('rename-confirm-button'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    await ref.read(chatProvider(widget.sessionId).notifier).rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider(widget.sessionId));
    // Kick off the /me fetch as soon as the screen opens so the account
    // name is (usually) resolved by the time the save dialog reads it
    // non-blocking — see _openSaveDialog.
    ref.watch(accountNameProvider);
    // Same reason, for the same reader: [FunnelMilestones] reads the
    // onboarding state synchronously (it never awaits a user-scoped
    // provider), so an output action can only post its milestone if the
    // read has landed. The service gate has normally loaded it long before
    // this screen opens; watching keeps it loaded and current here too.
    ref.watch(onboardingProvider);

    ref.listen(chatProvider(widget.sessionId), (previous, next) {
      final state = next.value;
      if (state == null) return;

      // Drop expansion state for tracks that have left the queue, so a
      // trackId can't accumulate here forever (and can't silently
      // re-expand if the DJ ever re-adds the same track later). Mutated
      // without setState deliberately: the very provider change that
      // triggered this listener also rebuilds this widget via ref.watch,
      // and setState from a listener can land mid-build.
      final liveIds = {for (final t in state.queue) t.trackId};
      _expandedTrackIds.removeWhere((id) => !liveIds.contains(id));

      // ChatScreen keeps its own transientError listener and is still
      // mounted underneath this route, so both would fire for one error and
      // queue two identical snackbars. Only the route actually on top shows
      // it, but it is ALWAYS cleared — leaving it in state (e.g. while this
      // screen's save dialog covers both routes) would let copyWith carry
      // it forward until some later, unrelated event surfaces it out of
      // context. Both listeners fire with the same captured `state`, so the
      // non-top screen clearing first can't stop the top one from showing.
      if (state.transientError != null) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          // A version conflict says so in the arrangement's own words.
          final message = state.transientError == staleQueueTransientMessage
              ? arrangementConflictMessage
              : state.transientError!;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(message)));
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }
    });

    // Same defensive ordering as ChatScreen: hasError checked before
    // isLoading/hasValue so a Riverpod retry-in-progress doesn't sit on a
    // bare spinner, and hasValue checked so a live list mid-background-
    // refresh-failure never blanks out to the full-screen error.
    if (chatAsync.hasError && !chatAsync.hasValue) {
      return _shell(
        title: '',
        body: _ErrorState(
          onRetry: () => ref.invalidate(chatProvider(widget.sessionId)),
        ),
      );
    }

    if (!chatAsync.hasValue) {
      return _shell(title: '', body: const Center(child: CircularProgressIndicator()));
    }

    final state = chatAsync.value!;

    // [visibleQueue] — not state.queue — drives EVERY surface on this
    // screen: the list, the empty state, whether Play/Create are actionable,
    // and the ids handed to Apple Music. A row the user has just swiped
    // away shouldn't play or be saved into a playlist just because its
    // removal hasn't round-tripped yet.
    final visibleQueue = state.queue.where((t) => !_hiddenTrackIds.contains(t.trackId)).toList();

    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return _shell(
      title: state.session.title,
      hasContent: true,
      // One scroll view, not a Column with a fixed header: at 200% text the
      // meta line and the wrapped actions are taller than a small phone, and
      // a header that cannot scroll would overflow the list off the screen.
      body: CustomScrollView(
        slivers: [
          if (state.session.notPersonal)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MixtapeMetrics.screenSidePadding,
                ),
                child: _NotPersonalBlock(),
              ),
            ),
          if (visibleQueue.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MixtapeMetrics.screenSidePadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MetaLine(
                      songs: visibleQueue.length,
                      version: state.queueVersion,
                      durationLabel: _durationLabel(visibleQueue),
                    ),
                    _actionsRow(state, visibleQueue),
                  ],
                ),
              ),
            ),
          if (visibleQueue.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _EmptyState())
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                MixtapeMetrics.screenSidePadding,
                0,
                MixtapeMetrics.screenSidePadding,
                24,
              ),
              sliver: SliverReorderableList(
                itemCount: visibleQueue.length,
                onReorder: (oldIndex, newIndex) =>
                    _handleReorder(visibleQueue, oldIndex, newIndex),
                // The board's lifted row, rebuilt rather than wrapped so the
                // raised treatment belongs to the row itself. Reduced motion
                // drops the spring: the row simply appears lifted.
                proxyDecorator: (child, index, animation) =>
                    // The list can ask for a proxy one frame after a removal
                    // shortened the queue; the child it hands back is still
                    // the right thing to draw.
                    index >= visibleQueue.length
                    ? child
                    : _row(
                        state,
                        visibleQueue,
                        index,
                        lifted: true,
                        reducedMotion: reducedMotion,
                      ),
                itemBuilder: (context, index) =>
                    _row(state, visibleQueue, index, reducedMotion: reducedMotion),
              ),
            ),
        ],
      ),
    );
  }

  /// Chrome shared by every state: the gradient, the glass clusters and the
  /// floating SnackBars (no dock on this route, so they sit 16 pt in).
  Widget _shell({
    required String title,
    required Widget body,
    bool hasContent = false,
  }) {
    final theme = Theme.of(context);
    return GradientBackground(
      child: Theme(
        data: theme.copyWith(
          snackBarTheme: theme.snackBarTheme.copyWith(
            behavior: SnackBarBehavior.floating,
            insetPadding: const EdgeInsets.all(16),
          ),
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  title: title,
                  onBack: () => Navigator.of(context).maybePop(),
                  onHistory: hasContent ? _openHistory : null,
                  onMore: hasContent ? _openMore : null,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The shared handoff row (`widgets/mix_handoff.dart`), which the
  /// conversation draws too. This screen has no busy gate of its own, so the
  /// row is always live; [MixActionsRow] applies the Apple/Spotify rules.
  Widget _actionsRow(ChatState state, List<QueueTrack> visibleQueue) {
    return MixActionsRow(
      keys: MixHandoffKeys.arrangement,
      queue: visibleQueue,
      enabled: true,
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      isPlayingThisMix: isPlayingThisMix,
      onPlayNow: () => playHere(state, visibleQueue),
      onCreatePlaylist: () => createPlaylist(
        queue: visibleQueue,
        defaultName: state.session.title,
        keys: MixHandoffKeys.arrangement,
      ),
      onSendToMusic: () => sendToMusic(visibleQueue),
      onShare: (buttonContext) => shareToTransferTool(
        buttonContext,
        visibleQueue,
        state.session.title,
      ),
      saving: savingPlaylist,
      sendingToMusic: sendingToMusic,
      sharing: sharingMix,
    );
  }

  Widget _row(
    ChatState state,
    List<QueueTrack> visibleQueue,
    int index, {
    bool lifted = false,
    required bool reducedMotion,
  }) {
    final track = visibleQueue[index];
    final row = TrackRow(
      number: index + 1,
      track: track,
      expanded: _expandedTrackIds.contains(track.trackId),
      onTap: () => _toggleReason(track.trackId),
      isFirst: index == 0,
      lifted: lifted,
      dragIndex: (lifted || track.spotifyId != null) ? null : index,
      onOpenInSpotify:
          track.spotifyId == null ? null : () => _openInSpotify(context, track),
      onMoveUp: index == 0 ? null : () => _moveTo(visibleQueue, index, index - 1),
      onMoveDown: index == visibleQueue.length - 1
          ? null
          : () => _moveTo(visibleQueue, index, index + 1),
    );
    if (lifted) return KeyedSubtree(key: ValueKey('lifted-${track.trackId}'), child: row);
    return Dismissible(
      key: ValueKey('dismissible-${track.trackId}'),
      direction: DismissDirection.endToStart,
      movementDuration:
          reducedMotion ? Duration.zero : const Duration(milliseconds: 200),
      background: const _RemoveBand(),
      onDismissed: (_) =>
          _handleDismiss(track, supportsInsert: state.supportsInsert),
      child: row,
    );
  }
}

/// "18 songs · 1 h 12 · version 2" — the duration is dropped when any track's
/// length is unknown rather than reported short.
String? _durationLabel(List<QueueTrack> queue) {
  if (queue.isEmpty || queue.any((t) => t.durationMs == null)) return null;
  final minutes = queue.fold<int>(0, (sum, t) => sum + t.durationMs!) ~/ 60000;
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

/// One queued queue-mutation, held in terms of TRACK IDS rather than
/// positions. The gesture that creates it knows what the user meant ("drop
/// this track", "put this track in front of that one"); the 0-based server
/// position that expresses it is only correct against the queue as it
/// stands when the op is actually posted, which is what [resolve] computes.
sealed class _QueueIntent {
  const _QueueIntent(this.trackId);

  /// The track this intent acts on — and the id un-hidden once it settles.
  final String trackId;

  /// The op to post against [queue] (the provider's current, canonical
  /// queue, in server order), or null if the intent no longer means
  /// anything and should be skipped.
  QueueOp? resolve(List<QueueTrack> queue);
}

class _RemoveIntent extends _QueueIntent {
  const _RemoveIntent(super.trackId);

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    final from = queue.indexWhere((t) => t.trackId == trackId);
    // Already gone (a DJ turn dropped it first) — removing "its" position
    // now would delete whichever track has since moved into that slot.
    return from < 0 ? null : QueueOp.remove(from);
  }
}

/// Undo: put the removed track back in front of whatever followed it. The
/// intent is dropped if the track is somehow back already — inserting a
/// duplicate is a 400, not a no-op — and an anchor that has itself since
/// left the queue lands the song at the end rather than losing the Undo.
class _InsertIntent extends _QueueIntent {
  const _InsertIntent(super.trackId, {required this.beforeTrackId});

  /// The track the restored one should land in front of; null means "at the
  /// end of the queue".
  final String? beforeTrackId;

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    if (queue.any((t) => t.trackId == trackId)) return null;
    final anchor =
        beforeTrackId == null ? -1 : queue.indexWhere((t) => t.trackId == beforeTrackId);
    return QueueOp.insert(anchor < 0 ? queue.length : anchor, trackId);
  }
}

class _MoveIntent extends _QueueIntent {
  const _MoveIntent(super.trackId, {required this.beforeTrackId});

  /// The track the dragged one should land in front of; null means "at the
  /// end of the queue".
  final String? beforeTrackId;

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    final from = queue.indexWhere((t) => t.trackId == trackId);
    if (from < 0) return null;
    // The server applies move as splice-out-then-splice-in, so `to` indexes
    // the queue WITHOUT the dragged track — build that list and locate the
    // anchor in it.
    final rest = [
      for (final t in queue)
        if (t.trackId != trackId) t.trackId,
    ];
    final int to;
    if (beforeTrackId == null) {
      to = rest.length;
    } else {
      final anchor = rest.indexOf(beforeTrackId!);
      if (anchor < 0) return null; // the landing spot itself is gone
      to = anchor;
    }
    return from == to ? null : QueueOp.move(from, to);
  }
}

/// Back on the left, the mix title centred, Version history and More on the
/// right — all in the board's glass clusters, with no app bar.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onHistory,
    required this.onMore,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback? onHistory;
  final Future<void> Function(BuildContext anchor)? onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          GlassCluster(
            children: [
              GlassButton(
                key: const Key('arrangement-back'),
                icon: Icons.arrow_back_ios_new,
                label: 'Back',
                onPressed: onBack,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.smallTitle,
              ),
            ),
          ),
          GlassCluster(
            children: [
              GlassButton(
                key: const Key('arrangement-history'),
                icon: Icons.history,
                label: 'Version history',
                onPressed: onHistory,
              ),
              Builder(
                builder: (anchor) => GlassButton(
                  key: const Key('arrangement-more'),
                  icon: Icons.more_horiz,
                  label: 'More',
                  onPressed: onMore == null ? null : () => onMore!(anchor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "18 songs · 1 h 12 · version 2" on the left, the tap hint on the right.
/// The hint steps aside at large text rather than squeezing the counts.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.songs,
    required this.version,
    required this.durationLabel,
  });

  final int songs;
  final int version;
  final String? durationLabel;

  static const String hint = 'Tap a song for its note';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.meta.copyWith(color: tokens.muted);
    final crowded = MediaQuery.textScalerOf(context).scale(100) / 100 >= 1.5;
    final line = [
      '$songs song${songs == 1 ? '' : 's'}',
      if (durationLabel != null) durationLabel!,
      'version $version',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              line,
              key: const Key('arrangement-meta'),
              style: style,
              maxLines: crowded ? null : 1,
              overflow: crowded ? null : TextOverflow.ellipsis,
            ),
          ),
          if (!crowded) ...[
            const SizedBox(width: 8),
            Text(hint, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

/// The red band a swipe reveals under a row.
class _RemoveBand extends StatelessWidget {
  const _RemoveBand();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      color: tokens.errInk,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Remove',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: 6),
          Icon(Icons.close, size: 18, color: Colors.white),
        ],
      ),
    );
  }
}

/// E4: only when there is nothing on screen at all — a list already shown
/// survives a failed refresh with a toast.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 36, color: tokens.errInk),
            const SizedBox(height: 14),
            Text(
              "Couldn't load this tape",
              textAlign: TextAlign.center,
              style: tokens.section,
            ),
            const SizedBox(height: 6),
            Text(
              'Check your connection and try again. The mix itself is safe.',
              textAlign: TextAlign.center,
              style: tokens.secondary,
            ),
            const SizedBox(height: 12),
            KeyedSubtree(
              key: const Key('queue-retry'),
              child: TapeButton(label: 'Try again', onPressed: onRetry),
            ),
          ],
        ),
      ),
    );
  }
}

/// E3: a conversation that has not produced an arrangement yet.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      key: const Key('queue-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CassetteTile(width: QueueScreen.emptyCassetteWidth),
            const SizedBox(height: 18),
            Text(
              'Nothing on the tape yet',
              textAlign: TextAlign.center,
              style: tokens.section,
            ),
            const SizedBox(height: 6),
            Text(
              'Ask the DJ for a mix and it will show up here.',
              textAlign: TextAlign.center,
              style: tokens.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The corpus-mode block (plan: Copy — "Not personal yet" wherever a session
/// has `notPersonal`): the mix came from the shared catalog and the
/// interview, not this listener's plays. A flush line with a hairline under
/// it, per the board — text only, since Home is the only screen that pushes
/// the import. A live region so a screen reader announces it when a turn
/// flips the flag.
class _NotPersonalBlock extends StatelessWidget {
  const _NotPersonalBlock();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      key: const Key('not-personal-banner'),
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.hairline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Not personal yet',
              style: tokens.rowTitle.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              "Built from Mixtape's catalog and your interview, not your listening. "
              'Import your Spotify data for the real thing.',
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ],
        ),
      ),
    );
  }
}
