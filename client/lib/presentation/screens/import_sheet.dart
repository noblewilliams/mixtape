import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/files/archive_picker.dart';
import '../../import/listening_import_service.dart';
import '../../import/snapshot.dart';
import '../format/import_format.dart';
import '../providers/listening_import_provider.dart';

/// Opens the import flow as a bottom sheet over the current route, the way
/// Home's library sync sheet is shown. The sheet reflects
/// [listeningImportProvider], so a run keeps going if the sheet is dismissed
/// and reopening it shows where the run got to. A sheet opened over an
/// upload in flight is not [dismissible]: it stays until the upload lands
/// or the listener cancels it.
Future<void> showImportSheet(BuildContext context, {bool dismissible = true}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      builder: (_) => const ImportSheet(),
    );

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

/// The Spotify import flow: pick a ZIP → inventory → upload with progress →
/// done / partial / failed / cancelled. Every fact shown comes from the
/// inventory or the summary; never a track, artist, or playlist name.
class ImportSheet extends ConsumerWidget {
  const ImportSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final inventory = state.inventory;
    final extended = inventory.package == ExportPackage.spotifyExtended;
    final rows = inventory.read.fold<int>(0, (sum, file) => sum + (file.rows ?? 0));
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
        // Rows read is the only figure the inventory has: the web shows
        // tracks, days, and years too, which come from the parser. The
        // inventory-preview round adds those parser stats to the inspect
        // step; until then the inventory shows what the listing counted.
        _Fact(label: 'Rows read', value: formatCount(rows)),
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
            subtitle: const Text('Plays hidden from followers stay out unless you choose otherwise.'),
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
      ],
    );
  }
}
