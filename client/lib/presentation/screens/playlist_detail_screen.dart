import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_models.dart';
import '../providers/playlist_providers.dart';
import '../providers/playlist_taste_provider.dart';
import '../providers/new_mix_inspiration_provider.dart';
import '../widgets/playlist_artwork.dart';
import 'playlist_edit_screen.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    this.onInspire,
  });

  final String playlistId;
  final ValueChanged<PlaylistSummary>? onInspire;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  bool _startingDraft = false;
  bool _confirmingTaste = false;

  Future<void> _startDraft() async {
    if (_startingDraft) return;
    setState(() => _startingDraft = true);
    try {
      final view = await ref.read(playlistDraftStarterProvider)(
        widget.playlistId,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlaylistEditScreen(draftId: view.draft.id),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't start a private draft.")),
        );
      }
    } finally {
      if (mounted) setState(() => _startingDraft = false);
    }
  }

  void _inspire(PlaylistSummary playlist) {
    if (widget.onInspire != null) {
      widget.onInspire!(playlist);
      return;
    }
    ref.read(newMixInspirationProvider.notifier).select(playlist);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _confirmTaste() async {
    if (_confirmingTaste) return;
    _confirmingTaste = true;
    bool? approved;
    try {
      approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Did you choose these songs?'),
          content: const Text(
            'Confirm only if you personally chose the songs in this playlist. This helps the DJ understand your taste.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
    } finally {
      _confirmingTaste = false;
    }
    if (approved == true && mounted) {
      await ref
          .read(playlistTasteProvider(widget.playlistId).notifier)
          .setConfirmed(true);
    }
  }

  Widget _tasteControls(PlaylistTasteState taste) {
    final notifier = ref.read(
      playlistTasteProvider(widget.playlistId).notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your taste', style: Theme.of(context).textTheme.labelLarge),
        if (taste.loading || taste.writing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Checking playlist confirmation…'),
          )
        else if (taste.unknown) ...[
          const Text(
            'Playlist confirmation is unavailable. Reload before changing it.',
          ),
          TextButton(
            onPressed: notifier.refresh,
            child: const Text('Reload confirmation'),
          ),
        ] else if (taste.confirmed) ...[
          const Text('You confirmed choosing these songs.'),
          TextButton(
            onPressed: taste.canRemove
                ? () => notifier.setConfirmed(false)
                : null,
            child: const Text('Remove confirmation'),
          ),
        ] else if (taste.canConfirm)
          TextButton(
            onPressed: _confirmTaste,
            child: const Text('I chose these songs'),
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('This playlist stays neutral in your taste profile.'),
          ),
        if (taste.error != null && !taste.unknown)
          const Text(
            'The confirmation was not changed. Review the current status before trying again.',
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(playlistDetailProvider(widget.playlistId));
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
      body: SafeArea(
        child: detail.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Couldn't load this playlist."),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () =>
                      ref.invalidate(playlistDetailProvider(widget.playlistId)),
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

  Widget _body(PlaylistDetail detail) {
    final taste = ref.watch(playlistTasteProvider(widget.playlistId));
    detail = taste.applyTo(detail);
    final playlist = detail.playlist;
    final source = switch (playlist.source) {
      'spotify_export' => 'Spotify export',
      'apple' => 'Apple Music',
      _ => 'Imported playlist',
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PlaylistArtwork(
              urlTemplate: playlist.artworkUrlTemplate,
              bgColor: playlist.artworkBgColor,
              size: 116,
              borderRadius: 16,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    playlist.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontFamily: 'Noteworthy',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text('${playlist.entryCount} songs'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: playlist.inLibrary ? () => _inspire(playlist) : null,
            child: const Text('Make a mix inspired by this'),
          ),
        ),
        _tasteControls(taste),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Make a private draft with the DJ. Your source playlist will not change until you review and confirm.',
                ),
                const SizedBox(height: 13),
                FilledButton.icon(
                  key: const Key('edit-with-dj'),
                  onPressed: _startingDraft ? null : _startDraft,
                  icon: _startingDraft
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.edit_outlined),
                  label: Text(
                    _startingDraft
                        ? 'Starting private draft…'
                        : 'Edit with the DJ',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final entry in detail.entries) _TrackRow(entry: entry),
        if (detail.nextEntryCursor != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              key: const Key('load-more-playlist-entries'),
              onPressed: () async {
                try {
                  await ref
                      .read(playlistDetailProvider(widget.playlistId).notifier)
                      .loadMore();
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Couldn't load more songs."),
                      ),
                    );
                  }
                }
              },
              child: const Text('Load more songs'),
            ),
          ),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.entry});

  final PlaylistEntry entry;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: SizedBox(
      width: 58,
      child: Row(
        children: [
          SizedBox(width: 20, child: Text('${entry.position + 1}')),
          const SizedBox(width: 5),
          PlaylistArtwork(
            urlTemplate: entry.artworkUrlTemplate,
            bgColor: entry.artworkBgColor,
            size: 32,
            borderRadius: 7,
          ),
        ],
      ),
    ),
    title: Text(entry.title),
    subtitle: Text(entry.artist),
    trailing: entry.resolved
        ? null
        : const Text('Local or unmatched', style: TextStyle(fontSize: 11)),
  );
}
