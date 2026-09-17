import 'package:flutter/material.dart';
import 'dart:math';
import '../../import/collection_review.dart';
import '../../import/snapshot.dart';

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
  @override
  Widget build(BuildContext context) {
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
        Text(
          'Review your music',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Files suggest names, not playlist identities. Choose what each file represents. Other playlists and history stay as they are.',
        ),
        if (selected != null)
          Text(
            '${selected.tracks.length} unique songs · ${selected.library.length} liked songs · ${selected.playlists.length} playlists',
          ),
        if (selected == null)
          const Text(
            'Choose at least one nonempty collection, valid names, distinct replacement targets, and no more than one Liked Songs file.',
          ),
        for (var i = 0; i < selection.files.length; i++) ...[
          const SizedBox(height: 16),
          Text(
            '${i < paths.length ? paths[i] : snapshot.playlists[i].name} · ${snapshot.playlists[i].entries.length} entries',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (snapshot.playlists[i].name.toLowerCase() == 'liked')
            const Text('This may be Liked Songs. Confirm its role below.'),
          TextFormField(
            key: ValueKey('collection-name-$i'),
            initialValue: selection.files[i].name,
            enabled: selection.files[i].role == 'playlist',
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Save as',
              counterText: '',
            ),
            onChanged: (name) =>
                fileChanged(i, selection.files[i].change(name: name)),
          ),
          DropdownButtonFormField<String>(
            initialValue: selection.files[i].role,
            decoration: const InputDecoration(labelText: 'Use as'),
            items: const [
              DropdownMenuItem(value: 'playlist', child: Text('Playlist')),
              DropdownMenuItem(value: 'liked', child: Text('Liked Songs')),
              DropdownMenuItem(value: 'skip', child: Text('Skip')),
            ],
            onChanged: (role) {
              if (role != null) {
                fileChanged(i, selection.files[i].change(role: role));
              }
            },
          ),
          if (selection.files[i].role == 'playlist')
            DropdownButtonFormField<String>(
              key: ValueKey('collection-target-$i'),
              initialValue: selection.files[i].target ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Playlist action'),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Create new playlist'),
                ),
                for (final p in selection.context.playlists)
                  DropdownMenuItem(
                    value: p.key,
                    child: Text(
                      'Replace: ${p.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (key) {
                if (key != null) {
                  fileChanged(
                    i,
                    selection.files[i].change(
                      action: key,
                      newKey: key.isEmpty
                          ? 'exportify:new:${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}'
                          : null,
                    ),
                  );
                }
              },
            ),
        ],
        if (hasLikes) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: selection.mode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Liked Songs update'),
            items: const [
              DropdownMenuItem(value: 'add', child: Text('Add songs')),
              DropdownMenuItem(
                value: 'replace',
                child: Text('Replace imported Liked Songs'),
              ),
            ],
            onChanged: (mode) {
              if (mode != null) {
                onChanged(
                  selection.change(
                    mode: mode,
                    confirmed: false,
                    confirmRemovals: false,
                  ),
                );
              }
            },
          ),
          if (selection.mode == 'replace')
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Remove $removed songs from Spotify imported Liked Songs. Songs missing from this file will leave that saved collection; other providers stay unchanged.',
              ),
              value: selection.confirmRemovals,
              onChanged: (v) =>
                  onChanged(selection.change(confirmRemovals: v ?? false)),
            ),
        ],
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'I reviewed the collection roles and replacement targets.',
          ),
          value: selection.confirmed,
          onChanged: (v) => onChanged(selection.change(confirmed: v ?? false)),
        ),
        const Text(
          'This file contains saved music, not listening history. Add history later with Go deeper.',
        ),
      ],
    );
  }
}
