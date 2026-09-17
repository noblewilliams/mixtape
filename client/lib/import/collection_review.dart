import '../data/listening/listening_models.dart';
import 'snapshot.dart';

class ImportedCollection {
  const ImportedCollection({
    required this.key,
    required this.name,
    required this.fingerprint,
    required this.fileHash,
  });
  final String key, name, fingerprint;
  final String? fileHash;
}

class CollectionContext {
  const CollectionContext({
    required this.ids,
    required this.fingerprint,
    required this.playlists,
    this.hasQuickImport = false,
  });
  final bool hasQuickImport;
  final List<String> ids;
  final String fingerprint;
  final List<ImportedCollection> playlists;
  factory CollectionContext.fromJson(Map<String, dynamic> json) {
    final library = asObject(json['library']);
    return CollectionContext(
      hasQuickImport: json['hasQuickImport'] == true,
      ids: asList(library['ids']).cast<String>(),
      fingerprint: readString(library, 'fingerprint'),
      playlists: asList(json['playlists']).map((value) {
        final p = asObject(value);
        return ImportedCollection(
          key: readString(p, 'key'),
          name: readString(p, 'name'),
          fingerprint: readString(p, 'fingerprint'),
          fileHash: p['fileHash'] as String?,
        );
      }).toList(),
    );
  }
}

class CollectionFile {
  const CollectionFile({
    required this.ordinal,
    required this.name,
    required this.role,
    required this.target,
    required this.createKey,
    required this.fileHash,
  });
  final int ordinal;
  final String name, role, createKey, fileHash;
  final String? target;
  CollectionFile change({
    String? name,
    String? role,
    String? action,
    String? newKey,
  }) => CollectionFile(
    ordinal: ordinal,
    name: name ?? this.name,
    role: role ?? this.role,
    target: action == null
        ? target
        : action.isEmpty
        ? null
        : action,
    createKey: newKey ?? createKey,
    fileHash: fileHash,
  );
}

class CollectionSelection {
  const CollectionSelection({
    required this.context,
    required this.files,
    this.mode = 'add',
    this.confirmed = false,
    this.confirmRemovals = false,
  });
  final CollectionContext context;
  final List<CollectionFile> files;
  final String mode;
  final bool confirmed, confirmRemovals;
  factory CollectionSelection.initial(
    ListeningExportSnapshot snapshot,
    CollectionContext context,
  ) => CollectionSelection(
    context: context,
    files: snapshot.playlists.map((p) {
      final matches = context.playlists
          .where((t) => t.fileHash == p.key)
          .toList();
      return CollectionFile(
        ordinal: p.ordinal,
        name: p.name,
        role: 'playlist',
        target: matches.length == 1 ? matches.single.key : null,
        createKey: 'exportify:${p.key}:${p.ordinal}',
        fileHash: p.key,
      );
    }).toList(),
  );
  CollectionSelection change({
    List<CollectionFile>? files,
    String? mode,
    bool? confirmed,
    bool? confirmRemovals,
  }) => CollectionSelection(
    context: context,
    files: files ?? this.files,
    mode: mode ?? this.mode,
    confirmed: confirmed ?? this.confirmed,
    confirmRemovals: confirmRemovals ?? this.confirmRemovals,
  );
  bool canUpload(ListeningExportSnapshot snapshot) {
    try {
      apply(snapshot);
      return true;
    } catch (_) {
      return false;
    }
  }

  ({
    ListeningExportSnapshot snapshot,
    Map<String, Object?> libraryReview,
    List<Map<String, Object?>> playlistReview,
  })
  apply(ListeningExportSnapshot original) {
    if (!confirmed || files.where((f) => f.role == 'liked').length > 1) {
      throw const FormatException('Review collection roles.');
    }
    final library = {for (final row in original.library) row.platformId: row};
    final playlists = <SnapshotPlaylist>[],
        review = <Map<String, Object?>>[],
        keys = <String>{};
    for (final file in files) {
      if (file.role == 'skip') continue;
      final p = original.playlists.firstWhere((p) => p.ordinal == file.ordinal);
      if (file.role == 'liked') {
        for (final e in p.entries) {
          if (e.platformId != null) {
            library[e.platformId!] = SnapshotLibraryRow(
              platformId: e.platformId!,
              dateAdded: e.addedAt ?? library[e.platformId!]?.dateAdded,
            );
          }
        }
      } else {
        final target = file.target == null
            ? null
            : context.playlists.firstWhere((t) => t.key == file.target);
        final key = target?.key ?? file.createKey;
        if (!keys.add(key) ||
            file.name.trim().isEmpty ||
            file.name.length > 500) {
          throw const FormatException(
            'Choose distinct playlists and valid names.',
          );
        }
        playlists.add(
          SnapshotPlaylist(
            ordinal: playlists.length,
            key: key,
            name: file.name.trim(),
            description: p.description,
            lastModifiedAt: p.lastModifiedAt,
            entries: p.entries,
          ),
        );
        review.add({
          'key': key,
          'baseFingerprint': target?.fingerprint,
          'fileHash': file.fileHash,
        });
      }
    }
    final hasLikes =
        original.package == ExportPackage.spotifyAccount ||
        files.any((f) => f.role == 'liked');
    if ((!hasLikes && playlists.isEmpty) ||
        (original.package == ExportPackage.spotifyExportify &&
            library.isEmpty &&
            playlists.every((p) => p.entries.isEmpty))) {
      throw const FormatException('Choose a collection.');
    }
    if (mode == 'replace' && hasLikes && !confirmRemovals) {
      throw const FormatException('Confirm replacing Liked Songs.');
    }
    final ids = {
      ...library.keys,
      ...playlists
          .expand((p) => p.entries)
          .map((e) => e.platformId)
          .whereType<String>(),
    };
    return (
      snapshot: ListeningExportSnapshot(
        package: original.package,
        timeZone: original.timeZone,
        country: original.country,
        tracks: original.tracks
            .where((t) => ids.contains(t.platformId))
            .toList(),
        days: original.days,
        library: library.values.toList(),
        artists: original.artists,
        playlists: playlists,
        unresolved: original.package == ExportPackage.spotifyExportify
            ? SnapshotUnresolved(
                rows: original.playlists
                    .where(
                      (p) => files.any(
                        (f) => f.ordinal == p.ordinal && f.role != 'skip',
                      ),
                    )
                    .expand((p) => p.entries)
                    .where((e) => e.platformId == null)
                    .length,
                plays: 0,
              )
            : original.unresolved,
        ledgerFrom: original.ledgerFrom,
        ledgerTo: original.ledgerTo,
      ),
      libraryReview: mode == 'replace' && hasLikes
          ? {'mode': 'replace', 'fingerprint': context.fingerprint}
          : {'mode': 'add'},
      playlistReview: review,
    );
  }
}
