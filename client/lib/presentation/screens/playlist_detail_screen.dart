import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_models.dart';
import '../providers/playlist_providers.dart';
import '../widgets/playlist_artwork.dart';
import 'playlist_edit_screen.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  bool _startingDraft = false;

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
        const SizedBox(height: 18),
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
