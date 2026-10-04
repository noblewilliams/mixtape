/// "Playlists": the whole collection as flush rows, paged
/// (`docs/mockups/approved/2026-09-04-web-your-music-integration.md`,
/// restyled for the approved shell by plan task 8.1).
///
/// Still pushed from Your music; the Library tab shows the same rows inline
/// through [playlistCollectionSliver].
library;

import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_models.dart';
import '../providers/playlist_providers.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/playlist_artwork.dart';
import 'music_sources_screen.dart' show LibraryBackScaffold;
import 'playlist_detail_screen.dart';

/// The copy the Library surfaces share for an empty or broken collection.
const String kNoPlaylistsTitle = 'No playlists yet';
const String kNoPlaylistsBody =
    'Playlists you save in Apple Music or import from Spotify show up here.';
const String kPlaylistsFailed = "Couldn't load your playlists.";
const String kPlaylistsRefreshFailed = "Couldn't refresh playlists.";

/// The quiet retry shown at the end of a list that pages on scroll, after a
/// page failed (the Library tab; the browser keeps its own button).
const Key kPlaylistsLoadMoreRetryKey = Key('library-load-more');

/// The art tile's side on a playlist row (board L1: the 60 pt square motif).
const double kPlaylistArtSize = 60;

/// `41 songs · Apple Music`.
///
/// The board's third part — "· 4 unmatched" — has no field behind it on
/// [PlaylistSummary]; it arrives when the server exposes the count.
String playlistSubtitle(PlaylistSummary playlist) {
  final songs =
      '${playlist.entryCount} ${playlist.entryCount == 1 ? 'song' : 'songs'}';
  final source = switch (playlist.source) {
    'spotify_export' => 'Spotify import',
    'apple' => 'Apple Music',
    _ => 'Imported playlist',
  };
  return '$songs · $source';
}

/// One playlist as a flush row: 60 pt square art, name, counts, chevron.
class PlaylistFlushRow extends StatelessWidget {
  const PlaylistFlushRow({
    super.key,
    required this.playlist,
    required this.isFirst,
  });

  final PlaylistSummary playlist;

  /// Rows are built lazily, so each one is told its own place in the list.
  final bool isFirst;

  @override
  Widget build(BuildContext context) => FlushRow(
    key: Key('playlist-row-${playlist.id}'),
    isFirst: isFirst,
    leading: PlaylistArtwork(
      urlTemplate: playlist.artworkUrlTemplate,
      bgColor: playlist.artworkBgColor,
      size: kPlaylistArtSize,
      borderRadius: MixtapeMetrics.tileRadius,
    ),
    leadingSize: kPlaylistArtSize,
    title: playlist.name,
    subtitle: playlistSubtitle(playlist),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
      ),
    ),
  );
}

/// The quiet stand-in rows shown while the first page is in flight.
class PlaylistSkeletonRows extends StatelessWidget {
  const PlaylistSkeletonRows({super.key, this.rows = 4});

  final int rows;

  static const Key rowKey = Key('playlist-skeleton-row');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tokens.hairline,
        borderRadius: BorderRadius.circular(3),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            key: i == 0 ? rowKey : null,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                SquareArt(size: kPlaylistArtSize, placeholder: tokens.hairline),
                const SizedBox(width: FlushRow.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(double.infinity, 14),
                      const SizedBox(height: 8),
                      bar(120, 11),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The empty collection, shared by the browser and the Library tab.
class PlaylistsEmpty extends StatelessWidget {
  const PlaylistsEmpty({super.key});

  static const Key emptyKey = Key('playlists-empty');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      key: emptyKey,
      padding: const EdgeInsets.only(top: 40, bottom: 24),
      child: Column(
        children: [
          Text(kNoPlaylistsTitle, style: tokens.rowTitle),
          const SizedBox(height: 6),
          Text(
            kNoPlaylistsBody,
            textAlign: TextAlign.center,
            style: tokens.secondary,
          ),
        ],
      ),
    );
  }
}

/// The collection failed to load at all; the retry is the caller's.
class PlaylistsFailed extends StatelessWidget {
  const PlaylistsFailed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  static const Key retryKey = Key('playlists-retry');

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 40, bottom: 24),
    child: Column(
      children: [
        Text(
          kPlaylistsFailed,
          textAlign: TextAlign.center,
          style: context.tokens.body,
        ),
        const SizedBox(height: 16),
        TapeButton(key: retryKey, label: 'Try again', onPressed: onRetry),
      ],
    ),
  );
}

/// The paged collection as a sliver, shared with the Library tab.
///
/// Riverpod retries a failed provider, which parks it back in
/// [AsyncValue.isLoading] with the error still attached, so failure is read
/// off `hasError` with no value — the rule the sources screen already uses —
/// rather than off `when`'s loading branch.
///
/// [loadMoreButton] false leaves paging to the caller's scroll position.
Widget playlistCollectionSliver(
  WidgetRef ref,
  AsyncValue<PlaylistCollectionState> collection, {
  bool loadMoreButton = true,
}) {
  final state = collection.value;
  if (state == null) {
    return collection.hasError
        ? SliverToBoxAdapter(
            child: PlaylistsFailed(
              onRetry: () =>
                  ref.read(playlistCollectionProvider.notifier).refresh(),
            ),
          )
        : const SliverToBoxAdapter(child: PlaylistSkeletonRows());
  }
  if (state.playlists.isEmpty) {
    return const SliverToBoxAdapter(child: PlaylistsEmpty());
  }
  // A list that pages on scroll still needs a way back after a page failed.
  final retryOnly = !loadMoreButton && state.loadMoreFailed;
  final trailing = state.nextCursor != null && (loadMoreButton || retryOnly)
      ? 1
      : 0;
  return SliverList.builder(
    itemCount: state.playlists.length + trailing,
    itemBuilder: (context, index) {
      if (index == state.playlists.length) {
        final loadMore = state.loadingMore
            ? null
            : () => ref.read(playlistCollectionProvider.notifier).loadMore();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: retryOnly
                ? TextAction(
                    key: kPlaylistsLoadMoreRetryKey,
                    label: 'Load more',
                    onPressed: loadMore,
                  )
                : TapeButton(
                    key: const Key('load-more-playlists'),
                    label: state.loadMoreFailed
                        ? 'Try loading more'
                        : 'Load more',
                    onPressed: loadMore,
                  ),
          ),
        );
      }
      return PlaylistFlushRow(
        playlist: state.playlists[index],
        isFirst: index == 0,
      );
    },
  );
}

class PlaylistBrowserScreen extends ConsumerWidget {
  const PlaylistBrowserScreen({super.key});

  static const Key backKey = Key('playlists-back');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(playlistCollectionProvider);

    return LibraryBackScaffold(
      title: 'Playlists',
      backKey: backKey,
      onRefresh: () async {
        final ok = await ref
            .read(playlistCollectionProvider.notifier)
            .refresh();
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            mixtapeSnackBar(
              message: kPlaylistsRefreshFailed,
              kind: FeedbackKind.error,
            ),
          );
        }
      },
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(
            bottom: LibraryBackScaffold.bottomInset,
          ),
          sliver: playlistCollectionSliver(ref, collection),
        ),
      ],
    );
  }
}
