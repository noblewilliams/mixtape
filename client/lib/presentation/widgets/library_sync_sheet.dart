/// The library-sync sheet, shared by the Library tab and Your music
/// (plan `docs/superpowers/plans/2026-09-17-native-design-implementation.md`
/// task 8.1; board `docs/mockups/2026-09-17-mobile-shell-r3.html` → L1's Sync
/// cluster).
///
/// One sheet, not three: the P1 copy from Home's card and the tab's own copy
/// of it are replaced by this, on the approved frosted material with a drag
/// handle. The states and strings are unchanged; the keys are the
/// `library-sync-` ones the tab published.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_sync_provider.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/frosted_surface.dart';
import 'foundation/tape_button.dart';
import 'foundation/text_action.dart';

/// The sync sheet: idle, running, done, failed.
class LibrarySyncSheet extends ConsumerWidget {
  const LibrarySyncSheet({super.key});

  /// The drag handle above the sheet's content.
  static const Key handleKey = Key('library-sync-handle');

  /// Idle: start a run.
  static const Key startKey = Key('library-sync-start');

  /// Running: the progress line and its bar.
  static const Key progressKey = Key('library-sync-progress');

  /// Done: run it again.
  static const Key againKey = Key('library-sync-again');

  /// Failed: try again.
  static const Key retryKey = Key('library-sync-retry');

  /// Opens the sheet over [context]'s nearest navigator.
  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // The frosted surface is the sheet's own material; Material's would sit
    // opaque behind the blur.
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (_) => const LibrarySyncSheet(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    final tokens = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: FrostedSurface(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  key: handleKey,
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: tokens.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 18),
                _body(context, ref, sync),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, SyncState sync) {
    final tokens = context.tokens;
    void run() => ref.read(librarySyncProvider.notifier).sync();

    switch (sync) {
      case SyncIdle():
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Bring your Apple Music songs and playlists across so the DJ '
              'can use them.',
              textAlign: TextAlign.center,
              style: tokens.secondary,
            ),
            const SizedBox(height: 18),
            TapeButton(
              key: startKey,
              label: 'Sync library',
              onPressed: run,
            ),
          ],
        );
      case SyncRunning(:final progress):
        return Column(
          key: progressKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress == 0 ? null : progress,
                minHeight: 4,
                backgroundColor: tokens.hairline,
                valueColor: AlwaysStoppedAnimation<Color>(tokens.plum),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              progress == 0
                  ? 'Syncing…'
                  : 'Syncing… ${(progress * 100).round()}%',
              textAlign: TextAlign.center,
              style: tokens.body,
            ),
          ],
        );
      case SyncDone(:final summary):
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Synced ${summary.songs} ${summary.songs == 1 ? 'song' : 'songs'} and '
              '${summary.playlists} ${summary.playlists == 1 ? 'playlist' : 'playlists'}. '
              'The DJ is listening.',
              textAlign: TextAlign.center,
              style: tokens.body,
            ),
            if (summary.unresolvedEntries > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${summary.unresolvedEntries} playlist '
                '${summary.unresolvedEntries == 1 ? 'entry is' : 'entries are'} '
                'still unmatched.',
                textAlign: TextAlign.center,
                style: tokens.secondary,
              ),
            ],
            const SizedBox(height: 14),
            TextAction(key: againKey, label: 'Sync again', onPressed: run),
          ],
        );
      case SyncFailed(:final message):
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center, style: tokens.body),
            const SizedBox(height: 18),
            TapeButton(key: retryKey, label: 'Try again', onPressed: run),
          ],
        );
    }
  }
}
