import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/files/archive_picker.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../import/listening_import_service.dart';
import '../../import/snapshot.dart';
import '../format/import_format.dart';
import '../providers/listening_import_provider.dart';
import '../providers/opened_archive_provider.dart';

/// How many import sheets are on screen. Home and the sources screen both
/// open one, and a file handed to the app can arrive over either, so the
/// fact lives here rather than in one screen's private flag: a hand-over
/// must never stack a second sheet over the one already up. The sheets
/// themselves keep the count, so a screen torn down with one up leaves
/// nothing behind, and the swap below (the old sheet is still on its way out
/// when the new one is pushed) never shows a gap.
int _showing = 0;

bool get importSheetShowing => _showing > 0;

/// Opens the import flow as a bottom sheet over the current route, the way
/// Home's library sync sheet is shown. The sheet reflects
/// [listeningImportProvider], so a run keeps going if the sheet is dismissed
/// and reopening it shows where the run got to. A sheet opened over an
/// upload in flight is not [dismissible]: it stays until the upload lands
/// or the listener cancels it.
///
/// A modal sheet's dismissibility is fixed when it opens, so the locked one
/// pops itself the moment the run lands and comes straight back dismissible
/// — nobody is left trapped in front of a result.
Future<void> showImportSheet(BuildContext context, {bool dismissible = true}) async {
  var landed = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    builder: (_) =>
        dismissible ? const ImportSheet() : _LockedSheet(onLanded: () => landed = true),
  );
  // The locked sheet asked to come back: the route it pops is still on its
  // way out, so the count never drops to nothing in between.
  if (!landed || !context.mounted) return;
  await showImportSheet(context);
}

/// The sheet while it may not be dismissed. It shows the same flow; when the
/// run reaches a state nothing follows from it pops itself, and
/// [showImportSheet] shows it again as a sheet the listener can dismiss.
class _LockedSheet extends ConsumerStatefulWidget {
  const _LockedSheet({required this.onLanded});

  final VoidCallback onLanded;

  @override
  ConsumerState<_LockedSheet> createState() => _LockedSheetState();
}

class _LockedSheetState extends ConsumerState<_LockedSheet> {
  bool _popping = false;

  @override
  Widget build(BuildContext context) {
    // Watched rather than listened to: a run that had already landed by the
    // time this opened would never fire a change.
    if (!_popping && !ref.watch(listeningImportProvider).inProgress) {
      _popping = true;
      widget.onLanded();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    return const ImportSheet();
  }
}

/// Home's "Choose a ZIP" and the sources screen's "Import again": the sheet
/// opens and the picker comes up at once, so the listener is not asked
/// twice. A run in progress (a file being read, an inventory, an upload) is
/// shown where it got to instead; starting over would cancel it.
Future<void> openImportFlow(BuildContext context, WidgetRef ref) {
  final state = ref.read(listeningImportProvider);
  if (!state.inProgress) {
    final notifier = ref.read(listeningImportProvider.notifier);
    notifier.reset();
    notifier.pick();
  }
  return showImportSheet(context, dismissible: state is! ImportUploading);
}

/// The share-sheet path (C5): the listener already chose the file in Files
/// or Mail, so the flow starts on it and the picker never opens. A file the
/// app could not copy at all has no archive to read, only a name to fail by.
///
/// Returns false, having changed nothing, when a run is in flight — the same
/// re-entry rule as [openImportFlow]: starting over would cancel it. The
/// handed file then waits, and the result screen offers it.
bool startHandedArchive(WidgetRef ref, HandedArchive handedOver) {
  if (ref.read(listeningImportProvider).inProgress) return false;
  final notifier = ref.read(listeningImportProvider.notifier);
  notifier.reset();
  final archive = handedOver.archive;
  if (archive == null) {
    notifier.handOverFailed(handedOver.name);
  } else {
    notifier.inspect(archive, handedOver: true);
  }
  ref.read(openedArchiveProvider.notifier).consumed(handedOver);
  return true;
}

/// A file handed to the app while this run was still going (C5). Starting it
/// then would have thrown the run away, and starting it the moment the run
/// landed would have thrown the result away before anyone read it — so it is
/// offered here instead, on the screen that result is on.
class _WaitingFile extends ConsumerWidget {
  const _WaitingFile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(openedArchiveProvider);
    if (waiting == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          'Another file is waiting: ${waiting.name}',
          key: const Key('import-waiting-file'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('import-waiting-start'),
          onPressed: () => startHandedArchive(ref, waiting),
          child: const Text('Import it'),
        ),
      ],
    );
  }
}

/// The Spotify import flow: pick a ZIP → inventory → upload with progress →
/// done / partial / failed / cancelled. Every fact shown comes from the
/// inventory or the summary; never a track, artist, or playlist name.
class ImportSheet extends ConsumerStatefulWidget {
  const ImportSheet({super.key});

  @override
  ConsumerState<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<ImportSheet> {
  @override
  void initState() {
    super.initState();
    _showing++;
  }

  @override
  void dispose() {
    _showing--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(listeningImportProvider);
    final notifier = ref.read(listeningImportProvider.notifier);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: switch (state) {
          ImportIdle() => _Idle(onPick: notifier.pick),
          ImportFlowCancelled() => _Idle(onPick: notifier.pick, cancelled: true),
          ImportInspecting(:final archive) => _Inspecting(archive: archive, onCancel: notifier.cancel),
          ImportInventory() => _Inventory(state: state, notifier: notifier),
          ImportUploading(:final archive, :final progress) =>
            _Uploading(archive: archive, progress: progress, onCancel: notifier.cancel),
          ImportDone(:final result) => _Done(result: result, notifier: notifier),
          ImportPartial(:final result) => _Partial(result: result, notifier: notifier),
          ImportFailed() => _Failed(state: state, notifier: notifier),
        },
      ),
    );
  }
}

String packageName(ExportPackage? package) => switch (package) {
      ExportPackage.spotifyExtended => 'Extended streaming history',
      ExportPackage.spotifyAccount => 'Account data',
      null => 'Unknown package',
    };

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

class _Idle extends StatelessWidget {
  const _Idle({required this.onPick, this.cancelled = false});

  final VoidCallback onPick;
  final bool cancelled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          cancelled ? 'Import cancelled.' : 'Pick the ZIP Spotify sent you. Either package, in either order.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('import-pick'),
          onPressed: onPick,
          child: const Text('Choose a ZIP'),
        ),
      ],
    );
  }
}

class _Inspecting extends StatelessWidget {
  const _Inspecting({required this.archive, required this.onCancel});

  final PickedArchive archive;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('Reading ${archive.name}…', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextButton(
          key: const Key('import-cancel'),
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Inventory extends StatelessWidget {
  const _Inventory({required this.state, required this.notifier});

  final ImportInventory state;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = state.preview;
    final inventory = preview.inventory;
    final snapshot = preview.snapshot;
    final extended = preview.package == ExportPackage.spotifyExtended;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(state.archive.name, key: const Key('import-file-name'), style: theme.textTheme.titleMedium),
        Text(
          '${formatBytes(state.archive.bytes)} · ${packageName(inventory.package)}',
          key: const Key('import-file-meta'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        // Every figure comes from the parse the service ran at inspect: the
        // snapshot for the counts, its stats for the drops.
        _Fact(label: 'Tracks', value: formatCount(preview.tracks)),
        if (extended) ...[
          _Fact(label: 'Days with plays', value: formatCount(preview.daysWithPlays)),
          _Fact(label: 'Years covered', value: yearsRange(snapshot.ledgerFrom, snapshot.ledgerTo) ?? '—'),
        ] else ...[
          _Fact(label: 'Liked songs', value: formatCount(snapshot.library.length)),
          _Fact(label: 'Artists', value: formatCount(snapshot.artists.length)),
          _Fact(label: 'Playlists', value: formatCount(snapshot.playlists.length)),
        ],
        _Fact(
          label: 'Skipped rows',
          value: skippedRowsLabel(podcasts: preview.skippedPodcasts, localFiles: preview.skippedLocalFiles),
        ),
        if (extended) ...[
          const SizedBox(height: 4),
          Text('Local days in ${state.timeZone}', key: const Key('import-zone'), style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        Text('Files read', style: theme.textTheme.labelLarge),
        for (final file in inventory.read)
          _FileLine(
            key: Key('import-read-${_baseName(file.path)}'),
            name: _baseName(file.path),
            note: file.rows == null ? 'unreadable' : plural(file.rows!, 'row'),
          ),
        if (inventory.ignored.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Ignored · never read', style: theme.textTheme.labelLarge),
          for (final file in inventory.ignored)
            _FileLine(
              key: Key('import-ignored-${_baseName(file.path)}'),
              name: _baseName(file.path),
              note: 'ignored',
              struck: true,
            ),
        ],
        if (extended) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('import-private-sessions'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Include private sessions'),
            subtitle: Text(privateSessionsHint(preview.privatePlays), key: const Key('import-private-hint')),
            value: state.includePrivateSessions,
            onChanged: notifier.setIncludePrivateSessions,
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Only these plays leave this device. Your account details, payments, and IP addresses are never read.',
          key: const Key('import-privacy'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('import-upload'),
          onPressed: notifier.upload,
          child: const Text('Upload'),
        ),
        TextButton(
          key: const Key('import-pick-other'),
          onPressed: () {
            notifier.reset();
            notifier.pick();
          },
          child: const Text('Choose a different file'),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _FileLine extends StatelessWidget {
  const _FileLine({super.key, required this.name, required this.note, this.struck = false});

  final String name;
  final String note;
  final bool struck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      decoration: struck ? TextDecoration.lineThrough : null,
      color: struck ? theme.colorScheme.onSurfaceVariant : null,
    );
    return Row(
      children: [
        Expanded(child: Text(name, style: style, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Text(note, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _Uploading extends StatelessWidget {
  const _Uploading({required this.archive, required this.progress, required this.onCancel});

  final PickedArchive archive;
  final double progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final percent = (progress * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(archive.name, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        LinearProgressIndicator(key: const Key('import-progress'), value: progress),
        const SizedBox(height: 16),
        Semantics(
          key: const Key('import-status'),
          liveRegion: true,
          child: Text('Uploading … · $percent%', textAlign: TextAlign.center),
        ),
        const SizedBox(height: 8),
        Text(
          'Reading and uploading on this device. Nothing needs to stay open in Spotify.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          key: const Key('import-cancel'),
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.result, required this.notifier});

  final ListeningImportResult result;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = result.summary;
    final extended = result.inventory.package == ExportPackage.spotifyExtended;
    final playlists = result.playlistSummary;
    final ledger = ledgerRange(summary.ledgerFrom, summary.ledgerTo);
    final counts = extended
        ? '${plural(summary.tracks, 'track')} · ${plural(summary.days, 'day')} with plays'
        : [
            plural(summary.libraryTracks, 'liked song'),
            plural(summary.artists, 'artist'),
            if (playlists != null) plural(playlists.playlists, 'playlist'),
          ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ResultTitle(
          icon: Icons.check_circle_outline,
          title: extended ? 'Extended history imported' : 'Account data imported',
        ),
        const SizedBox(height: 8),
        Text(counts, key: const Key('import-done-counts')),
        if (ledger != null) Text('Ledger $ledger', key: const Key('import-ledger')),
        if (summary.unresolvedRows > 0)
          Text(
            '${plural(summary.unresolvedRows, 'row')} skipped (podcasts, local files, no track)',
            style: theme.textTheme.bodySmall,
          ),
        if (playlists != null && playlists.unresolvedEntries > 0)
          Text(
            '${playlists.unresolvedEntries} playlist '
            '${playlists.unresolvedEntries == 1 ? 'entry is' : 'entries are'} still unmatched.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        Text(
          'The DJ starts with what it knows best. More detail arrives over the next hours as '
          'tracks are enriched.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('import-make-mix'),
          onPressed: () => _makeMix(context, notifier),
          child: const Text('Make your first mix'),
        ),
        TextButton(
          key: const Key('import-other'),
          onPressed: () {
            notifier.reset();
            notifier.pick();
          },
          child: Text(extended ? 'Import the account data too' : 'Import the extended history too'),
        ),
        const _WaitingFile(),
      ],
    );
  }
}

/// The history was published but the playlist sync after it failed. Same
/// copy as the web's partial card; "Retry playlists" re-imports the same
/// file (idempotent on the server) so the playlist sync runs again.
class _Partial extends StatelessWidget {
  const _Partial({required this.result, required this.notifier});

  final ListeningImportResult result;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = result.summary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ResultTitle(
          icon: Icons.error_outline,
          title: "Account data imported, playlists didn't land",
        ),
        const SizedBox(height: 4),
        Text(
          'Likes and followed artists are in. The playlist sync was interrupted.',
          key: const Key('import-partial-subtitle'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${plural(summary.libraryTracks, 'liked song')} · ${plural(summary.artists, 'artist')}',
          key: const Key('import-done-counts'),
        ),
        const SizedBox(height: 12),
        Text(
          'Your liked songs and artists are safe on the server. Nothing is lost and nothing needs '
          're-uploading; the playlists can follow later.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('import-make-mix'),
          onPressed: () => _makeMix(context, notifier),
          child: const Text('Make a mix anyway'),
        ),
        TextButton(
          key: const Key('import-retry-playlists'),
          onPressed: notifier.retryPlaylists,
          child: const Text('Retry playlists'),
        ),
        Text(
          'Re-uploads the file; nothing is duplicated.',
          key: const Key('import-retry-note'),
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const _WaitingFile(),
      ],
    );
  }
}

void _makeMix(BuildContext context, ListeningImportNotifier notifier) {
  notifier.reset();
  Navigator.of(context).popUntil((route) => route.isFirst);
}

class _ResultTitle extends StatelessWidget {
  const _ResultTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            key: const Key('import-done-title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.state, required this.notifier});

  final ImportFailed state;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diagnostics = state.diagnostics;
    final unreadable = state.unreadable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          unreadable ? "Couldn't read this export" : 'Import failed',
          key: const Key('import-failed-title'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(state.message),
        if (unreadable) ...[
          const SizedBox(height: 8),
          Text(
            'Expected files: $expectedExportFiles.',
            key: const Key('import-expected'),
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (state.diagnosing) ...[
          const SizedBox(height: 12),
          Text(
            'Building the report…',
            key: const Key('import-diagnosing'),
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (diagnostics != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              diagnostics.canonicalJsonString(),
              key: const Key('import-diagnostics'),
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The report lists file names, sizes, and row counts only. No song, artist, or personal data.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const Key('import-copy-report'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: diagnostics.canonicalJsonString()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied')));
            },
            child: const Text('Copy report'),
          ),
        ],
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('import-try-another'),
          onPressed: () {
            notifier.reset();
            notifier.pick();
          },
          child: const Text('Try another file'),
        ),
        const _WaitingFile(),
      ],
    );
  }
}
