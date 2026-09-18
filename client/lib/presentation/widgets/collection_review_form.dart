/// The reviewed-collection form from the Exportify approval
/// (`docs/mockups/approved/2026-09-08-exportify-import.md`): what each file
/// represents, where a playlist lands, and the explicit confirmation before a
/// Liked Songs replacement.
///
/// Smoke round six reworks it file by file: every file is its own inset
/// group, captioned with its name and entry count, holding the "Save as"
/// field, the house segmented toggle for what it represents, and — for a
/// playlist — where it lands. "Set all…" sets every file at once. The sheet's
/// own heading, the file facts and the Upload / New file footer live on the
/// import sheet around this form.
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../../import/collection_review.dart';
import '../../import/snapshot.dart';
import '../format/import_format.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/inset_group.dart';
import 'foundation/label_chip.dart';
import 'foundation/mixtape_menu.dart';
import 'foundation/mixtape_sheet.dart';
import 'foundation/section_word.dart';
import 'foundation/segmented_toggle.dart';

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

  /// Above this text scale the toggles give way to stacked rows: three
  /// side-by-side labels cannot hold 320 pt at 200%.
  static const double stackChoicesScale = 1.5;

  /// What a playlist file with no replacement target reads as.
  static const String newPlaylistLabel = 'Create new playlist';

  /// The bulk action over the file groups. It only ever changes the choices
  /// on screen — nothing is uploaded until Upload is pressed.
  static const Key setAllKey = Key('collection-set-all');

  /// What each file may be, in the order the toggle shows them.
  static const Map<String, String> roleOptions = {
    'playlist': 'Playlist',
    'liked': 'Liked Songs',
    'skip': 'Skip',
  };

  static String _baseName(String path) =>
      path.substring(path.lastIndexOf('/') + 1);

  bool _stacked(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1) >= stackChoicesScale;

  void _fileChanged(int index, CollectionFile file) => onChanged(
    selection.change(
      files: [
        for (var j = 0; j < selection.files.length; j++)
          j == index ? file : selection.files[j],
      ],
      confirmed: false,
      confirmRemovals: false,
    ),
  );

  /// One choice over every file at once (smoke round six, note 4). "As
  /// detected" is the suggestion the parse itself made, file by file.
  Future<void> _setAll(BuildContext context) async {
    final choice = await showMixtapeMenu<String>(
      context,
      title: 'Set all files',
      actions: const [
        MixtapeMenuAction(
          key: Key('collection-set-all-detected'),
          label: 'As detected',
          value: 'detected',
        ),
        MixtapeMenuAction(
          key: Key('collection-set-all-playlist'),
          label: 'All as playlists',
          value: 'playlist',
        ),
        MixtapeMenuAction(
          key: Key('collection-set-all-liked'),
          label: 'All as liked songs',
          value: 'liked',
        ),
        MixtapeMenuAction(
          key: Key('collection-set-all-skip'),
          label: 'Skip all',
          value: 'skip',
        ),
      ],
    );
    if (choice == null) return;
    final detected = CollectionSelection.initial(
      snapshot,
      selection.context,
    ).files;
    onChanged(
      selection.change(
        files: [
          for (var i = 0; i < selection.files.length; i++)
            choice == 'detected'
                ? detected[i]
                : selection.files[i].change(role: choice),
        ],
        confirmed: false,
        confirmRemovals: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
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
        // The counts, and the one control that changes all of them, on one
        // line (smoke round seven, note 3): a chip, so it reads as something
        // to press rather than a word in the copy.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: selected != null
                  ? Text(
                      '${formatCount(selected.tracks.length)} songs · '
                      '${formatCount(selected.library.length)} liked · '
                      '${formatCount(selected.playlists.length)} playlists',
                      key: const Key('collection-summary'),
                      style: tokens.secondary,
                    )
                  : Text(
                      'Choose at least one nonempty collection, valid names, '
                      'distinct replacement targets, and no more than one '
                      'Liked Songs file.',
                      key: const Key('collection-invalid'),
                      style: tokens.meta.copyWith(color: tokens.warnInk),
                    ),
            ),
            const SizedBox(width: 12),
            LabelChip(
              key: setAllKey,
              label: 'Set all…',
              hole: false,
              onPressed: () => _setAll(context),
            ),
          ],
        ),
        Text(
          'Files suggest names, not playlist identities. Choose what each file '
          'represents. Other playlists and history stay as they are.',
          style: tokens.meta,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < selection.files.length; i++) _fileGroup(context, i),
        if (hasLikes) ...[
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
          const SizedBox(height: 12),
        ],
        Text(
          'This file contains saved music, not listening history. Add history '
          'later with Go deeper.',
          style: tokens.meta,
        ),
      ],
    );
  }

  /// One file: its caption, its name, what it represents, and — when it is a
  /// playlist — where it lands, in a single inset group.
  Widget _fileGroup(BuildContext context, int index) {
    final tokens = context.tokens;
    final file = selection.files[index];
    final playlist = snapshot.playlists[index];
    final name = _baseName(
      index < paths.length ? paths[index] : playlist.name,
    ).toUpperCase();
    final maybeLiked = playlist.name.toLowerCase() == 'liked';
    final caption = tokens.label.copyWith(
      color: tokens.muted,
      letterSpacing: 0.6,
    );

    return InsetGroup(
      key: ValueKey('collection-file-$index'),
      outlined: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The tiny "just information" line: the file on the left and
              // how much is in it on the right, never a track or an artist.
              Row(
                key: ValueKey('collection-caption-$index'),
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: caption,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    plural(
                      playlist.entries.length,
                      'entry',
                      'entries',
                    ).toUpperCase(),
                    style: caption,
                  ),
                ],
              ),
              if (maybeLiked)
                Text(
                  'This may be Liked Songs. Confirm its role below.',
                  style: tokens.meta,
                ),
              TextFormField(
                key: ValueKey('collection-name-$index'),
                initialValue: file.name,
                enabled: file.role == 'playlist',
                maxLength: 500,
                style: tokens.rowTitle,
                // No underline of its own: the group's hairline under the row
                // is the only rule the field needs.
                decoration: InputDecoration(
                  labelText: 'Save as',
                  labelStyle: tokens.meta,
                  counterText: '',
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
                onChanged: (value) =>
                    _fileChanged(index, file.change(name: value)),
              ),
            ],
          ),
        ),
        ..._roleChoice(context, index, file),
        // Nothing to attach to means nothing to choose: the file creates a
        // new playlist and the row is not drawn (smoke round seven, note 5).
        if (file.role == 'playlist' && selection.context.playlists.isNotEmpty)
          _TargetField(
            index: index,
            selection: selection,
            onPick: (key) => _fileChanged(
              index,
              file.change(
                action: key,
                newKey: key.isEmpty
                    ? 'exportify:new:${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}'
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  /// What the file represents, as a flush toggle row — or, once the text is
  /// too large for three segments, as rows inside the same group.
  List<Widget> _roleChoice(BuildContext context, int index, CollectionFile file) {
    void choose(String role) => _fileChanged(index, file.change(role: role));
    final key = ValueKey('collection-role-$index');
    if (_stacked(context)) {
      return [
        _StackedChoice(
          groupKey: key,
          optionKey: (value) => ValueKey('collection-role-$index-$value'),
          value: file.role,
          options: roleOptions,
          onChanged: choose,
        ),
      ];
    }
    return [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: InsetGroup.rowInset),
        child: Padding(
          // 12, not the group's 16: three segments and a border need every
          // point they can get before "Liked Songs" ellipsises at 390 pt.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedToggle<String>(
              key: key,
              value: file.role,
              options: [
                for (final entry in roleOptions.entries)
                  SegmentedOption(
                    value: entry.key,
                    label: entry.value,
                    key: ValueKey('collection-role-$index-${entry.key}'),
                  ),
              ],
              onChanged: choose,
            ),
          ),
        ),
      ),
    ];
  }
}

/// A labelled two- or three-way choice outside a file group: the house
/// toggle, or stacked rows once the text is too large for segments to fit
/// 320 pt.
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
            children: [
              _StackedChoice(
                groupKey: controlKey,
                optionKey: optionKey,
                value: value,
                options: options,
                onChanged: onChanged,
              ),
            ],
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedToggle<String>(
              key: controlKey,
              value: value,
              options: [
                for (final entry in options.entries)
                  SegmentedOption(
                    value: entry.key,
                    label: entry.value,
                    key: optionKey(entry.key),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
      ],
    );
  }
}

/// The large-text fallback for a choice: one ticked row per option, with the
/// group's own hairline between them, as a single child of its group.
class _StackedChoice extends StatelessWidget {
  const _StackedChoice({
    required this.groupKey,
    required this.optionKey,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final Key groupKey;
  final Key Function(String value) optionKey;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final entries = options.entries.toList();
    return Column(
      key: groupKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.only(left: InsetGroup.rowInset),
              child: Container(
                key: InsetGroup.hairlineKey,
                height: 1,
                color: tokens.hairline,
              ),
            ),
          InsetRow(
            key: optionKey(entries[i].key),
            title: entries[i].value,
            trailing: entries[i].key == value
                ? Icon(Icons.check, size: 18, color: tokens.plum)
                : const SizedBox.shrink(),
            onTap: () => onChanged(entries[i].key),
          ),
        ],
      ],
    );
  }
}

/// Where a playlist file lands: a new playlist, or one of the collections
/// already imported. A flush row in the file's own group, over a sheet of the
/// targets.
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
  Widget build(BuildContext context) => InsetRow(
    key: ValueKey('collection-target-$index'),
    title: 'Playlist action',
    subtitle: _label,
    onTap: () => _pick(context),
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
