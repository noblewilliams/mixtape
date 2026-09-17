/// The Library tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` →
/// Library; plan `docs/superpowers/plans/2026-09-17-native-design-
/// implementation.md` task 2.4).
///
/// A skeleton on purpose: it carries the board's large title and glass Sync
/// cluster, and reaches the shipped screens through flush rows so the shell is
/// navigable end to end. Phase 8 restyles the hosted screens and brings the
/// Playlists section in.
///
/// The music entries Home's overflow menu offered land here: Your music, Add
/// Spotify music and Sync library. Music setup stays on Home's waiting card,
/// which owns the interview and the ZIP import.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the app root:
/// pushes go to the nearest [Navigator] and it draws no app bar of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/library_sync_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/flush_row.dart';
import '../../widgets/foundation/glass_cluster.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../../widgets/foundation/large_title_scaffold.dart';
import '../../widgets/foundation/section_word.dart';
import '../music_sources_screen.dart';
import '../spotify_request_screen.dart';

/// The Library tab.
class LibraryTab extends ConsumerWidget {
  const LibraryTab({super.key});

  /// A row of breathing room under the last row, on top of the dock's own
  /// height: the shell hands that down as [MediaQuery.padding], which
  /// [LargeTitleScaffold] already emits at the end of the slivers.
  static const double defaultBottomInset = 16;

  static const Key syncButtonKey = Key('library-sync');
  static const Key yourMusicKey = Key('library-your-music');
  static const Key addSpotifyKey = Key('library-add-spotify');

  /// The sync sheet's start action.
  static const Key syncStartKey = Key('library-sync-start');
  static const Key syncAgainKey = Key('library-sync-again');
  static const Key syncRetryKey = Key('library-sync-retry');

  /// The leading column's width for these icon rows, and so the hairline's
  /// inset.
  static const double rowIconColumn = 28;

  void _openSources(BuildContext context, WidgetRef ref) {
    ref.read(onboardingProvider.notifier).refresh();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MusicSourcesScreen()))
        // An import or a removal over there changes what the sources say.
        .then((_) => ref.read(onboardingProvider.notifier).refresh());
  }

  void _openSpotifyRequest(BuildContext context, WidgetRef ref) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SpotifyRequestScreen()))
        .then((_) => ref.read(onboardingProvider.notifier).refresh());
  }

  void _openSync(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LibrarySyncSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;

    return GradientBackground(
      // A transparent Scaffold with no app bar: the large title is the chrome,
      // and the Scaffold hosts this tab's sheets and SnackBars.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'Library',
          trailing: GlassCluster(
            children: [
              GlassButton(
                key: syncButtonKey,
                icon: Icons.sync,
                label: 'Sync library',
                onPressed: () => _openSync(context),
              ),
            ],
          ),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(bottom: defaultBottomInset),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionWord('Sources'),
                    FlushList(
                      children: [
                        FlushRow(
                          key: yourMusicKey,
                          leading: _RowIcon(
                            Icons.library_music_outlined,
                            color: tokens.plum,
                          ),
                          leadingSize: rowIconColumn,
                          title: 'Your music',
                          subtitle: 'Sources, imports and playlists',
                          onTap: () => _openSources(context, ref),
                        ),
                        FlushRow(
                          key: addSpotifyKey,
                          leading: _RowIcon(
                            Icons.playlist_add,
                            color: tokens.plum,
                          ),
                          leadingSize: rowIconColumn,
                          title: 'Add Spotify music',
                          subtitle: 'Bring a Spotify export across',
                          onTap: () => _openSpotifyRequest(context, ref),
                        ),
                        // No "Music setup" row: the real setup sheet (the
                        // interview and Choose a ZIP) stays on Home's waiting
                        // card, which Home keeps for Spotify listeners until
                        // both imports land.
                        // TODO(Phase 8): interview entry under You
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row's leading glyph, in the leading column's width so the hairline lines
/// up with the text.
class _RowIcon extends StatelessWidget {
  const _RowIcon(this.icon, {required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: LibraryTab.rowIconColumn,
    child: Center(child: Icon(icon, size: 22, color: color)),
  );
}

/// The P1 library-sync UI, reproduced here for the Sync cluster.
///
/// Gap (task 2.4): Home's own `_LibrarySyncSheet` is private to
/// `home_screen.dart`, which another agent owns this phase, so reaching it
/// would have meant editing that file. The states, copy and actions match it.
// TODO(Phase 8): extract one shared library-sync sheet and delete Home's copy.
class _LibrarySyncSheet extends ConsumerWidget {
  const _LibrarySyncSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (sync) {
          SyncIdle() => FilledButton(
            key: LibraryTab.syncStartKey,
            onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
            child: const Text('Sync my library'),
          ),
          SyncRunning(:final progress) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress == 0 ? null : progress),
              const SizedBox(height: 16),
              Text(
                progress == 0
                    ? 'Syncing…'
                    : 'Syncing… ${(progress * 100).round()}%',
              ),
            ],
          ),
          SyncDone(:final summary) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Synced ${summary.songs} ${summary.songs == 1 ? 'song' : 'songs'} and '
                '${summary.playlists} ${summary.playlists == 1 ? 'playlist' : 'playlists'}. '
                'The DJ is listening.',
                textAlign: TextAlign.center,
              ),
              if (summary.unresolvedEntries > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${summary.unresolvedEntries} playlist '
                  '${summary.unresolvedEntries == 1 ? 'entry is' : 'entries are'} '
                  'still unmatched.',
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                key: LibraryTab.syncAgainKey,
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Sync again'),
              ),
            ],
          ),
          SyncFailed(:final message) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                key: LibraryTab.syncRetryKey,
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Try again'),
              ),
            ],
          ),
        },
      ),
    );
  }
}
