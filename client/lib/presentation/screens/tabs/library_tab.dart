/// The Library tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` →
/// Library; board frame L1 in `docs/mockups/2026-09-17-mobile-shell-r3.html`;
/// plan `docs/superpowers/plans/2026-09-17-native-design-implementation.md`
/// task 8.1).
///
/// Two flush lists under bold section words: the sources the listener has
/// connected or imported, each with a status word, and the playlists they
/// own. The glass cluster at the title carries Sync library and More; More
/// holds the full "Your music" screen, so nothing the September 4 approval
/// shipped is out of reach.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the app root:
/// pushes go to the nearest [Navigator] and it draws no app bar of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/listening/listening_models.dart';
import '../../format/source_labels.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/playlist_providers.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/empty_state.dart';
import '../../widgets/foundation/flush_row.dart';
import '../../widgets/foundation/glass_cluster.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../../widgets/foundation/section_word.dart';
import '../../widgets/foundation/service_marks.dart';
import '../../widgets/foundation/tape_button.dart';
import '../../widgets/library_sync_sheet.dart';
import '../import_sheet.dart';
import '../music_sources_screen.dart';
import '../playlist_browser_screen.dart';
import '../spotify_request_screen.dart';
import '../../widgets/foundation/mixtape_sheet.dart';

/// The Library tab.
class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key});

  /// A row of breathing room under the last row, on top of the dock's own
  /// height: the shell hands that down as [MediaQuery.padding], which
  /// [LargeTitleScaffold] already emits at the end of the slivers.
  static const double defaultBottomInset = 16;

  static const Key syncButtonKey = Key('library-sync');

  /// The Apple Music note on the Sync button: a touch smaller than the
  /// cluster's 20 pt glyphs, which the drawn mark out-weighs at the same side.
  static const double syncMarkSize = 18;
  static const Key moreButtonKey = Key('library-more');

  /// The More menu's entry to the full Your music screen.
  static const Key yourMusicKey = Key('library-your-music');

  static const Key addSpotifyKey = Key('library-add-spotify');

  /// The no-sources empty state's action.
  static const Key emptySetupKey = Key('library-empty-setup');
  static const Key emptyKey = Key('library-sources-empty');

  /// The sources list failed to load.
  static const Key sourcesRetryKey = Key('library-sources-retry');

  /// The skeleton shown while the sources are in flight.
  static const Key sourcesSkeletonKey = Key('library-sources-skeleton');

  /// A source's own row, and the actions its sheet offers.
  static Key sourceRowKey(String source) => Key('library-source-$source');
  static Key sourceImportAgainKey(String source) =>
      Key('library-source-import-again-$source');
  static Key sourceRemoveKey(String source) =>
      Key('library-source-remove-$source');

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

  void _openMore() {
    showMixtapeSheet<void>(
      context,
      builder: (sheetContext) => _LibrarySheet(
        children: [
          FlushRow(
            key: LibraryTab.yourMusicKey,
            leading: const SizedBox.square(
              dimension: kSourceMarkSize,
              child: Center(child: Icon(Icons.library_music_outlined)),
            ),
            leadingSize: kSourceMarkSize,
            title: 'Your music',
            subtitle: 'Sources, imports and playlists',
            onTap: () {
              Navigator.of(sheetContext).pop();
              _push(const MusicSourcesScreen());
            },
          ),
        ],
      ),
    );
  }

  /// A source row's detail: the Apple library opens Your music, an imported
  /// source offers what can be done to it.
  void _openSource(MusicSource source) {
    final removable =
        source.source == 'spotify_export' || source.source == 'apple_export';
    if (!removable) {
      _push(const MusicSourcesScreen());
      return;
    }
    showMixtapeSheet<void>(
      context,
      builder: (sheetContext) => _LibrarySheet(
        children: [
          if (source.source == 'spotify_export')
            FlushRow(
              key: LibraryTab.sourceImportAgainKey(source.source),
              leading: const SizedBox.square(
                dimension: kSourceMarkSize,
                child: Center(child: Icon(Icons.file_upload_outlined)),
              ),
              leadingSize: kSourceMarkSize,
              title: 'Import again',
              trailing: const SizedBox.shrink(),
              onTap: () {
                Navigator.of(sheetContext).pop();
                openImportFlow(context, ref);
              },
            ),
          FlushRow(
            key: LibraryTab.sourceRemoveKey(source.source),
            leading: const SizedBox.square(
              dimension: kSourceMarkSize,
              child: Center(child: Icon(Icons.delete_outline)),
            ),
            leadingSize: kSourceMarkSize,
            title: 'Remove',
            trailing: const SizedBox.shrink(),
            onTap: () {
              Navigator.of(sheetContext).pop();
              removeSourceFlow(context, ref, source);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = ref.watch(onboardingProvider);
    final state = onboarding.value;
    final hasSources = state != null && state.sources.isNotEmpty;
    final noSources = state != null && state.sources.isEmpty;
    _playlistsShown = hasSources;

    return GradientBackground(
      // A transparent Scaffold with no app bar: the large title is the chrome,
      // and the Scaffold hosts this tab's sheets and SnackBars.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'Library',
          controller: _controller,
          trailing: GlassCluster(
            children: [
              GlassButton(
                key: LibraryTab.syncButtonKey,
                label: 'Sync library',
                onPressed: () => LibrarySyncSheet.show(context),
                // It is Apple Music's sync, so it wears Apple Music's mark
                // rather than the generic arrows (smoke round four, note 3).
                child: AppleMusicMark(
                  size: LibraryTab.syncMarkSize,
                  color: context.tokens.text,
                ),
              ),
              GlassButton(
                key: LibraryTab.moreButtonKey,
                icon: Icons.more_horiz,
                label: 'More',
                onPressed: _openMore,
              ),
            ],
          ),
          slivers: [
            // Nothing to list: the shared placement puts the block at the
            // same height Mixes puts its own (smoke round three, note 7).
            if (noSources)
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
    final tokens = context.tokens;

    if (state == null) {
      // Riverpod retries a failed provider, which parks it back in loading
      // with the error still attached: failure is "no value and an error".
      if (onboarding.hasError) {
        return Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Column(
            children: [
              Text(
                "couldn't load your sources",
                textAlign: TextAlign.center,
                style: tokens.body,
              ),
              const SizedBox(height: 16),
              TapeButton(
                key: LibraryTab.sourcesRetryKey,
                label: 'Try again',
                onPressed: () =>
                    ref.read(onboardingProvider.notifier).refresh(),
              ),
            ],
          ),
        );
      }
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
          onPressed: () => _push(const SpotifyRequestScreen()),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Sources'),
        FlushList(
          children: [
            for (final source in state.sources)
              FlushRow(
                key: LibraryTab.sourceRowKey(source.source),
                leading: SourceMark(source: source.source),
                leadingSize: kSourceMarkSize,
                title: sourceName(source),
                subtitleWidget: SourceSubtitle(source: source, state: state),
                onTap: () => _openSource(source),
              ),
            FlushRow(
              key: LibraryTab.addSpotifyKey,
              leading: const SizedBox.square(
                dimension: kSourceMarkSize,
                child: Center(child: Icon(Icons.add, size: 22)),
              ),
              leadingSize: kSourceMarkSize,
              title: 'Add Spotify music',
              subtitle: 'Bring a Spotify export across',
              // The row names the service, so it opens on that pane.
              onTap: () => _push(
                const SpotifyRequestScreen(
                  initialSegment: SpotifyRequestScreen.spotifySegment,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The tab's own action sheets. The shared sheet supplies the material, the
/// handle and the bottom inset; this is only the rows.
class _LibrarySheet extends StatelessWidget {
  const _LibrarySheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: FlushList(children: children),
  );
}
