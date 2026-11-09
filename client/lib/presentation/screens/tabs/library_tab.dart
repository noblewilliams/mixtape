/// The Library tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` →
/// Library; board frame L1 in `docs/mockups/2026-09-17-mobile-shell-r3.html`;
/// plan `docs/superpowers/plans/2026-09-17-native-design-implementation.md`
/// task 8.1).
///
/// The sources strip and the playlists the listener owns. The strip is one
/// row of two halves, Apple Music and Spotify, each a mark, the service name
/// and where it stands; each opens Add your music on its own segment
/// (approval `docs/mockups/approved/2026-11-03-library-sources.md`, which
/// supersedes the More menu and the chip-row sources).
///
/// The title carries one labelled button, "Add your music", into Your music,
/// where each source lives (founder, 2026-11-09). Sync is Apple Music's alone,
/// so it sits with Apple Music there and on Add your music, never here.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the app root:
/// pushes go to the nearest [Navigator] and it draws no app bar of its own.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/listening/listening_models.dart';
import '../../format/source_labels.dart';
import '../../providers/library_sync_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/playlist_providers.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/empty_state.dart';
import '../../widgets/foundation/glass_cluster.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../../widgets/foundation/section_word.dart';
import '../../widgets/foundation/service_marks.dart';
import '../../widgets/foundation/status_word.dart';
import '../../widgets/foundation/tape_button.dart';
import '../../widgets/library_sync_dialog.dart';
import '../first_run/first_run_flow.dart';
import '../music_sources_screen.dart';
import '../playlist_browser_screen.dart';
import '../spotify_request_screen.dart';

/// The Library tab.
class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key});

  /// A row of breathing room under the last row, on top of the dock's own
  /// height: the shell hands that down as [MediaQuery.padding], which
  /// [LargeTitleScaffold] already emits at the end of the slivers.
  static const double defaultBottomInset = 16;

  /// The title's one button, "Add your music", which opens Your music.
  static const Key addMusicKey = Key('library-add-music');

  /// The no-sources empty state's action.
  static const Key emptySetupKey = Key('library-empty-setup');
  static const Key emptyKey = Key('library-sources-empty');

  static const Key sourcesRetryKey = Key('library-sources-retry');

  /// The skeleton shown while the sources are in flight.
  static const Key sourcesSkeletonKey = Key('library-sources-skeleton');

  /// The strip's two halves.
  static const Key appleSourceKey = Key('library-source-apple');
  static const Key spotifySourceKey = Key('library-source-spotify');

  /// At this text scale the halves stack into full-width rows.
  static const double stackStripScale = 1.3;

  /// The empty state's words.
  static const String emptyTitle = 'No music yet';
  static const String emptyBody =
      'Connect Apple Music or add your Spotify export.';

  /// The next page is fetched this far from the bottom.
  static const double loadMoreMargin = 400;

  /// The retry after a page failed; scrolling alone will not try again.
  static const Key loadMoreKey = kPlaylistsLoadMoreRetryKey;

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// The playlists page as the list nears its end: the board has no "Load
  /// more" button on this screen, and the collection provider already guards
  /// re-entry and a missing cursor.
  ///
  /// Two guards of its own: nothing is asked for unless the Playlists section
  /// is actually on screen — an overscroll over the empty or failed sources
  /// state would otherwise spin the autoDispose provider up for a request
  /// nobody can see — and a page that failed waits for the listener's
  /// [LibraryTab.loadMoreKey] rather than retrying itself on every tick.
  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels <
        position.maxScrollExtent - LibraryTab.loadMoreMargin) {
      return;
    }
    if (!_playlistsShown) return;
    if (ref.read(playlistCollectionProvider).value?.loadMoreFailed ?? false) {
      return;
    }
    ref.read(playlistCollectionProvider.notifier).loadMore();
  }

  /// Whether this build put the Playlists section in the tree.
  bool _playlistsShown = false;

  Future<void> _push(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    // An import or a removal over there changes what the sources say.
    if (mounted) await ref.read(onboardingProvider.notifier).refresh();
  }

  /// Path B's three steps from the first-run flow, popping back here once
  /// the music is in (first-run spec, Clients).
  Future<void> _addMusic() async {
    await openAddMusic(context);
    if (mounted) await ref.read(onboardingProvider.notifier).refresh();
  }

  /// Add your music on the segment a half names.
  void _openService(int segment) =>
      _push(SpotifyRequestScreen(initialSegment: segment));

  @override
  Widget build(BuildContext context) {
    final onboarding = ref.watch(onboardingProvider);
    final state = onboarding.value;
    final hasSources = state != null && state.sources.isNotEmpty;
    final noSources = state != null && state.sources.isEmpty;
    // Riverpod retries a failed provider, which parks it back in loading
    // with the error still attached: failure is "no value and an error".
    final failed = state == null && onboarding.hasError;
    _playlistsShown = hasSources;

    return GradientBackground(
      // A transparent Scaffold with no app bar: the large title is the chrome,
      // and the Scaffold hosts this tab's sheets and SnackBars.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'Library',
          accessoriesBelowTitle: true,
          controller: _controller,
          // Keep the full title above the action, including on narrow phones.
          // With no sources the empty state's own "Add your music" is the way
          // in, so the title does not offer a second one that goes elsewhere.
          trailing: noSources
              ? null
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: GlassCluster(
                    children: [
                      GlassLabelButton(
                        key: LibraryTab.addMusicKey,
                        icon: CupertinoIcons.add,
                        label: 'Add your music',
                        onPressed: () => _push(const MusicSourcesScreen()),
                      ),
                    ],
                  ),
                ),
          slivers: [
            // Nothing to list: the shared placement puts the block at the
            // same height Mixes puts its own (smoke round three, note 7).
            if (failed)
              EmptyStateSliver(
                child: LoadErrorState(
                  title: kSourcesLoadFailedTitle,
                  retryKey: LibraryTab.sourcesRetryKey,
                  onRetry: () =>
                      ref.read(onboardingProvider.notifier).refresh(),
                ),
              )
            else if (noSources)
              EmptyStateSliver(child: _sources(onboarding, state))
            else ...[
              SliverToBoxAdapter(child: _sources(onboarding, state)),
              if (hasSources) ...[
                const SliverToBoxAdapter(child: SectionWord('Playlists')),
                playlistCollectionSliver(
                  ref,
                  ref.watch(playlistCollectionProvider),
                  // The list pages on scroll; no button stands at its end.
                  loadMoreButton: false,
                ),
              ],
              const SliverToBoxAdapter(
                child: SizedBox(height: LibraryTab.defaultBottomInset),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sources(
    AsyncValue<OnboardingState> onboarding,
    OnboardingState? state,
  ) {
    if (state == null) {
      // A failure is the whole tab's state, drawn by build.
      return const Padding(
        key: LibraryTab.sourcesSkeletonKey,
        padding: EdgeInsets.only(top: 16),
        child: PlaylistSkeletonRows(rows: 3),
      );
    }

    if (state.sources.isEmpty) {
      return EmptyState(
        key: LibraryTab.emptyKey,
        title: LibraryTab.emptyTitle,
        body: LibraryTab.emptyBody,
        action: TapeButton(
          key: LibraryTab.emptySetupKey,
          label: 'Add your music',
          onPressed: _addMusic,
        ),
      );
    }

    return _SourcesStrip(
      state: state,
      sync: ref.watch(librarySyncProvider),
      onApple: () => _openService(SpotifyRequestScreen.appleSegment),
      onSpotify: () => _openService(SpotifyRequestScreen.spotifySegment),
    );
  }
}

/// The sources strip: Apple Music and Spotify side by side, or stacked at
/// large text, flush on the background with a hairline under it.
class _SourcesStrip extends StatelessWidget {
  const _SourcesStrip({
    required this.state,
    required this.sync,
    required this.onApple,
    required this.onSpotify,
  });

  final OnboardingState state;
  final SyncState sync;
  final VoidCallback onApple;
  final VoidCallback onSpotify;

  /// Apple: the library sync's own line; an account that only imported the
  /// Apple history says so; nothing at all is an invitation.
  ({StatusKind kind, String label})? get _appleStatus {
    MusicSource? export;
    for (final source in state.sources) {
      if (source.source == 'apple_export') export = source;
    }
    final live = appleLiveSource(state);
    if (live == null && sync is SyncIdle) {
      if (export?.lastImportedAt != null) {
        return (kind: StatusKind.ok, label: 'History added');
      }
      return null;
    }
    return appleSyncStatus(sync, state);
  }

  ({StatusKind kind, String label})? get _spotifyStatus {
    final source = spotifySource(state);
    return source == null ? null : sourceStatusFor(source, state);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) >= LibraryTab.stackStripScale;

    final apple = _SourceHalf(
      key: LibraryTab.appleSourceKey,
      mark: AppleMusicMark(size: _SourceHalf.markSize, color: tokens.text),
      emptyMark: AppleMusicMark(
        size: _SourceHalf.markSize,
        color: tokens.muted,
      ),
      name: 'Apple Music',
      status: _appleStatus,
      stacked: stacked,
      onTap: onApple,
    );
    final spotify = _SourceHalf(
      key: LibraryTab.spotifySourceKey,
      mark: SpotifyMark(size: _SourceHalf.markSize, color: tokens.text),
      emptyMark: SpotifyMark(size: _SourceHalf.markSize, color: tokens.muted),
      name: 'Spotify',
      status: _spotifyStatus,
      stacked: stacked,
      onTap: onSpotify,
    );
    final hairline = Container(height: 1, color: tokens.hairline);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stacked) ...[
            apple,
            hairline,
            spotify,
          ] else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: apple),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Container(width: 1, color: tokens.hairline),
                  ),
                  Expanded(child: spotify),
                ],
              ),
            ),
          hairline,
        ],
      ),
    );
  }
}

/// One service in the strip: its mark, its name and its status line, or
/// "Add music" when nothing of it is in yet. The whole half is the button.
class _SourceHalf extends StatelessWidget {
  const _SourceHalf({
    super.key,
    required this.mark,
    required this.emptyMark,
    required this.name,
    required this.status,
    required this.stacked,
    required this.onTap,
  });

  final Widget mark;
  final Widget emptyMark;
  final String name;
  final ({StatusKind kind, String label})? status;
  final bool stacked;
  final VoidCallback onTap;

  static const double markSize = 28;
  static const String addLabel = 'Add music';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final status = this.status;
    final line = status == null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.add, size: 13, color: tokens.plum),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  addLabel,
                  maxLines: stacked ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tokens.plum,
                  ),
                ),
              ),
            ],
          )
        : StatusWord(label: status.label, kind: status.kind);

    return Semantics(
      button: true,
      label: '$name, ${status?.label ?? 'not added. $addLabel'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 62),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                status == null ? emptyMark : mark,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        maxLines: stacked ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.rowTitle.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      line,
                    ],
                  ),
                ),
                if (stacked)
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 18,
                    color: tokens.muted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
