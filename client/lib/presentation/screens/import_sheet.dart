/// The Spotify import flow as a modal sheet: pick a ZIP → inventory and
/// review → upload with progress → done / partial / failed / cancelled.
///
/// Behaviour is the September 8 Exportify approval
/// (`docs/mockups/approved/2026-09-08-exportify-import.md`) over the September
/// 4 web import record; plan task 8.7 restyles it onto the September 17 shell
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`): the shared sheet
/// chrome, flush rows, status words, a prism progress bar, and tape/chip/
/// text controls. Every fact shown still comes from the inventory or the
/// summary; never a track, artist, or playlist name.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/files/archive_picker.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../import/listening_import_service.dart';
import '../../import/snapshot.dart';
import '../format/import_format.dart';
import '../providers/listening_import_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/opened_archive_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/collection_review_form.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import 'interview_screen.dart';
import '../widgets/foundation/mixtape_sheet.dart';

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
Future<void> showImportSheet(
  BuildContext context, {
  bool dismissible = true,
}) async {
  var landed = false;
  await showMixtapeSheet<void>(
    context,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    builder: (_) => dismissible
        ? const ImportSheet()
        : _LockedSheet(onLanded: () => landed = true),
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
          style: context.tokens.meta,
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TapeButton(
            key: const Key('import-waiting-start'),
            label: 'Import it',
            onPressed: () => startHandedArchive(ref, waiting),
          ),
        ),
      ],
    );
  }
}

/// The Spotify import flow, inside the shared sheet chrome.
class ImportSheet extends ConsumerStatefulWidget {
  const ImportSheet({super.key});

  /// The fraction of the screen the sheet may take before it scrolls inside
  /// itself — the 200% text case.
  static const double maxHeightFactor = 0.9;

  /// The air under the sheet's own content. The home indicator is cleared by
  /// [MixtapeSheetChrome]'s bottom padding, not by a second inset here
  /// (smoke round four, note 1: the sheet wore two handles and a dead band).
  static const double contentBottomPadding = 12;

  /// The review step's pinned footer, and the "pick another file" action on
  /// it. The key is the one the bottom action carried before the footer
  /// existed, so the flow's tests and automation still find it.
  static const Key footerKey = Key('import-footer');
  static const Key newFileKey = Key('import-pick-other');

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
    final body = switch (state) {
      ImportIdle() => _Idle(onPick: notifier.pick),
      ImportFlowCancelled() => _Idle(onPick: notifier.pick, cancelled: true),
      ImportInspecting(:final archive, :final file, :final progress) =>
        _Inspecting(
          archive: archive,
          file: file,
          progress: progress,
          onCancel: notifier.cancel,
        ),
      ImportInventory() => _Inventory(state: state, notifier: notifier),
      ImportUploading(:final archive, :final progress) => _Uploading(
        archive: archive,
        progress: progress,
        onCancel: notifier.cancel,
      ),
      ImportDone(:final result) => _Done(result: result, notifier: notifier),
      ImportPartial(:final result) => _Partial(
        result: result,
        notifier: notifier,
      ),
      ImportFailed() => _Failed(state: state, notifier: notifier),
    };

    // The review step is the one step with a pinned footer: it fills the
    // sheet, its list scrolls, and Upload / New file stay on the bottom edge
    // (smoke round six, note 5).
    final reviewing =
        state is ImportInventory && state.preview.selection != null;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    // No handle, no surface and no safe area of its own: the shared chrome
    // draws one handle, paints the sheet and clears the home indicator, and a
    // second copy of each is what the founder read as a transparent sheet
    // with a dead band under it (smoke round four, note 1). The height is
    // whatever the step needs — the review fills the sheet, the idle "Choose
    // files" step hugs its content.
    // Measured from the height under the status bar, not the whole screen: at
    // 90% of the screen the full-height review pushed its own grab handle up
    // behind the Dynamic Island (smoke round six). The sheet route clears
    // both `padding.top` and `viewPadding.top` on the way in (`useSafeArea:
    // false`), so the inset is read off the window itself.
    final topInset = MediaQueryData.fromView(View.of(context)).padding.top;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            (MediaQuery.sizeOf(context).height - topInset) *
            ImportSheet.maxHeightFactor,
      ),
      // The review's footer rides above the keyboard; every other step lets
      // its content scroll clear of it instead.
      child: Padding(
        padding: EdgeInsets.only(bottom: reviewing ? keyboard : 0),
        child: Column(
          mainAxisSize: reviewing ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                // The review stage has text fields: the keyboard's inset is
                // padding, not a clip, so "Save as" scrolls above it.
                padding: EdgeInsets.fromLTRB(
                  20,
                  4,
                  20,
                  ImportSheet.contentBottomPadding + (reviewing ? 0 : keyboard),
                ),
                child: body,
              ),
            ),
            // The footer's own air sits under it, not inside it, so its edge
            // lands one inset above the home indicator — the chrome's safe
            // area — rather than stacking a second inset on top of it.
            if (reviewing)
              Padding(
                padding: const EdgeInsets.only(
                  bottom: ImportSheet.contentBottomPadding,
                ),
                child: _ReviewFooter(state: state, notifier: notifier),
              ),
          ],
        ),
      ),
    );
  }
}

/// The review step's pinned footer: Upload on the left, New file on the
/// right, a hairline between it and the list scrolling under it.
class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter({required this.state, required this.notifier});

  final ImportInventory state;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final preview = state.preview;
    final selection = preview.selection!;
    // Pressing Upload is the review: the old "I reviewed the collection
    // roles" checkbox is gone (smoke round six, note 5). Everything else the
    // selection must satisfy — a nonempty collection, valid names, distinct
    // targets, and the explicit tick before Liked Songs are replaced — still
    // gates the button.
    final reviewed = selection.change(confirmed: true);
    return Container(
      key: ImportSheet.footerKey,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TapeButton(
            key: const Key('import-upload'),
            label: 'Upload',
            onPressed: reviewed.canUpload(preview.snapshot)
                ? () {
                    notifier.setSelection(reviewed);
                    notifier.upload();
                  }
                : null,
          ),
          LabelChip(
            key: ImportSheet.newFileKey,
            label: 'New file',
            onPressed: () {
              notifier.reset();
              notifier.pick();
            },
          ),
        ],
      ),
    );
  }
}

String packageName(ExportPackage? package) => switch (package) {
  ExportPackage.spotifyExtended => 'Extended streaming history',
  ExportPackage.spotifyAccount => 'Account data',
  ExportPackage.spotifyExportify => 'Exportify saved music',
  null => 'Unknown package',
};

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// The upload's prism-filled bar: the board's stripe, laid flat.
///
/// The indicator itself stays a [LinearProgressIndicator] — the progress is a
/// platform fact a screen reader and the tests both read off it — with the
/// track drawn behind it and the prism painted through its value bar.
class ImportProgressBar extends StatelessWidget {
  const ImportProgressBar({super.key, required this.value, this.indicatorKey});

  /// 0…1, or null while the work reports no fraction yet.
  final double? value;

  /// Goes on the [LinearProgressIndicator] itself.
  final Key? indicatorKey;

  /// The board's stripe thickness.
  static const double thickness = 7;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = BorderRadius.circular(MixtapeMetrics.pillRadius);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: thickness,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: tokens.hairline),
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) =>
                  LinearGradient(colors: tokens.prism).createShader(bounds),
              child: LinearProgressIndicator(
                key: indicatorKey,
                value: value,
                minHeight: thickness,
                backgroundColor: Colors.transparent,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A flush fact row: label on the left, value on the right, a hairline above
/// every row but the first.
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    this.value,
    this.valueWidget,
    this.isFirst = false,
  });

  final String label;
  final String? value;
  final Widget? valueWidget;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      decoration: isFirst
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: tokens.hairline)),
            ),
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: tokens.body)),
          const SizedBox(width: 12),
          valueWidget ??
              Flexible(
                child: Text(
                  value ?? '',
                  textAlign: TextAlign.end,
                  style: tokens.rowTitle,
                ),
              ),
        ],
      ),
    );
  }
}

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
          cancelled
              ? 'Import cancelled.'
              : 'Choose an Exportify ZIP or CSV files, or an official Spotify ZIP. Review before uploading.',
          style: context.tokens.body,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TapeButton(
            key: const Key('import-pick'),
            label: 'Choose files',
            onPressed: onPick,
          ),
        ),
      ],
    );
  }
}

class _Inspecting extends StatelessWidget {
  const _Inspecting({
    required this.archive,
    required this.onCancel,
    this.file,
    this.progress,
  });

  final PickedArchive archive;
  final String? file;
  final double? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Reading ${file == null ? archive.name : _baseName(file!)}…',
              style: context.tokens.body,
            ),
          ),
          // The approval's compact Cancel: beside the heading, no row of its
          // own, still a 44 pt target.
          TextAction(
            key: const Key('import-cancel'),
            label: 'Cancel',
            onPressed: onCancel,
          ),
        ],
      ),
      const SizedBox(height: 10),
      ImportProgressBar(value: progress),
    ],
  );
}

class _Inventory extends StatelessWidget {
  const _Inventory({required this.state, required this.notifier});

  final ImportInventory state;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final preview = state.preview;
    final inventory = preview.inventory;
    var snapshot = preview.snapshot;
    if (preview.selection != null) {
      try {
        snapshot = preview.selection!
            .change(confirmed: true, confirmRemovals: true)
            .apply(snapshot)
            .snapshot;
      } catch (_) {}
    }
    final extended = preview.package == ExportPackage.spotifyExtended;
    final reviewing = preview.selection != null;
    final package = StatusWord(
      key: const Key('import-file-package'),
      label: packageName(inventory.package),
      kind: inventory.package == null ? StatusKind.warn : StatusKind.ok,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One header block for the review step: the sheet's heading with a
        // Cancel on its right edge, then the file's own facts on one line
        // (smoke round six, note 3). Packages with nothing to review keep the
        // stacked fact rows, which are all they have.
        if (reviewing) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Review your music',
                  style: MixtapeSheet.headingOf(context),
                ),
              ),
              TextAction(
                key: const Key('import-cancel'),
                label: 'Cancel',
                onPressed: () {
                  Navigator.of(context).pop();
                  notifier.reset();
                },
              ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${state.archive.name} · ${formatBytes(state.archive.bytes)} · ',
                key: const Key('import-file-name'),
                style: tokens.meta,
              ),
              package,
            ],
          ),
          const SizedBox(height: 6),
        ] else ...[
          _FactRow(
            label: 'File',
            isFirst: true,
            valueWidget: Flexible(
              child: Text(
                state.archive.name,
                key: const Key('import-file-name'),
                textAlign: TextAlign.end,
                style: tokens.rowTitle,
              ),
            ),
          ),
          _FactRow(
            label: 'Size',
            valueWidget: Text(
              formatBytes(state.archive.bytes),
              key: const Key('import-file-meta'),
              style: tokens.rowTitle,
            ),
          ),
          _FactRow(
            label: 'Package',
            valueWidget: Flexible(child: package),
          ),
        ],
        if (preview.selection != null)
          CollectionReviewForm(
            snapshot: preview.snapshot,
            paths: inventory.read.map((f) => f.path).toList(),
            selection: preview.selection!,
            onChanged: notifier.setSelection,
          ),
        // Every figure comes from the parse the service ran at inspect: the
        // snapshot for the counts, its stats for the drops.
        if (preview.selection == null) ...[
          _FactRow(label: 'Tracks', value: formatCount(preview.tracks)),
          if (extended) ...[
            _FactRow(
              label: 'Days with plays',
              value: formatCount(preview.daysWithPlays),
            ),
            _FactRow(
              label: 'Years covered',
              value: yearsRange(snapshot.ledgerFrom, snapshot.ledgerTo) ?? '—',
            ),
          ] else ...[
            _FactRow(
              label: 'Liked songs',
              value: formatCount(snapshot.library.length),
            ),
            _FactRow(
              label: 'Artists',
              value: formatCount(snapshot.artists.length),
            ),
            _FactRow(
              label: 'Playlists',
              value: formatCount(snapshot.playlists.length),
            ),
          ],
          _FactRow(
            label: 'Skipped rows',
            value: skippedRowsLabel(
              podcasts: preview.skippedPodcasts,
              localFiles: preview.skippedLocalFiles,
            ),
          ),
          if (extended) ...[
            const SizedBox(height: 6),
            Text(
              'Local days in ${state.timeZone}',
              key: const Key('import-zone'),
              style: tokens.meta,
            ),
          ],
          const SectionWord('Files read'),
          for (var i = 0; i < inventory.read.length; i++)
            _FileLine(
              key: Key('import-read-${_baseName(inventory.read[i].path)}'),
              name: _baseName(inventory.read[i].path),
              note: inventory.read[i].rows == null
                  ? 'unreadable'
                  : plural(inventory.read[i].rows!, 'row'),
              isFirst: i == 0,
            ),
          if (inventory.ignored.isNotEmpty) ...[
            const SectionWord('Ignored · never read'),
            for (var i = 0; i < inventory.ignored.length; i++)
              _FileLine(
                key: Key(
                  'import-ignored-${_baseName(inventory.ignored[i].path)}',
                ),
                name: _baseName(inventory.ignored[i].path),
                note: 'ignored',
                struck: true,
                isFirst: i == 0,
              ),
          ],
        ],
        if (extended) ...[
          const SizedBox(height: 12),
          InsetGroup(
            children: [
              InsetRow(
                key: const Key('import-private-row'),
                title: 'Include private sessions',
                subtitle: privateSessionsHint(preview.privatePlays),
                trailing: Switch.adaptive(
                  key: const Key('import-private-sessions'),
                  value: state.includePrivateSessions,
                  onChanged: notifier.setIncludePrivateSessions,
                ),
                onTap: () => notifier.setIncludePrivateSessions(
                  !state.includePrivateSessions,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Only reviewed music leaves this device. Your account details, payments, and IP addresses are never read.',
          key: const Key('import-privacy'),
          style: tokens.meta,
        ),
        // The review step carries these on its pinned footer instead.
        if (!reviewing) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TapeButton(
              key: const Key('import-upload'),
              label: 'Upload',
              onPressed: snapshot.package != ExportPackage.spotifyExportify
                  ? notifier.upload
                  : null,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              key: ImportSheet.newFileKey,
              label: 'Choose a different file',
              onPressed: () {
                notifier.reset();
                notifier.pick();
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _FileLine extends StatelessWidget {
  const _FileLine({
    super.key,
    required this.name,
    required this.note,
    this.struck = false,
    this.isFirst = false,
  });

  final String name;
  final String note;
  final bool struck;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.meta.copyWith(
      fontFamily: 'monospace',
      decoration: struck ? TextDecoration.lineThrough : null,
      color: struck ? tokens.muted : null,
    );
    return Container(
      decoration: isFirst
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: tokens.hairline)),
            ),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(name, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(note, style: tokens.meta),
        ],
      ),
    );
  }
}

class _Uploading extends StatelessWidget {
  const _Uploading({
    required this.archive,
    required this.progress,
    required this.onCancel,
  });

  final PickedArchive archive;
  final double progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final percent = (progress * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(archive.name, style: tokens.rowTitle)),
            TextAction(
              key: const Key('import-cancel'),
              label: 'Cancel',
              onPressed: onCancel,
            ),
          ],
        ),
        const SizedBox(height: 14),
        ImportProgressBar(
          indicatorKey: const Key('import-progress'),
          value: progress,
        ),
        const SizedBox(height: 14),
        Semantics(
          key: const Key('import-status'),
          liveRegion: true,
          child: Text('Uploading … · $percent%', style: tokens.body),
        ),
        const SizedBox(height: 6),
        Text(
          'Reading and uploading on this device. Nothing needs to stay open in Spotify.',
          style: tokens.meta,
        ),
      ],
    );
  }
}

class _Done extends ConsumerWidget {
  const _Done({required this.result, required this.notifier});

  final ListeningImportResult result;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsInterview =
        result.inventory.package == ExportPackage.spotifyExportify &&
        ref.watch(onboardingProvider).value?.interviewCompletedAt == null;
    final tokens = context.tokens;
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
        SectionWord(
          extended
              ? 'Extended history imported'
              : result.inventory.package == ExportPackage.spotifyExportify
              ? 'Spotify music imported'
              : 'Account data imported',
          key: const Key('import-done-title'),
        ),
        _FactRow(
          label: 'Imported',
          isFirst: true,
          valueWidget: Flexible(
            child: Semantics(
              liveRegion: true,
              child: StatusWord(
                key: const Key('import-done-counts'),
                label: counts,
                kind: StatusKind.ok,
              ),
            ),
          ),
        ),
        if (ledger != null)
          _FactRow(
            label: 'Ledger',
            valueWidget: Text(
              ledger,
              key: const Key('import-ledger'),
              style: tokens.rowTitle,
            ),
          ),
        if (summary.unresolvedRows > 0)
          _FactRow(
            label: 'Skipped',
            valueWidget: Flexible(
              child: StatusWord(
                label:
                    '${plural(summary.unresolvedRows, 'row')} skipped (podcasts, local files, no track)',
                kind: StatusKind.warn,
              ),
            ),
          ),
        if (playlists != null && playlists.unresolvedEntries > 0)
          _FactRow(
            label: 'Unmatched',
            valueWidget: Flexible(
              child: StatusWord(
                label:
                    '${playlists.unresolvedEntries} playlist '
                    '${playlists.unresolvedEntries == 1 ? 'entry is' : 'entries are'} still unmatched.',
                kind: StatusKind.warn,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          'The DJ starts with what it knows best. More detail arrives over the next hours as '
          'tracks are enriched.',
          style: tokens.meta,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TapeButton(
            key: const Key('import-make-mix'),
            label: needsInterview
                ? 'Tell the DJ about your taste'
                : 'Make your first mix',
            onPressed: () {
              if (needsInterview) {
                notifier.reset();
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const InterviewScreen(),
                  ),
                );
              } else {
                _makeMix(context, notifier);
              }
            },
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextAction(
            key: const Key('import-other'),
            label: extended
                ? 'Import the account data too'
                : 'Import the extended history too',
            onPressed: () {
              notifier.reset();
              notifier.pick();
            },
          ),
        ),
        const _WaitingFile(),
      ],
    );
  }
}

/// The history was published but the playlist sync after it failed. Same
/// copy as the web's partial card; "Retry playlists" re-imports the same
/// file (idempotent on the server) so the playlist sync runs again.
class _Partial extends ConsumerWidget {
  const _Partial({required this.result, required this.notifier});

  final ListeningImportResult result;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsInterview =
        result.inventory.package == ExportPackage.spotifyExportify &&
        ref.watch(onboardingProvider).value?.interviewCompletedAt == null;
    final tokens = context.tokens;
    final summary = result.summary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: const SectionWord(
            "Account data imported, playlists didn't land",
            key: Key('import-done-title'),
          ),
        ),
        Text(
          result.inventory.package == ExportPackage.spotifyExportify
              ? 'The saved-song step finished. Review and retry the playlists.'
              : 'Likes and followed artists are in. The playlist sync was interrupted.',
          key: const Key('import-partial-subtitle'),
          style: tokens.meta,
        ),
        const SizedBox(height: 8),
        _FactRow(
          label: 'Imported',
          isFirst: true,
          valueWidget: Flexible(
            child: Semantics(
              liveRegion: true,
              child: StatusWord(
                key: const Key('import-done-counts'),
                label:
                    '${plural(summary.libraryTracks, 'liked song')} · ${plural(summary.artists, 'artist')}',
                kind: StatusKind.ok,
              ),
            ),
          ),
        ),
        _FactRow(
          label: 'Playlists',
          valueWidget: const StatusWord(
            label: "didn't land",
            kind: StatusKind.err,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your liked songs and artists are safe on the server. Nothing is lost and nothing needs '
          're-uploading; the playlists can follow later.',
          style: tokens.meta,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TapeButton(
            key: const Key('import-make-mix'),
            label: needsInterview
                ? 'Tell the DJ about your taste'
                : 'Make a mix anyway',
            onPressed: () {
              if (needsInterview) {
                notifier.reset();
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const InterviewScreen(),
                  ),
                );
              } else {
                _makeMix(context, notifier);
              }
            },
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextAction(
            key: const Key('import-retry-playlists'),
            label:
                result.playlistError is ApiException &&
                    (result.playlistError as ApiException).statusCode == 409
                ? 'Review again'
                : 'Retry playlists',
            onPressed: notifier.retryPlaylists,
          ),
        ),
        Text(
          'Re-uploads the file; nothing is duplicated.',
          key: const Key('import-retry-note'),
          style: tokens.meta,
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

class _Failed extends StatelessWidget {
  const _Failed({required this.state, required this.notifier});

  final ImportFailed state;
  final ListeningImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final diagnostics = state.diagnostics;
    final unreadable = state.unreadable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: SectionWord(
            unreadable ? "Couldn't read this export" : 'Import failed',
            key: const Key('import-failed-title'),
          ),
        ),
        StatusWord(label: state.message, kind: StatusKind.err),
        if (unreadable) ...[
          const SizedBox(height: 8),
          Text(
            'Expected files: $expectedExportFiles.',
            key: const Key('import-expected'),
            style: tokens.meta,
          ),
        ],
        if (state.diagnosing) ...[
          const SizedBox(height: 12),
          Text(
            'Building the report…',
            key: const Key('import-diagnosing'),
            style: tokens.meta,
          ),
        ],
        if (diagnostics != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tokens.panel,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              diagnostics.canonicalJsonString(),
              key: const Key('import-diagnostics'),
              style: tokens.meta.copyWith(fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The report lists file names, sizes, and row counts only. No song, artist, or personal data.',
            style: tokens.meta,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: LabelChip(
              key: const Key('import-copy-report'),
              label: 'Copy report',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: diagnostics.canonicalJsonString()),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Report copied')));
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (state.archive != null && !unreadable)
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              key: const Key('import-review-again'),
              label: 'Review again',
              onPressed: () => notifier.inspect(state.archive!),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextAction(
            key: const Key('import-try-another'),
            label: 'Try another file',
            onPressed: () {
              notifier.reset();
              notifier.pick();
            },
          ),
        ),
        const _WaitingFile(),
      ],
    );
  }
}
