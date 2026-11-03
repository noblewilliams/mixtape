/// The library-sync alert, shared by the Library tab, Your music and Add your
/// music (approval `docs/mockups/approved/2026-11-03-library-sources.md`).
///
/// It replaces the September sync sheet: syncing needs a confirmation, so it
/// is a centred alert, and it speaks as a re-sync once the account has one
/// ("Sync Apple Music again?" with the last date). The run's states play out
/// inside it; Hide leaves the run going, and the Library strip carries it.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show LinearProgressIndicator;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/library/library_sync_service.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/service_marks.dart';
import 'foundation/status_word.dart';

/// iOS' own deep link to this app's Settings pane.
final Uri appSettingsUrl = Uri(scheme: 'app-settings');

/// The account's live Apple Music library row, if it has one.
MusicSource? appleLiveSource(OnboardingState? state) {
  for (final source in state?.sources ?? const <MusicSource>[]) {
    if (source.source == 'apple_live') return source;
  }
  return null;
}

/// When the live library last landed, for the re-sync copy.
DateTime? appleLastSynced(OnboardingState? state) {
  final live = appleLiveSource(state);
  return live == null ? null : live.lastImportedAt ?? live.connectedAt;
}

/// The status line every Apple library row shows: the run this session
/// started, or the date the account last had one.
({StatusKind kind, String label}) appleSyncStatus(
  SyncState sync,
  OnboardingState? state,
) {
  final last = appleLastSynced(state);
  return switch (sync) {
    SyncRunning(:final progress) => (
      kind: StatusKind.muted,
      label: progress == 0
          ? 'Syncing…'
          : 'Syncing… ${(progress * 100).round()}%',
    ),
    SyncFailed() => (kind: StatusKind.warn, label: "Sync didn't finish"),
    SyncDone() => (kind: StatusKind.ok, label: 'Synced just now'),
    SyncIdle() when last != null => (
      kind: StatusKind.ok,
      label: 'Synced ${shortDate(last)}',
    ),
    SyncIdle() => (kind: StatusKind.muted, label: 'Not synced yet'),
  };
}

/// Opens the sync alert from anywhere with a [WidgetRef], reading the last
/// sync date off the onboarding state.
Future<void> showLibrarySync(BuildContext context, WidgetRef ref) =>
    LibrarySyncDialog.show(
      context,
      lastSynced: appleLastSynced(ref.read(onboardingProvider).value),
    );

/// The sync alert: confirm, running, done, failed.
class LibrarySyncDialog extends ConsumerStatefulWidget {
  const LibrarySyncDialog({super.key, this.lastSynced});

  /// When the account last synced; null for a first sync.
  final DateTime? lastSynced;

  static const Key startKey = Key('library-sync-start');
  static const Key cancelKey = Key('library-sync-cancel');
  static const Key progressKey = Key('library-sync-progress');
  static const Key hideKey = Key('library-sync-hide');
  static const Key doneKey = Key('library-sync-done');
  static const Key retryKey = Key('library-sync-retry');
  static const Key settingsKey = Key('library-sync-settings');

  static const String resyncTitle = 'Sync Apple Music again?';
  static const String firstTitle = 'Sync Apple Music?';
  static const String runningTitle = 'Syncing Apple Music';
  static const String doneTitle = 'Apple Music is up to date';
  static const String failedTitle = "Sync didn't finish";
  static const String deniedTitle = "Mixtape can't see your library";

  static Future<void> show(BuildContext context, {DateTime? lastSynced}) =>
      showCupertinoDialog<void>(
        context: context,
        builder: (_) => LibrarySyncDialog(lastSynced: lastSynced),
      );

  @override
  ConsumerState<LibrarySyncDialog> createState() => _LibrarySyncDialogState();
}

class _LibrarySyncDialogState extends ConsumerState<LibrarySyncDialog> {
  /// Whether this alert is following a run. Opened over an earlier run's
  /// result it starts at the confirmation, so a second sync is always one
  /// tap away; opened over a run in flight it shows that run.
  late bool _following = ref.read(librarySyncProvider) is SyncRunning;

  void _start() {
    setState(() => _following = true);
    unawaited(ref.read(librarySyncProvider.notifier).sync());
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(librarySyncProvider);
    final tokens = context.tokens;

    final (String title, Widget body, List<Widget> actions) = !_following
        ? _confirm()
        : switch (sync) {
            SyncIdle() => _confirm(),
            SyncRunning(:final progress) => (
              LibrarySyncDialog.runningTitle,
              Column(
                key: LibrarySyncDialog.progressKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    progress == 0
                        ? 'Starting. You can keep using Mixtape while this runs.'
                        : '${(progress * 100).round()}% · you can keep using '
                              'Mixtape while this runs.',
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress == 0 ? null : progress,
                      minHeight: 4,
                      backgroundColor: tokens.hairline,
                      valueColor: AlwaysStoppedAnimation<Color>(tokens.plum),
                    ),
                  ),
                ],
              ),
              [
                CupertinoDialogAction(
                  key: LibrarySyncDialog.hideKey,
                  onPressed: _close,
                  child: const Text('Hide'),
                ),
              ],
            ),
            SyncDone(:final summary) => (
              LibrarySyncDialog.doneTitle,
              Text(_doneCopy(summary)),
              [
                CupertinoDialogAction(
                  key: LibrarySyncDialog.doneKey,
                  isDefaultAction: true,
                  onPressed: _close,
                  child: const Text('Done'),
                ),
              ],
            ),
            SyncFailed(accessDenied: true) => (
              LibrarySyncDialog.deniedTitle,
              const Text(
                'Allow Media & Apple Music access for Mixtape in Settings, '
                'then sync again.',
              ),
              [
                CupertinoDialogAction(
                  key: LibrarySyncDialog.cancelKey,
                  onPressed: _close,
                  child: const Text('Not now'),
                ),
                CupertinoDialogAction(
                  key: LibrarySyncDialog.settingsKey,
                  isDefaultAction: true,
                  onPressed: () {
                    _close();
                    unawaited(ref.read(linkOpenerProvider)(appSettingsUrl));
                  },
                  child: const Text('Open Settings'),
                ),
              ],
            ),
            SyncFailed(:final message) => (
              LibrarySyncDialog.failedTitle,
              Text(message),
              [
                CupertinoDialogAction(
                  key: LibrarySyncDialog.cancelKey,
                  onPressed: _close,
                  child: const Text('Cancel'),
                ),
                CupertinoDialogAction(
                  key: LibrarySyncDialog.retryKey,
                  isDefaultAction: true,
                  onPressed: _start,
                  child: const Text('Try again'),
                ),
              ],
            ),
          };

    return CupertinoAlertDialog(
      title: Column(
        children: [
          AppleMusicMark(size: 30, color: tokens.text),
          const SizedBox(height: 8),
          Text(title),
        ],
      ),
      content: body,
      actions: actions,
    );
  }

  String _doneCopy(LibrarySyncSummary summary) {
    final synced =
        '${plural(summary.songs, 'song')} and '
        '${plural(summary.playlists, 'playlist')} synced.';
    final unmatched = summary.unresolvedEntries;
    if (unmatched == 0) return synced;
    final entries = plural(unmatched, 'playlist entry', 'playlist entries');
    return '$synced $entries ${unmatched == 1 ? 'is' : 'are'} still unmatched.';
  }

  (String, Widget, List<Widget>) _confirm() {
    final last = widget.lastSynced;
    return (
      last == null
          ? LibrarySyncDialog.firstTitle
          : LibrarySyncDialog.resyncTitle,
      Text(
        last == null
            ? 'Mixtape will read your Apple Music songs and playlists so the '
                  'DJ can build from them. Apple asks for access first.'
            : 'Last synced ${shortDate(last)}. Mixtape will bring in the songs '
                  "and playlists you've added or changed since then.",
      ),
      [
        CupertinoDialogAction(
          key: LibrarySyncDialog.cancelKey,
          onPressed: _close,
          child: const Text('Not now'),
        ),
        CupertinoDialogAction(
          key: LibrarySyncDialog.startKey,
          isDefaultAction: true,
          onPressed: _start,
          child: const Text('Sync'),
        ),
      ],
    );
  }
}
