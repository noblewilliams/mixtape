class PlaylistEditModelException implements Exception {
  const PlaylistEditModelException();

  @override
  String toString() => 'PlaylistEditModelException';
}

class PlaylistEditDraft {
  const PlaylistEditDraft({
    required this.id,
    required this.sourcePlaylistId,
    required this.status,
    required this.version,
    required this.baseSourceFingerprint,
    required this.baseName,
    required this.sourceType,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlaylistEditDraft.fromJson(Map<String, dynamic> json) =>
      PlaylistEditDraft(
        id: _string(json['id']),
        sourcePlaylistId: _string(json['sourcePlaylistId']),
        status: _string(json['status']),
        version: _nonnegativeInt(json['version']),
        baseSourceFingerprint: _string(json['baseSourceFingerprint']),
        baseName: _string(json['baseName']),
        sourceType: _oneOf(json['sourceType'], const {
          'apple',
          'spotify_export',
        }),
        createdAt: _date(json['createdAt']),
        updatedAt: _date(json['updatedAt']),
      );

  final String id;
  final String sourcePlaylistId;
  final String status;
  final int version;
  final String baseSourceFingerprint;
  final String baseName;
  final String sourceType;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class PlaylistEditEntry {
  const PlaylistEditEntry({
    required this.entryKey,
    required this.origin,
    required this.title,
    required this.artist,
    required this.position,
    required this.resolved,
    this.sourceEntryId,
    this.trackId,
    this.appleLibraryTrackId,
    this.appleCatalogId,
    this.spotifyId,
    this.album,
    this.durationMs,
    this.artworkUrlTemplate,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
  });

  factory PlaylistEditEntry.fromJson(Map<String, dynamic> json) =>
      PlaylistEditEntry(
        entryKey: _string(json['entryKey']),
        origin: _oneOf(json['origin'], const {'source', 'catalog_addition'}),
        sourceEntryId: _optionalString(json['sourceEntryId']),
        trackId: _optionalString(json['trackId']),
        appleLibraryTrackId: _optionalString(json['appleLibraryTrackId']),
        appleCatalogId: _optionalString(json['appleCatalogId']),
        spotifyId: _optionalString(json['spotifyId']),
        title: _string(json['title']),
        artist: _string(json['artist']),
        album: _optionalString(json['album']),
        durationMs: _optionalNonnegativeInt(json['durationMs']),
        artworkUrlTemplate: _optionalString(json['artworkUrlTemplate']),
        artworkWidth: _optionalPositiveInt(json['artworkWidth']),
        artworkHeight: _optionalPositiveInt(json['artworkHeight']),
        artworkBgColor: _optionalHex(json['artworkBgColor']),
        position: _nonnegativeInt(json['position']),
        resolved: _bool(json['resolved']),
      );

  final String entryKey;
  final String origin;
  final String? sourceEntryId;
  final String? trackId;
  final String? appleLibraryTrackId;
  final String? appleCatalogId;
  final String? spotifyId;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artworkUrlTemplate;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  final int position;
  final bool resolved;
}

class PlaylistEditDiffEntry {
  const PlaylistEditDiffEntry({
    required this.entryKey,
    this.fromPosition,
    this.toPosition,
    this.position,
  });

  factory PlaylistEditDiffEntry.fromJson(Map<String, dynamic> json) =>
      PlaylistEditDiffEntry(
        entryKey: _string(json['entryKey']),
        fromPosition: _optionalNonnegativeInt(json['fromPosition']),
        toPosition: _optionalNonnegativeInt(json['toPosition']),
        position: _optionalNonnegativeInt(json['position']),
      );

  final String entryKey;
  final int? fromPosition;
  final int? toPosition;
  final int? position;
}

class PlaylistEditDiff {
  const PlaylistEditDiff({
    required this.added,
    required this.removed,
    required this.moved,
    required this.replaced,
  });

  factory PlaylistEditDiff.fromJson(Map<String, dynamic> json) {
    final added = _objects(
      json['added'],
    ).map(PlaylistEditDiffEntry.fromJson).toList();
    final removed = _objects(
      json['removed'],
    ).map(PlaylistEditDiffEntry.fromJson).toList();
    final moved = _objects(
      json['moved'],
    ).map(PlaylistEditDiffEntry.fromJson).toList();
    final replaced = _objects(
      json['replaced'],
    ).map(PlaylistEditDiffEntry.fromJson).toList();
    if (added.any((item) => item.toPosition == null) ||
        removed.any((item) => item.fromPosition == null) ||
        moved.any(
          (item) => item.fromPosition == null || item.toPosition == null,
        ) ||
        replaced.any((item) => item.position == null)) {
      throw const PlaylistEditModelException();
    }
    return PlaylistEditDiff(
      added: added,
      removed: removed,
      moved: moved,
      replaced: replaced,
    );
  }

  final List<PlaylistEditDiffEntry> added;
  final List<PlaylistEditDiffEntry> removed;
  final List<PlaylistEditDiffEntry> moved;
  final List<PlaylistEditDiffEntry> replaced;

  int get changeCount =>
      added.length + removed.length + moved.length + replaced.length;
}

class PlaylistEditReviewEntry {
  const PlaylistEditReviewEntry({
    required this.entryKey,
    required this.position,
    required this.title,
    required this.artist,
    required this.resolved,
    this.album,
    this.durationMs,
    this.artworkUrlTemplate,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
    this.fromPosition,
  });

  factory PlaylistEditReviewEntry.fromJson(Map<String, dynamic> json) =>
      PlaylistEditReviewEntry(
        entryKey: _string(json['entryKey']),
        position: _nonnegativeInt(json['position']),
        title: _string(json['title']),
        artist: _string(json['artist']),
        album: _optionalString(json['album']),
        durationMs: _optionalNonnegativeInt(json['durationMs']),
        artworkUrlTemplate: _optionalString(json['artworkUrlTemplate']),
        artworkWidth: _optionalPositiveInt(json['artworkWidth']),
        artworkHeight: _optionalPositiveInt(json['artworkHeight']),
        artworkBgColor: _optionalHex(json['artworkBgColor']),
        resolved: _bool(json['resolved']),
        fromPosition: _optionalNonnegativeInt(json['fromPosition']),
      );

  final String entryKey;
  final int position;
  final int? fromPosition;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? artworkUrlTemplate;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  final bool resolved;
}

class PlaylistEditReplacement {
  const PlaylistEditReplacement({required this.before, required this.after});

  factory PlaylistEditReplacement.fromJson(Map<String, dynamic> json) =>
      PlaylistEditReplacement(
        before: PlaylistEditReviewEntry.fromJson(_object(json['before'])),
        after: PlaylistEditReviewEntry.fromJson(_object(json['after'])),
      );

  final PlaylistEditReviewEntry before;
  final PlaylistEditReviewEntry after;
}

class PlaylistEditReview {
  const PlaylistEditReview({
    required this.added,
    required this.removed,
    required this.moved,
    required this.replaced,
  });

  factory PlaylistEditReview.fromJson(Map<String, dynamic> json) {
    final moved = _objects(
      json['moved'],
    ).map(PlaylistEditReviewEntry.fromJson).toList();
    if (moved.any((item) => item.fromPosition == null)) {
      throw const PlaylistEditModelException();
    }
    return PlaylistEditReview(
      added: _objects(
        json['added'],
      ).map(PlaylistEditReviewEntry.fromJson).toList(),
      removed: _objects(
        json['removed'],
      ).map(PlaylistEditReviewEntry.fromJson).toList(),
      moved: moved,
      replaced: _objects(
        json['replaced'],
      ).map(PlaylistEditReplacement.fromJson).toList(),
    );
  }

  final List<PlaylistEditReviewEntry> added;
  final List<PlaylistEditReviewEntry> removed;
  final List<PlaylistEditReviewEntry> moved;
  final List<PlaylistEditReplacement> replaced;
}

class PlaylistEditCapability {
  const PlaylistEditCapability({
    required this.possibleModes,
    required this.sourceWillRemainUntouched,
    required this.applyAvailable,
  });

  factory PlaylistEditCapability.fromJson(Map<String, dynamic> json) =>
      PlaylistEditCapability(
        possibleModes: _strings(json['possibleModes']),
        sourceWillRemainUntouched: _bool(json['sourceWillRemainUntouched']),
        applyAvailable: _bool(json['applyAvailable']),
      );

  final List<String> possibleModes;
  final bool sourceWillRemainUntouched;
  final bool applyAvailable;
}

class PlaylistEditMessage {
  const PlaylistEditMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.seq,
    required this.createdAt,
    this.draftVersion,
  });

  factory PlaylistEditMessage.fromJson(Map<String, dynamic> json) {
    final role = _oneOf(json['role'], const {'user', 'dj'});
    final draftVersion = _optionalNonnegativeInt(json['draftVersion']);
    if ((role == 'user' && draftVersion != null) ||
        (role == 'dj' && draftVersion == null)) {
      throw const PlaylistEditModelException();
    }
    return PlaylistEditMessage(
      id: _string(json['id']),
      role: role,
      content: _string(json['content']),
      draftVersion: draftVersion,
      seq: _nonnegativeInt(json['seq']),
      createdAt: _date(json['createdAt']),
    );
  }

  final String id;
  final String role;
  final String content;
  final int? draftVersion;
  final int seq;
  final DateTime createdAt;
}

class PlaylistEditView {
  const PlaylistEditView({
    required this.draft,
    required this.entries,
    required this.diff,
    required this.review,
    required this.capability,
  });

  factory PlaylistEditView.fromJson(
    Map<String, dynamic> json,
  ) => PlaylistEditView(
    draft: PlaylistEditDraft.fromJson(_object(json['draft'])),
    entries: _objects(json['entries']).map(PlaylistEditEntry.fromJson).toList(),
    diff: PlaylistEditDiff.fromJson(_object(json['diff'])),
    review: PlaylistEditReview.fromJson(_object(json['review'])),
    capability: PlaylistEditCapability.fromJson(_object(json['capability'])),
  );

  final PlaylistEditDraft draft;
  final List<PlaylistEditEntry> entries;
  final PlaylistEditDiff diff;
  final PlaylistEditReview review;
  final PlaylistEditCapability capability;
}

class PlaylistEditThread extends PlaylistEditView {
  const PlaylistEditThread({
    required super.draft,
    required super.entries,
    required super.diff,
    required super.review,
    required super.capability,
    required this.messages,
  });

  factory PlaylistEditThread.fromJson(Map<String, dynamic> json) {
    final view = PlaylistEditView.fromJson(json);
    return PlaylistEditThread(
      draft: view.draft,
      entries: view.entries,
      diff: view.diff,
      review: view.review,
      capability: view.capability,
      messages: _objects(
        json['messages'],
      ).map(PlaylistEditMessage.fromJson).toList(),
    );
  }

  final List<PlaylistEditMessage> messages;
}

class PlaylistEditTurnResult {
  const PlaylistEditTurnResult({required this.djMessage, required this.draft});

  factory PlaylistEditTurnResult.fromJson(Map<String, dynamic> json) =>
      PlaylistEditTurnResult(
        djMessage: PlaylistEditMessage.fromJson(_object(json['djMessage'])),
        draft: PlaylistEditView.fromJson(_object(json['draft'])),
      );

  final PlaylistEditMessage djMessage;
  final PlaylistEditView draft;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) throw const PlaylistEditModelException();
  return value;
}

List<Map<String, dynamic>> _objects(Object? value) {
  if (value is! List) throw const PlaylistEditModelException();
  return value.map(_object).toList(growable: false);
}

String _string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const PlaylistEditModelException();
  }
  return value;
}

String _oneOf(Object? value, Set<String> allowed) {
  final parsed = _string(value);
  if (!allowed.contains(parsed)) throw const PlaylistEditModelException();
  return parsed;
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _nonnegativeInt(Object? value) {
  if (value is! int || value < 0) throw const PlaylistEditModelException();
  return value;
}

int? _optionalNonnegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;
int? _optionalPositiveInt(Object? value) =>
    value is int && value > 0 ? value : null;

bool _bool(Object? value) {
  if (value is! bool) throw const PlaylistEditModelException();
  return value;
}

DateTime _date(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw const PlaylistEditModelException();
  return parsed;
}

String? _optionalHex(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{6}$').hasMatch(value) ? value : null;

List<String> _strings(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const PlaylistEditModelException();
  }
  return value.cast<String>().toList(growable: false);
}
