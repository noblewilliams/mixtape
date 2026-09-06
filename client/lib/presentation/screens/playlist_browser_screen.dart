import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_models.dart';
import '../providers/playlist_providers.dart';
import '../widgets/playlist_artwork.dart';
import 'playlist_detail_screen.dart';

class PlaylistBrowserScreen extends ConsumerWidget {
  const PlaylistBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(playlistCollectionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      body: SafeArea(
        child: collection.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _LoadError(
            onRetry: () =>
                ref.read(playlistCollectionProvider.notifier).refresh(),
          ),
          data: (state) => RefreshIndicator(
            onRefresh: () async {
              final ok = await ref
                  .read(playlistCollectionProvider.notifier)
                  .refresh();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Couldn't refresh playlists.")),
                );
              }
            },
            child: state.playlists.isEmpty
                ? const _EmptyCollection()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount:
                        state.playlists.length +
                        (state.nextCursor == null ? 0 : 1),
                    itemBuilder: (context, index) {
                      if (index == state.playlists.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: OutlinedButton(
                            key: const Key('load-more-playlists'),
                            onPressed: state.loadingMore
                                ? null
                                : () => ref
                                      .read(playlistCollectionProvider.notifier)
                                      .loadMore(),
                            child: Text(
                              state.loadMoreFailed
                                  ? 'Try loading more'
                                  : 'Load more',
                            ),
                          ),
                        );
                      }
                      return _PlaylistRow(playlist: state.playlists[index]);
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlist});

  final PlaylistSummary playlist;

  @override
  Widget build(BuildContext context) {
    final source = switch (playlist.source) {
      'spotify_export' => 'Spotify export',
      'apple' => 'Apple Music',
      _ => 'Imported playlist',
    };
    final songs =
        '${playlist.entryCount} ${playlist.entryCount == 1 ? 'song' : 'songs'}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('playlist-row-${playlist.id}'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              PlaylistArtwork(
                urlTemplate: playlist.artworkUrlTemplate,
                bgColor: playlist.artworkBgColor,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$source · $songs',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCollection extends StatelessWidget {
  const _EmptyCollection();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: const [
      SizedBox(height: 120),
      Icon(Icons.library_music_outlined, size: 38),
      SizedBox(height: 16),
      Text('No playlists yet.', textAlign: TextAlign.center),
      SizedBox(height: 8),
      Text(
        'Sync Apple Music or import Spotify account data, then they will appear here.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Couldn't load your playlists."),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
