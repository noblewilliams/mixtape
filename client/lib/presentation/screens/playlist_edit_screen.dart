import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_edit_models.dart';
import '../providers/playlist_providers.dart';
import '../widgets/playlist_artwork.dart';

class PlaylistEditScreen extends ConsumerStatefulWidget {
  const PlaylistEditScreen({super.key, required this.draftId});

  final String draftId;

  @override
  ConsumerState<PlaylistEditScreen> createState() => _PlaylistEditScreenState();
}

class _PlaylistEditScreenState extends ConsumerState<PlaylistEditScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await ref
        .read(playlistEditThreadProvider(widget.draftId).notifier)
        .send(text);
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(playlistEditThreadProvider(widget.draftId));
    ref.listen(playlistEditThreadProvider(widget.draftId), (previous, next) {
      final state = next.value;
      if (state?.transientError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state!.transientError!)));
        ref
            .read(playlistEditThreadProvider(widget.draftId).notifier)
            .clearTransientError();
      }
      if ((next.value?.messages.length ?? 0) !=
          (previous?.value?.messages.length ?? 0)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        });
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: Text(thread.value?.view.draft.baseName ?? 'Playlist edit'),
      ),
      body: SafeArea(
        child: thread.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Couldn't load this private draft."),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.invalidate(
                    playlistEditThreadProvider(widget.draftId),
                  ),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
          data: _body,
        ),
      ),
    );
  }

  Widget _body(PlaylistEditThreadState state) {
    final changes = state.view.diff.changeCount;
    return Column(
      children: [
        _TruthHeader(view: state.view),
        Expanded(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            children: [
              if (state.messages.isEmpty)
                const _MessageBubble(
                  message:
                      'Tell me what you want to add, remove, replace, or move.',
                  role: 'dj',
                ),
              for (final message in state.messages)
                _MessageBubble(
                  message: message.message.content,
                  role: message.message.role,
                  error: message.isError,
                  onRetry: message.retryContent == null
                      ? null
                      : () => ref
                            .read(
                              playlistEditThreadProvider(
                                widget.draftId,
                              ).notifier,
                            )
                            .send(message.retryContent!),
                ),
              if (changes > 0) _ChangeSummary(view: state.view),
              if (state.sending) const _ThinkingBubble(),
            ],
          ),
        ),
        if (changes > 0)
          Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$changes ${changes == 1 ? 'change' : 'changes'}'),
                        Text(
                          'Source untouched',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    key: const Key('review-draft'),
                    onPressed: () => _openReview(state.view),
                    child: const Text('Review'),
                  ),
                ],
              ),
            ),
          ),
        Material(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('playlist-edit-composer'),
                    controller: _controller,
                    enabled: !state.sending,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textInputAction: TextInputAction.send,
                    onSubmitted: state.sending ? null : (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Tell the DJ what to change…',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('playlist-edit-send'),
                  tooltip: 'Send',
                  onPressed: state.sending ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openReview(PlaylistEditView view) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ReviewSheet(view: view),
  );
}

class _TruthHeader extends StatelessWidget {
  const _TruthHeader({required this.view});

  final PlaylistEditView view;

  @override
  Widget build(BuildContext context) {
    final changes = view.diff.changeCount;
    final source = view.draft.sourceType == 'spotify_export'
        ? 'Spotify export'
        : 'Apple source';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        child: Row(
          children: [
            Expanded(
              child: _TruthCell(
                label: 'Source',
                value: view.draft.baseName,
                detail:
                    '$source · ${view.entries.length - view.diff.added.length + view.diff.removed.length} songs',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TruthCell(
                label: 'Private draft',
                value: changes == 0
                    ? 'No changes'
                    : '$changes ${changes == 1 ? 'change' : 'changes'}',
                detail: 'v${view.draft.version} · private only',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TruthCell extends StatelessWidget {
  const _TruthCell({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(13),
      color: Theme.of(context).colorScheme.surface,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.role,
    this.error = false,
    this.onRetry,
  });

  final String message;
  final String role;
  final bool error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final user = role == 'user';
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: error
              ? colors.errorContainer
              : user
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: user || error
              ? null
              : Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try that request again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) =>
      const _MessageBubble(message: 'The DJ is arranging…', role: 'dj');
}

class _ChangeSummary extends StatelessWidget {
  const _ChangeSummary({required this.view});

  final PlaylistEditView view;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 8),
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Draft updated · v${view.draft.version}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 7),
          Text(
            _summary(view.diff),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final entry in view.review.added) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.add_circle_outline, size: 19),
                const SizedBox(width: 8),
                Expanded(child: Text('${entry.title} · ${entry.artist}')),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

String _summary(PlaylistEditDiff diff) {
  final parts = <String>[];
  if (diff.added.isNotEmpty) parts.add('${diff.added.length} added');
  if (diff.removed.isNotEmpty) parts.add('${diff.removed.length} removed');
  if (diff.moved.isNotEmpty) parts.add('${diff.moved.length} moved');
  if (diff.replaced.isNotEmpty) parts.add('${diff.replaced.length} replaced');
  return parts.join(' · ');
}

class _ReviewSheet extends StatelessWidget {
  const _ReviewSheet({required this.view});

  final PlaylistEditView view;

  @override
  Widget build(BuildContext context) {
    final spotify = view.draft.sourceType == 'spotify_export';
    final unresolved = view.entries.where((entry) => !entry.resolved).length;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Review private draft',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Create a revised copy',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                spotify
                    ? 'This Spotify export stays untouched. A later apply step can create an Apple Music copy after every song is matched.'
                    : 'Apple Music cannot safely place structural edits into the middle of this source. Mixtape will create a revised copy and leave “${view.draft.baseName}” untouched.',
              ),
            ),
            const SizedBox(height: 17),
            Text(
              _summary(view.diff),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            for (final entry in view.review.added)
              _ReviewRow(
                icon: Icons.add_rounded,
                entry: entry,
                detail: _placement(view.entries, entry.position),
              ),
            for (final entry in view.review.removed)
              _ReviewRow(
                icon: Icons.remove_rounded,
                entry: entry,
                detail: 'Removed from position ${entry.position + 1}',
              ),
            for (final entry in view.review.moved)
              _ReviewRow(
                icon: Icons.swap_vert_rounded,
                entry: entry,
                detail:
                    'Moved from ${entry.fromPosition! + 1} to ${entry.position + 1}',
              ),
            for (final replacement in view.review.replaced)
              _ReviewRow(
                icon: Icons.sync_alt_rounded,
                entry: replacement.after,
                detail:
                    'Replaces “${replacement.before.title}” at position ${replacement.after.position + 1}',
              ),
            if (unresolved > 0) ...[
              const SizedBox(height: 12),
              Text(
                '$unresolved local or unmatched ${unresolved == 1 ? 'song blocks' : 'songs block'} apply. Mixtape will not leave anything out.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('apply-draft'),
              onPressed: null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Apple apply is not available in this build'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              child: const Text('Keep editing'),
            ),
          ],
        ),
      ),
    );
  }

  String _placement(List<PlaylistEditEntry> entries, int position) {
    final before = position > 0 ? entries[position - 1].title : null;
    final after = position + 1 < entries.length
        ? entries[position + 1].title
        : null;
    if (before != null && after != null) {
      return 'After “$before” · before “$after”';
    }
    if (before != null) return 'After “$before” · at the end';
    if (after != null) return 'Before “$after” · at the beginning';
    return 'Only song in the draft';
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.icon,
    required this.entry,
    required this.detail,
  });

  final IconData icon;
  final PlaylistEditReviewEntry entry;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21),
        const SizedBox(width: 10),
        PlaylistArtwork(
          urlTemplate: entry.artworkUrlTemplate,
          bgColor: entry.artworkBgColor,
          size: 38,
          borderRadius: 8,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.title, style: Theme.of(context).textTheme.titleSmall),
              Text(entry.artist, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 3),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}
