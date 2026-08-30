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
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  final Set<String> _expandedTrackIds = {};

  /// Filters a just-swiped row out of the render immediately. [Dismissible]
  /// requires the item to be gone from the underlying list by the very next
  /// build or it asserts ("A dismissed Dismissible widget is still part of
  /// the tree") — but this screen is server-canonical (no optimistic data
  /// edits), so the REAL removal only lands once the queue-ops response
  /// comes back. This set is a pure rendering patch, not a data mutation:
  /// it's cleared the moment [ChatState.queueVersion] actually changes
  /// (success or a stale-replacement both bump it), so a failed/no-op
  /// removal naturally un-hides the row instead of silently losing it.
  final Set<String> _hiddenTrackIds = {};
  int? _lastSeenVersion;

  bool _playing = false;
  bool _saving = false;

  void _toggleReason(String trackId) {
    setState(() {
      if (!_expandedTrackIds.add(trackId)) _expandedTrackIds.remove(trackId);
    });
  }

  void _handleDismiss(QueueTrack track) {
    setState(() => _hiddenTrackIds.add(track.trackId));
    ref
        .read(chatProvider(widget.sessionId).notifier)
        .applyOps([QueueOp.remove(track.position)]);
  }

  /// [newIndex] arrives in [ReorderableListView]'s own pre-removal indexing:
  /// moving an item DOWN reports an index one past where it actually lands
  /// once the dragged item is taken out of the list, so it's decremented by
  /// one in that case before becoming the op's target position.
  void _handleReorder(int oldIndex, int newIndex) {
    var adjusted = newIndex;
    if (adjusted > oldIndex) adjusted -= 1;
    if (adjusted == oldIndex) return;
    ref
        .read(chatProvider(widget.sessionId).notifier)
        .applyOps([QueueOp.move(oldIndex, adjusted)]);
  }

  Future<void> _handlePlay(BuildContext screenContext, List<QueueTrack> queue) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      final ids = [for (final t in queue) if (t.appleId != null) t.appleId!];
      final skipped = queue.length - ids.length;
      await ref.read(musicKitBridgeProvider).playQueue(ids);
      if (!screenContext.mounted) return;
      _showSnack(screenContext, _playSuccessMessage(skipped));
    } on MusicKitException {
      if (!screenContext.mounted) return;
      _showSnack(screenContext, "couldn't reach Apple Music — try again");
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
      await showDialog<void>(
        context: screenContext,
        builder: (dialogContext) => _SaveDialog(
          defaultName: defaultName,
          onConfirm: (name) => _confirmSave(screenContext, dialogContext, queue, name, defaultName),
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
  ) async {
    final trimmed = rawName.trim();
    final name = trimmed.isEmpty ? defaultName : trimmed;
    final ids = [for (final t in queue) if (t.appleId != null) t.appleId!];
    try {
      final result = await ref.read(musicKitBridgeProvider).createPlaylist(name, ids);
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!screenContext.mounted) return;
      _showSnack(screenContext, _saveSuccessMessage(result.added, result.failed));
    } on MusicKitException {
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!screenContext.mounted) return;
      _showSnack(screenContext, "couldn't save the playlist — try again");
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

    ref.listen(chatProvider(widget.sessionId), (previous, next) {
      final state = next.value;
      if (state == null) return;

      // Any real version bump (success or a stale-replacement) means the
      // server's view has moved on — a locally-hidden row is either
      // genuinely gone now (the fresh queue just won't contain it) or was
      // never actually removed (a failed/no-op call), in which case it
      // must reappear rather than stay stuck invisible.
      if (_lastSeenVersion != null && state.queueVersion != _lastSeenVersion) {
        _hiddenTrackIds.clear();
      }
      _lastSeenVersion = state.queueVersion;

      if (state.transientError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.transientError!)));
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
    _lastSeenVersion ??= state.queueVersion;

    final visibleQueue = state.queue.where((t) => !_hiddenTrackIds.contains(t.trackId)).toList();
    final disabledReason = _actionsDisabledReason(state.queue);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.session.title),
        actions: [
          IconButton(
            key: const Key('play-button'),
            tooltip: disabledReason ?? 'Play in Apple Music',
            onPressed: (disabledReason == null && !_playing)
                ? () => _handlePlay(context, state.queue)
                : null,
            icon: const Icon(Icons.play_circle),
          ),
          IconButton(
            key: const Key('save-button'),
            tooltip: disabledReason ?? 'Save as playlist',
            onPressed: (disabledReason == null && !_saving)
                ? () => _openSaveDialog(context, state.queue, state.session.title)
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
                onReorder: _handleReorder,
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
  const _SaveDialog({required this.defaultName, required this.onConfirm});

  final String defaultName;
  final Future<void> Function(String name) onConfirm;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.defaultName);
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return; // guards a double-tap: each tap would otherwise create a NEW playlist
    setState(() => _submitting = true);
    await widget.onConfirm(_controller.text);
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
      content: TextField(
        key: const Key('playlist-name-field'),
        controller: _controller,
        autofocus: true,
        enabled: !_submitting,
        decoration: const InputDecoration(labelText: 'Playlist name'),
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
