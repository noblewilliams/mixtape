/// One playlist, restyled onto the native design
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Titles, controls and
/// lists; plan `docs/superpowers/plans/2026-09-17-native-design-
/// implementation.md` task 8.2).
///
/// Behaviour is the September 8 parity approval's: the personal-curation
/// confirmation and its removal keep their modal and their canonical recovery,
/// inspiration hands Home the exact playlist without writing anything, and the
/// private DJ draft (2026-09-06) stays a separate, explicit entry — now in the
/// More menu rather than on a card of its own.
///
/// Pushed inside a tab `Navigator`, so it draws its own glass chrome and never
/// assumes it is the app root.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_models.dart';
import '../providers/new_mix_inspiration_provider.dart';
import '../providers/playlist_providers.dart';
import '../providers/playlist_taste_provider.dart';
import '../providers/shell_providers.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
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

  /// The header's cover, per the board's 120 pt detail art.
  static const double headerArtSize = 120;

  /// The square motif at row size.
  static const double rowArtSize = 48;

  /// The track number's column, ahead of the art.
  static const double rowNumberWidth = 22;

  /// The gap between the number and the art.
  static const double rowNumberGap = 8;

  /// The leading column a row's hairline is inset past.
  static const double rowLeadingWidth =
      rowNumberWidth + rowNumberGap + rowArtSize;

  /// At or above this text scale the header stacks rather than squeezing the
  /// meta line beside the art.
  static const double stackScale = 1.5;

  /// The title shown before the playlist's own name arrives.
  static const String pendingTitle = 'Playlist';

  static const int skeletonRows = 4;

  static Key skeletonRowKey(int index) =>
      ValueKey('playlist-detail.skeleton-$index');

  static const Key backKey = Key('playlist-detail-back');
  static const Key moreKey = Key('playlist-detail-more');
  static const Key headerArtKey = Key('playlist-detail-art');
  static const Key inspireKey = Key('playlist-inspire');
  static const Key retryKey = Key('playlist-detail-retry');
  static const Key loadMoreKey = Key('load-more-playlist-entries');

  /// The private-draft entry, keyed as it was when it sat on a card.
  static const Key editWithDjKey = Key('edit-with-dj');

  /// The label a row wears when its song has no exact match to play.
  static const String unmatchedLabel = 'Local or unmatched';

  /// The private-draft promise from the September 6 approval, carried on the
  /// entry that starts one.
  static const String draftPromise =
      'Your source playlist will not change until you review and confirm.';

  /// Shown under the header while the draft is being opened, because the menu
  /// that started it has already closed.
  static const String startingDraft = 'Starting private draft…';

  static const Key startingDraftKey = Key('playlist-detail-starting-draft');

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
    // The composer that takes the attachment is Home's, so the shell switches
    // tabs and this tab's navigator goes back to its own root — never a
    // second HomeScreen pushed on top of the one already there.
    ref.read(selectedTabProvider.notifier).selectTab(AppTab.home);
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

  /// The one overflow entry: the private draft. Kept out of the body so the
  /// screen reads as the playlist, not as an editing surface.
  Future<void> _openMore(BuildContext anchor) async {
    final box = anchor.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
          key: PlaylistDetailScreen.editWithDjKey,
          value: 'edit',
          enabled: !_startingDraft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Edit with the DJ'),
                const SizedBox(height: 2),
                Text(
                  PlaylistDetailScreen.draftPromise,
                  style: context.tokens.meta.copyWith(
                    color: context.tokens.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    if (!mounted || action != 'edit') return;
    await _startDraft();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(playlistDetailProvider(widget.playlistId));
    final taste = ref.watch(playlistTasteProvider(widget.playlistId));
    final playlist = detail.value == null
        ? null
        : taste.applyTo(detail.value!).playlist;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: playlist?.name ?? PlaylistDetailScreen.pendingTitle,
          leading: GlassCluster(
            children: [
              GlassButton(
                key: PlaylistDetailScreen.backKey,
                icon: Icons.chevron_left,
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          trailing: GlassCluster(
            children: [
              Builder(
                builder: (anchor) => GlassButton(
                  key: PlaylistDetailScreen.moreKey,
                  icon: Icons.more_horiz,
                  label: 'More',
                  // The menu closes the moment the draft starts, so the button
                  // itself carries the wait.
                  onPressed: _startingDraft ? null : () => _openMore(anchor),
                ),
              ),
            ],
          ),
          slivers: detail.when(
            loading: () => const [_Skeleton()],
            error: (_, __) => [
              SliverToBoxAdapter(
                child: _Failure(
                  onRetry: () =>
                      ref.invalidate(playlistDetailProvider(widget.playlistId)),
                ),
              ),
            ],
            data: (loaded) => _slivers(taste.applyTo(loaded), taste),
          ),
        ),
      ),
    );
  }

  List<Widget> _slivers(PlaylistDetail detail, PlaylistTasteState taste) {
    final playlist = detail.playlist;
    return [
      SliverToBoxAdapter(child: _header(playlist, taste)),
      SliverList.list(
        children: [
          for (var index = 0; index < detail.entries.length; index++)
            _TrackRow(entry: detail.entries[index], isFirst: index == 0),
        ],
      ),
      if (detail.nextEntryCursor != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: TextAction(
                key: PlaylistDetailScreen.loadMoreKey,
                label: 'Load more songs',
                onPressed: _loadMore,
              ),
            ),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  Future<void> _loadMore() async {
    try {
      await ref
          .read(playlistDetailProvider(widget.playlistId).notifier)
          .loadMore();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't load more songs.")),
        );
      }
    }
  }

  /// The 120 pt cover, the meta line, the curation status and the one tape
  /// action this screen offers.
  Widget _header(PlaylistSummary playlist, PlaylistTasteState taste) {
    final tokens = context.tokens;
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) >=
        PlaylistDetailScreen.stackScale;
    final source = switch (playlist.source) {
      'spotify_export' => 'Spotify export',
      'apple' => 'Apple Music',
      _ => 'Imported playlist',
    };

    final art = SquareArt(
      key: PlaylistDetailScreen.headerArtKey,
      url: playlistArtworkUrl(
        playlist.artworkUrlTemplate,
        size: (PlaylistDetailScreen.headerArtSize * 3).round(),
      ),
      placeholder: playlistArtworkColor(playlist.artworkBgColor),
      size: PlaylistDetailScreen.headerArtSize,
    );

    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${playlist.entryCount} songs · $source',
          style: tokens.meta.copyWith(color: tokens.muted),
        ),
        const SizedBox(height: 8),
        _TasteBlock(
          taste: taste,
          onConfirm: _confirmTaste,
          onRemove: () => ref
              .read(playlistTasteProvider(widget.playlistId).notifier)
              .setConfirmed(false),
          onReload: () => ref
              .read(playlistTasteProvider(widget.playlistId).notifier)
              .refresh(),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stacked) ...[
            Align(alignment: Alignment.centerLeft, child: art),
            const SizedBox(height: 14),
            meta,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                art,
                const SizedBox(width: 16),
                Expanded(child: meta),
              ],
            ),
          const SizedBox(height: 16),
          TapeButton(
            key: PlaylistDetailScreen.inspireKey,
            label: 'Make a mix inspired by this',
            onPressed: playlist.inLibrary ? () => _inspire(playlist) : null,
          ),
          if (_startingDraft)
            Padding(
              key: PlaylistDetailScreen.startingDraftKey,
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tokens.muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      PlaylistDetailScreen.startingDraft,
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The curation status as a word, with the parity approval's actions and its
/// recovery copy underneath.
class _TasteBlock extends StatelessWidget {
  const _TasteBlock({
    required this.taste,
    required this.onConfirm,
    required this.onRemove,
    required this.onReload,
  });

  final PlaylistTasteState taste;
  final VoidCallback onConfirm;
  final VoidCallback onRemove;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final muted = tokens.meta.copyWith(color: tokens.muted);
    final children = <Widget>[];

    if (taste.loading || taste.writing) {
      children.add(Text('Checking playlist confirmation…', style: muted));
    } else if (taste.unknown) {
      children
        ..add(
          Text(
            'Playlist confirmation is unavailable. Reload before changing it.',
            style: muted,
          ),
        )
        ..add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(label: 'Reload confirmation', onPressed: onReload),
          ),
        );
    } else if (taste.confirmed) {
      children
        ..add(
          const StatusWord(label: 'You chose these songs', kind: StatusKind.ok),
        )
        ..add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              label: 'Remove confirmation',
              onPressed: taste.canRemove ? onRemove : null,
            ),
          ),
        );
    } else {
      // Neutral: the DJ counts nothing from this playlist as the listener's
      // own taste. Nothing to act on, so the word carries muted ink.
      children.add(
        const StatusWord(
          label: 'Neutral in your taste',
          kind: StatusKind.muted,
        ),
      );
      if (taste.canConfirm) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              label: 'I chose these songs',
              onPressed: onConfirm,
            ),
          ),
        );
      }
    }

    if (taste.error != null && !taste.unknown) {
      children.add(
        Text(
          'The confirmation was not changed. Review the current status before trying again.',
          style: muted,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// A flush song row: number, 48 pt art, title, artist — and, when the song has
/// no exact match, the em-line that says so.
class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.entry, required this.isFirst});

  final PlaylistEntry entry;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final subtitle = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          entry.artist,
          style: tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted),
        ),
        if (!entry.resolved)
          Text(
            PlaylistDetailScreen.unmatchedLabel,
            style: tokens.meta.copyWith(
              fontSize: 12,
              color: tokens.muted,
              fontStyle: FontStyle.italic,
            ),
          ),
      ],
    );

    return FlushRow(
      isFirst: isFirst,
      leadingSize: PlaylistDetailScreen.rowLeadingWidth,
      leading: SizedBox(
        width: PlaylistDetailScreen.rowLeadingWidth,
        child: Row(
          children: [
            SizedBox(
              width: PlaylistDetailScreen.rowNumberWidth,
              child: Text(
                '${entry.position + 1}',
                style: tokens.meta.copyWith(color: tokens.muted),
              ),
            ),
            const SizedBox(width: PlaylistDetailScreen.rowNumberGap),
            SquareArt(
              url: playlistArtworkUrl(
                entry.artworkUrlTemplate,
                size: (PlaylistDetailScreen.rowArtSize * 3).round(),
              ),
              placeholder: playlistArtworkColor(entry.artworkBgColor),
              size: PlaylistDetailScreen.rowArtSize,
            ),
          ],
        ),
      ),
      title: entry.title,
      subtitleWidget: subtitle,
    );
  }
}

/// Placeholder rows under live chrome, so the list area has the shape of what
/// is coming. The bars say nothing; one live region announces the wait.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  static const String loadingLabel = 'Loading this playlist';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverToBoxAdapter(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: loadingLabel,
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (
                var index = 0;
                index < PlaylistDetailScreen.skeletonRows;
                index++
              )
                Padding(
                  key: PlaylistDetailScreen.skeletonRowKey(index),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      const SquareArt(size: PlaylistDetailScreen.rowArtSize),
                      const SizedBox(width: FlushRow.gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Bar(width: 170, height: 14, color: tokens.hairline),
                            const SizedBox(height: 8),
                            _Bar(width: 100, height: 11, color: tokens.hairline),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.height, required this.color});

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

class _Failure extends StatelessWidget {
  const _Failure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't load this playlist.", style: tokens.body),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TapeButton(
              key: PlaylistDetailScreen.retryKey,
              label: 'Try again',
              onPressed: onRetry,
            ),
          ),
        ],
      ),
    );
  }
}
