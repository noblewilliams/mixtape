/// The reviewed-collection form from the Exportify approval
/// (`docs/mockups/approved/2026-09-08-exportify-import.md`): what each file
/// represents, where a playlist lands, and the explicit confirmation before a
/// Liked Songs replacement.
///
/// Plan task 8.7 restyles it onto the September 17 shell — flush rows with
/// hairlines, sliding segmented controls for the two- and three-way choices,
/// replacement targets as inset rows with a chevron. The fields, the
/// validation and the copy are unchanged.
library;

import 'dart:math';

import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../../import/collection_review.dart';
import '../../import/snapshot.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/inset_group.dart';
import 'foundation/section_word.dart';
import 'foundation/mixtape_sheet.dart';

class CollectionReviewForm extends StatelessWidget {
  const CollectionReviewForm({
    super.key,
    required this.snapshot,
    this.paths = const [],
    required this.selection,
    required this.onChanged,
  });

  final ListeningExportSnapshot snapshot;
  final List<String> paths;
  final CollectionSelection selection;
  final ValueChanged<CollectionSelection> onChanged;

  /// Above this text scale the segmented controls give way to stacked rows:
  /// three side-by-side labels cannot hold 320 pt at 200%.
  static const double stackChoicesScale = 1.5;

  /// What a playlist file with no replacement target reads as.
  static const String newPlaylistLabel = 'Create new playlist';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    void fileChanged(int i, CollectionFile file) => onChanged(
      selection.change(
        files: [
          for (var j = 0; j < selection.files.length; j++)
            j == i ? file : selection.files[j],
        ],
        confirmed: false,
        confirmRemovals: false,
      ),
    );
    final hasLikes =
        snapshot.package == ExportPackage.spotifyAccount ||
        selection.files.any((f) => f.role == 'liked');
    ListeningExportSnapshot? selected;
    try {
      selected = selection
          .change(confirmed: true, confirmRemovals: true)
          .apply(snapshot)
          .snapshot;
    } catch (_) {}
    final incoming =
        selected?.library.map((r) => r.platformId).toSet() ?? <String>{};
    final removed = selection.context.ids
        .where((id) => !incoming.contains(id))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Review your music'),
        Text(
          'Files suggest names, not playlist identities. Choose what each file '
          'represents. Other playlists and history stay as they are.',
          style: tokens.secondary,
        ),
        const SizedBox(height: 6),
        if (selected != null)
          Text(
            '${selected.tracks.length} unique songs · ${selected.library.length} '
            'liked songs · ${selected.playlists.length} playlists',
            key: const Key('collection-summary'),
            style: tokens.meta,
          ),
        if (selected == null)
          Text(
            'Choose at least one nonempty collection, valid names, distinct '
            'replacement targets, and no more than one Liked Songs file.',
            key: const Key('collection-invalid'),
            style: tokens.meta.copyWith(color: tokens.warnInk),
          ),
        for (var i = 0; i < selection.files.length; i++) ...[
          const SizedBox(height: 16),
          Text(
            '${i < paths.length ? paths[i] : snapshot.playlists[i].name} · '
            '${snapshot.playlists[i].entries.length} entries',
            style: tokens.rowTitle,
          ),
          if (snapshot.playlists[i].name.toLowerCase() == 'liked')
            Text(
              'This may be Liked Songs. Confirm its role below.',
              style: tokens.meta,
            ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('collection-name-$i'),
            initialValue: selection.files[i].name,
            enabled: selection.files[i].role == 'playlist',
            maxLength: 500,
            style: tokens.body,
            decoration: const InputDecoration(
              labelText: 'Save as',
              counterText: '',
            ),
            onChanged: (name) =>
                fileChanged(i, selection.files[i].change(name: name)),
          ),
          const SizedBox(height: 10),
          _ChoiceField(
            label: 'Use as',
            controlKey: ValueKey('collection-role-$i'),
            optionKey: (value) => ValueKey('collection-role-$i-$value'),
            value: selection.files[i].role,
            options: const {
              'playlist': 'Playlist',
              'liked': 'Liked Songs',
              'skip': 'Skip',
            },
            onChanged: (role) =>
                fileChanged(i, selection.files[i].change(role: role)),
          ),
          if (selection.files[i].role == 'playlist')
            _TargetField(
              index: i,
              selection: selection,
              onPick: (key) => fileChanged(
                i,
                selection.files[i].change(
                  action: key,
                  newKey: key.isEmpty
                      ? 'exportify:new:${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}'
                      : null,
                ),
              ),
            ),
        ],
        if (hasLikes) ...[
          const SizedBox(height: 16),
          _ChoiceField(
            label: 'Liked Songs update',
            controlKey: const ValueKey('collection-mode'),
            optionKey: (value) => ValueKey('collection-mode-$value'),
            value: selection.mode,
            options: const {
              'add': 'Add songs',
              'replace': 'Replace imported Liked Songs',
            },
            onChanged: (mode) => onChanged(
              selection.change(
                mode: mode,
                confirmed: false,
                confirmRemovals: false,
              ),
            ),
          ),
          if (selection.mode == 'replace')
            _ConfirmRow(
              rowKey: const Key('collection-confirm-removals'),
              value: selection.confirmRemovals,
              label:
                  'Remove $removed songs from Spotify imported Liked Songs. Songs '
                  'missing from this file will leave that saved collection; other '
                  'providers stay unchanged.',
              onChanged: (v) => onChanged(selection.change(confirmRemovals: v)),
            ),
        ],
        _ConfirmRow(
          rowKey: const Key('collection-confirmed'),
          value: selection.confirmed,
          label: 'I reviewed the collection roles and replacement targets.',
          onChanged: (v) => onChanged(selection.change(confirmed: v)),
        ),
        Text(
          'This file contains saved music, not listening history. Add history '
          'later with Go deeper.',
          style: tokens.meta,
        ),
      ],
    );
  }
}

/// A labelled two- or three-way choice: the native sliding segmented control,
/// or stacked rows once the text is too large for segments to fit 320 pt.
class _ChoiceField extends StatelessWidget {
  const _ChoiceField({
    required this.label,
    required this.controlKey,
    required this.optionKey,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final Key controlKey;
  final Key Function(String value) optionKey;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) >=
        CollectionReviewForm.stackChoicesScale;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: tokens.label),
        const SizedBox(height: 6),
        if (stacked)
          InsetGroup(
            key: controlKey,
            children: [
              for (final entry in options.entries)
                InsetRow(
                  key: optionKey(entry.key),
                  title: entry.value,
                  trailing: entry.key == value
                      ? Icon(Icons.check, size: 18, color: tokens.plum)
                      : const SizedBox.shrink(),
                  onTap: () => onChanged(entry.key),
                ),
            ],
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMetrics.minTarget,
            ),
            child: CupertinoSlidingSegmentedControl<String>(
              key: controlKey,
              groupValue: value,
              children: {
                for (final entry in options.entries)
                  entry.key: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Text(
                      entry.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.meta.copyWith(color: tokens.text),
                    ),
                  ),
              },
              onValueChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
      ],
    );
  }
}

/// Where a playlist file lands: a new playlist, or one of the collections
/// already imported. An inset row with a chevron, over a sheet of the targets.
class _TargetField extends StatelessWidget {
  const _TargetField({
    required this.index,
    required this.selection,
    required this.onPick,
  });

  final int index;
  final CollectionSelection selection;
  final ValueChanged<String> onPick;

  String get _label {
    final target = selection.files[index].target;
    if (target == null || target.isEmpty) {
      return CollectionReviewForm.newPlaylistLabel;
    }
    for (final p in selection.context.playlists) {
      if (p.key == target) return 'Replace: ${p.name}';
    }
    return CollectionReviewForm.newPlaylistLabel;
  }

  Future<void> _pick(BuildContext context) async {
    final chosen = await showMixtapeSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: InsetGroup(
          header: const SectionWord('Playlist action'),
          children: [
            InsetRow(
              key: ValueKey('collection-target-$index-option-new'),
              title: CollectionReviewForm.newPlaylistLabel,
              onTap: () => Navigator.of(sheetContext).pop(''),
            ),
            for (final p in selection.context.playlists)
              InsetRow(
                key: ValueKey('collection-target-$index-option-${p.key}'),
                title: 'Replace: ${p.name}',
                onTap: () => Navigator.of(sheetContext).pop(p.key),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) onPick(chosen);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: InsetGroup(
      children: [
        InsetRow(
          key: ValueKey('collection-target-$index'),
          title: 'Playlist action',
          subtitle: _label,
          onTap: () => _pick(context),
        ),
      ],
    ),
  );
}

/// One explicit confirmation: a checkbox on a flush row with a hairline above
/// it, the whole row a 44 pt target.
class _ConfirmRow extends StatelessWidget {
  const _ConfirmRow({
    required this.rowKey,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final Key rowKey;
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      checked: value,
      label: label,
      // Without an action of its own the node reads as a checkbox VoiceOver
      // cannot flip; the gesture below is not in the semantics tree.
      onTap: () => onChanged(!value),
      excludeSemantics: true,
      child: GestureDetector(
        key: rowKey,
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Container(
          margin: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.hairline)),
          ),
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                value ? Icons.check_box : Icons.check_box_outline_blank,
                size: 22,
                color: value ? tokens.plum : tokens.muted,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: tokens.secondary)),
            ],
          ),
        ),
      ),
    );
  }
}
