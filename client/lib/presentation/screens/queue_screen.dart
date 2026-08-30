import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/dj/dj_models.dart';
import '../../data/musickit/musickit_bridge.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';

/// The full tape for one session (see
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md` Task 5): reorder,
/// remove, reveal the DJ's reasons, then hand off to Apple Music (play) or
/// save (playlist) — over the same [chatProvider] the chat screen and
/// [QueueCard] already watch. Server-canonical, like every other queue
/// mutation in this app: reorder/remove post an op and re-render from the
/// response rather than editing local state optimistically.
///
/// Every mutation goes through one FIFO of [_QueueIntent]s rather than
/// firing straight at the provider — see [_QueueScreenState._enqueue] for
/// the invariants that buys (one op in flight at a time, positions resolved
/// against the queue as it stands when the op is posted, and rows un-hidden
/// when their own op settles rather than on a version change).
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
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

  bool _playing = false;
  bool _saving = false;

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

  void _handleDismiss(QueueTrack track) {
    setState(() => _hiddenTrackIds.add(track.trackId));
    _enqueue(_RemoveIntent(track.trackId));
  }

  /// [newIndex] arrives in [ReorderableListView]'s own pre-removal indexing:
  /// moving an item DOWN reports an index one past where it actually lands
  /// once the dragged item is taken out of the list, so it's decremented by
  /// one in that case.
  ///
  /// The result is turned into an ANCHOR (the id of the row the dragged one
  /// should land in front of, or null for "at the end") rather than a bare
  /// index, because [visible] is the on-screen list — which omits any row
  /// hidden by an intent that hasn't settled yet — while the op needs a
  /// position in the server's full queue. [_MoveIntent] re-derives that
  /// position from the current queue when it runs.
  void _handleReorder(List<QueueTrack> visible, int oldIndex, int newIndex) {
    var adjusted = newIndex;
    if (adjusted > oldIndex) adjusted -= 1;
    if (adjusted == oldIndex) return;
    final rest = [
      for (var i = 0; i < visible.length; i++)
        if (i != oldIndex) visible[i].trackId,
    ];
    _enqueue(
      _MoveIntent(
        visible[oldIndex].trackId,
        beforeTrackId: adjusted < rest.length ? rest[adjusted] : null,
      ),
    );
  }

  /// Fire-and-forget `POST /sessions/:id/events` — see
  /// `docs/superpowers/plans/2026-08-30-p4-taste-learning.md` Task 4. Posted
  /// exactly once per SUCCESSFUL play/save (never on failure, never on a
  /// rebuild — both call sites fire this only from their success branch, not
  /// from build()), and any failure here is swallowed silently: the server
  /// endpoint is purely a taste-learning signal, never allowed to degrade
  /// the Play/Save UX that already succeeded on the user's device. The save
  /// call site additionally only fires this when `result.added > 0` (see
  /// [_confirmSave]) — a save that added zero tracks isn't evidence the
  /// user liked anything in this queue, and would be a false taste signal.
  void _postEvent(String type) {
    unawaited(() async {
      try {
        await ref.read(djApiProvider).postSessionEvent(widget.sessionId, type);
      } catch (_) {
        // Silent by design — no retry, no surfaced error.
      }
    }());
  }

  Future<void> _handlePlay(BuildContext screenContext, List<QueueTrack> queue) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final ids = [for (final t in queue) if (t.appleId != null) t.appleId!];
      final skipped = queue.length - ids.length;
      await ref.read(musicKitBridgeProvider).playQueue(ids);
      _postEvent('played');
      if (!screenContext.mounted) return;
      _showSnack(screenContext, _playSuccessMessage(skipped));
    } on MusicKitException catch (e) {
      if (!screenContext.mounted) return;
      _showSnack(screenContext, "couldn't play — ${e.message}");
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _openSaveDialog(
    BuildContext screenContext,
    List<QueueTrack> queue,
    String defaultName,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // Author prefill: the name typed on this device last time wins, then
      // the account's display name (GET /me — read non-blocking: the fetch
      // was started by build()'s watch, and a still-loading/absent value
      // just means an empty field; per dj_providers' warning we never await
      // a provider future across auth transitions). Blank falls back to
      // 'mixtape' on save.
      final storedAuthor = await ref.read(authorStoreProvider).read();
      if (!screenContext.mounted) return;
      final accountName = ref.read(accountNameProvider).value;
      await showDialog<void>(
        context: screenContext,
        builder: (dialogContext) => _SaveDialog(
          defaultName: defaultName,
          defaultAuthor:
              (storedAuthor != null && storedAuthor.isNotEmpty ? storedAuthor : accountName) ?? '',
          onConfirm: (name, author) =>
              _confirmSave(screenContext, dialogContext, queue, name, defaultName, author),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Runs the actual bridge call for a confirmed save — called by
  /// [_SaveDialog] itself, which owns the double-tap guard on its Save
  /// button (each tap would otherwise create a NEW playlist; there's no way
  /// to dedupe after the fact). Always resolves the dialog (pops it) on
  /// both success and failure, then reports the outcome as a snackbar on
  /// the screen underneath.
  Future<void> _confirmSave(
    BuildContext screenContext,
    BuildContext dialogContext,
    List<QueueTrack> queue,
    String rawName,
    String defaultName,
    String rawAuthor,
  ) async {
    final trimmed = rawName.trim();
    final name = trimmed.isEmpty ? defaultName : trimmed;
    // Attribution: without an explicit author Apple shows the Xcode product
    // name ("Runner"). The user's typed name wins; blank falls back to the
    // app name. Remembered (even if the save then fails) so the next
    // dialog prefills it — it's the user's name, not per-playlist data.
    final trimmedAuthor = rawAuthor.trim();
    final author = trimmedAuthor.isEmpty ? 'mixtape' : trimmedAuthor;
    if (trimmedAuthor.isNotEmpty) {
      await ref.read(authorStoreProvider).write(trimmedAuthor);
    }
    final ids = [for (final t in queue) if (t.appleId != null) t.appleId!];
    try {
      final result = await ref.read(musicKitBridgeProvider).createPlaylist(
            name,
            ids,
            author: author,
            description: 'made by mixtape',
          );
      // A zero-added save is a false taste signal, not evidence of a like —
      // see _postEvent's doc comment.
      if (result.added > 0) _postEvent('saved_playlist');
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!screenContext.mounted) return;
      _showSnack(screenContext, _saveSuccessMessage(result.added, result.failed));
    } on MusicKitException catch (e) {
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!screenContext.mounted) return;
      // The bridge's message carries Apple's actual failure reason (see
      // MusicKitBridge._fromPlatform) — hiding it behind a generic string
      // made real device failures undiagnosable.
      _showSnack(screenContext, "couldn't save the playlist — ${e.message}");
    }
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _playSuccessMessage(int skipped) => skipped > 0
      ? 'playing in Apple Music — $skipped track${skipped == 1 ? '' : 's'} skipped (not in Apple Music)'
      : 'playing in Apple Music';

  String _saveSuccessMessage(int added, int failed) => failed > 0
      ? 'saved $added songs to Apple Music ($failed failed)'
      : 'saved $added songs to Apple Music';

  /// Null when Play/Save are actionable; otherwise the tooltip explaining
  /// why they're disabled — an empty queue has nothing to act on, and a
  /// queue whose tracks are ALL missing an Apple Music match can't be
  /// played or saved at all (a partial match still works: the filtered
  /// track count is reported in the success snackbar instead).
  String? _actionsDisabledReason(List<QueueTrack> queue) {
    if (queue.isEmpty) return 'nothing queued yet';
    if (queue.every((t) => t.appleId == null)) return "these tracks aren't in Apple Music";
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider(widget.sessionId));
    // Kick off the /me fetch as soon as the screen opens so the account
    // name is (usually) resolved by the time the save dialog reads it
    // non-blocking — see _openSaveDialog.
    ref.watch(accountNameProvider);

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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.transientError!)));
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }
    });

    // Same defensive ordering as ChatScreen: hasError checked before
    // isLoading/hasValue so a Riverpod retry-in-progress doesn't sit on a
    // bare spinner, and hasValue checked so a live list mid-background-
    // refresh-failure never blanks out to the full-screen error.
    if (chatAsync.hasError && !chatAsync.hasValue) {
      return _QueueErrorScreen(onRetry: () => ref.invalidate(chatProvider(widget.sessionId)));
    }

    if (!chatAsync.hasValue) {
      return Scaffold(
        appBar: AppBar(), // present on every state, see ChatScreen's identical comment
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final state = chatAsync.value!;

    // [visibleQueue] — not state.queue — drives EVERY surface on this
    // screen: the list, the empty state, whether Play/Save are actionable,
    // and the ids handed to Apple Music. A row the user has just swiped
    // away shouldn't play or be saved into a playlist just because its
    // removal hasn't round-tripped yet.
    final visibleQueue = state.queue.where((t) => !_hiddenTrackIds.contains(t.trackId)).toList();
    final disabledReason = _actionsDisabledReason(visibleQueue);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.session.title),
        actions: [
          IconButton(
            key: const Key('play-button'),
            tooltip: disabledReason ?? 'Play in Apple Music',
            onPressed: (disabledReason == null && !_playing)
                ? () => _handlePlay(context, visibleQueue)
                : null,
            icon: const Icon(Icons.play_circle),
          ),
          IconButton(
            key: const Key('save-button'),
            tooltip: disabledReason ?? 'Save as playlist',
            onPressed: (disabledReason == null && !_saving)
                ? () => _openSaveDialog(context, visibleQueue, state.session.title)
                : null,
            icon: const Icon(Icons.playlist_add),
          ),
        ],
      ),
      body: SafeArea(
        child: visibleQueue.isEmpty
            ? const _EmptyQueue()
            : ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: visibleQueue.length,
                // Each row supplies its own ReorderableDragStartListener on
                // the drag handle — the default handles would add a second,
                // duplicate one on every row.
                buildDefaultDragHandles: false,
                onReorder: (oldIndex, newIndex) =>
                    _handleReorder(visibleQueue, oldIndex, newIndex),
                itemBuilder: (context, index) {
                  final track = visibleQueue[index];
                  return _QueueRow(
                    key: ValueKey('queue-row-${track.trackId}'),
                    index: index,
                    track: track,
                    expanded: _expandedTrackIds.contains(track.trackId),
                    onToggle: () => _toggleReason(track.trackId),
                    onDismissed: () => _handleDismiss(track),
                  );
                },
              ),
      ),
    );
  }
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

class _QueueErrorScreen extends StatelessWidget {
  const _QueueErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              const Text("couldn't load this queue", textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('queue-retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('ask the DJ for a tape', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.index,
    required this.track,
    required this.expanded,
    required this.onToggle,
    required this.onDismissed,
  });

  final int index;
  final QueueTrack track;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onDismissed;

  Widget _dismissBackground(ThemeData theme, Alignment alignment) => Container(
    color: theme.colorScheme.errorContainer,
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasReason = track.reason != null && track.reason!.trim().isNotEmpty;

    return Dismissible(
      key: ValueKey('dismissible-${track.trackId}'),
      background: _dismissBackground(theme, Alignment.centerLeft),
      secondaryBackground: _dismissBackground(theme, Alignment.centerRight),
      onDismissed: (_) => onDismissed(),
      child: Material(
        color: theme.colorScheme.surface,
        child: InkWell(
          key: Key('queue-row-tap-${track.trackId}'),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(width: 28, child: Text('${index + 1}', style: theme.textTheme.bodyMedium)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        key: Key('drag-handle-${track.trackId}'),
                        padding: const EdgeInsets.only(left: 8),
                        child: Icon(Icons.drag_handle, color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 6),
                  Text(
                    hasReason ? track.reason! : 'no notes from the DJ',
                    key: Key('queue-row-reason-${track.trackId}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: hasReason ? FontStyle.normal : FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({
    required this.defaultName,
    required this.defaultAuthor,
    required this.onConfirm,
  });

  final String defaultName;
  final String defaultAuthor;
  final Future<void> Function(String name, String author) onConfirm;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.defaultName);
  late final TextEditingController _authorController =
      TextEditingController(text: widget.defaultAuthor);
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    _authorController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return; // guards a double-tap: each tap would otherwise create a NEW playlist
    setState(() => _submitting = true);
    await widget.onConfirm(_controller.text, _authorController.text);
    // widget.onConfirm always pops this dialog itself (success or failure)
    // before returning, so in practice this widget is already gone by the
    // time control reaches here and the line below never runs — kept only
    // so _submitting can't get stuck at true if that contract ever changes.
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('playlist-name-field'),
            controller: _controller,
            autofocus: true,
            enabled: !_submitting,
            decoration: const InputDecoration(labelText: 'Playlist name'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('playlist-author-field'),
            controller: _authorController,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: 'Your name',
              helperText: 'shown under the playlist in Apple Music',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-confirm-button'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
