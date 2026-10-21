/// DJ conversation domain models — mirrors the P3a server contract in
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`. Manual `fromJson`
/// (no codegen), matching the rest of the data layer.
library;

import '../playlists/playlist_context_models.dart';

/// Which loop, read shape and routes a session takes (server
/// `dj_sessions.kind`). An older server omits it; anything unknown reads as
/// a mix, the shape every client already understands.
enum SessionKind {
  mix,
  album;

  static SessionKind fromWire(Object? value) =>
      value == 'album' ? SessionKind.album : SessionKind.mix;
}

/// Album artwork as the server sends it: an Apple URL template
/// (`{w}x{h}`) plus the optional source size and background colour.
class AlbumArtwork {
  const AlbumArtwork({
    required this.url,
    this.width,
    this.height,
    this.bgColor,
  });

  final String url;
  final int? width;
  final int? height;
  final String? bgColor;

  factory AlbumArtwork.fromJson(Map<String, dynamic> json) => AlbumArtwork(
    url: json['url'] as String,
    width: json['width'] as int?,
    height: json['height'] as int?,
    bgColor: json['bgColor'] as String?,
  );

  static AlbumArtwork? maybe(Object? json) =>
      json == null ? null : AlbumArtwork.fromJson(json as Map<String, dynamic>);
}

/// The current pick an album row shows in the Mixes list (`GET /sessions`
/// → `pick`, album rows only; null before the first pick).
class AlbumSummary {
  const AlbumSummary({required this.title, required this.artist, this.artwork});

  final String title;
  final String artist;
  final AlbumArtwork? artwork;

  factory AlbumSummary.fromJson(Map<String, dynamic> json) => AlbumSummary(
    title: json['title'] as String,
    artist: json['artist'] as String,
    artwork: AlbumArtwork.maybe(json['artwork']),
  );
}

class DjSession {
  const DjSession({
    required this.id,
    required this.title,
    required this.status,
    required this.queueVersion,
    required this.updatedAt,
    this.notPersonal = false,
    this.caseColor,
    this.kind = SessionKind.mix,
    this.pick,
  });

  final String? caseColor;
  final String id;
  final String title;
  final String status; // 'active' | 'archived'
  final int queueVersion;
  final DateTime updatedAt;

  /// True once a corpus-mode generate/swap put shared-catalog picks in this
  /// session's queue (server routes/sessions.ts → sessionListColumns). Every
  /// session summary carries it; the "Not personal yet" banner reads it.
  /// Absent on the wire (older server) reads as false.
  final bool notPersonal;

  /// Mix or album. For an album session [queueVersion] is the pick version.
  final SessionKind kind;

  /// Album rows in `GET /sessions` only: the current pick, for the Mixes
  /// list. Null for mixes, for an album before its first pick, and on every
  /// other read (session detail, PATCH echoes).
  final AlbumSummary? pick;

  /// The one way to change a session in place, so a new field can never be
  /// silently dropped by a hand-rolled rebuild.
  DjSession copyWith({
    String? id,
    String? title,
    String? status,
    int? queueVersion,
    DateTime? updatedAt,
    bool? notPersonal,
    String? caseColor,
    SessionKind? kind,
    AlbumSummary? pick,
  }) => DjSession(
    id: id ?? this.id,
    title: title ?? this.title,
    status: status ?? this.status,
    queueVersion: queueVersion ?? this.queueVersion,
    updatedAt: updatedAt ?? this.updatedAt,
    notPersonal: notPersonal ?? this.notPersonal,
    caseColor: caseColor ?? this.caseColor,
    kind: kind ?? this.kind,
    pick: pick ?? this.pick,
  );

  factory DjSession.fromJson(Map<String, dynamic> json) => DjSession(
    caseColor: json['caseColor'] as String?,
    id: json['id'] as String,
    title: json['title'] as String,
    status: json['status'] as String,
    queueVersion: json['queueVersion'] as int,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    notPersonal: json['notPersonal'] as bool? ?? false,
    kind: SessionKind.fromWire(json['kind']),
    pick: json['pick'] == null
        ? null
        : AlbumSummary.fromJson(json['pick'] as Map<String, dynamic>),
  );
}

/// The display word for an album's release type. Known types have their own
/// casing (EP); a type a newer server added is shown as given, capitalised.
String albumTypeLabel(String type) => switch (type) {
  'album' => 'Album',
  'ep' => 'EP',
  'single' => 'Single',
  'live' => 'Live',
  'compilation' => 'Compilation',
  'soundtrack' => 'Soundtrack',
  'mixtape' => 'Mixtape',
  '' => '',
  _ => '${type[0].toUpperCase()}${type.substring(1)}',
};

/// One album the DJ offered (server `AlbumView`): the pick, a runner-up, or
/// a passed-over pick from an earlier version.
class AlbumPick {
  const AlbumPick({
    required this.id,
    required this.title,
    required this.artist,
    required this.type,
    required this.newToThem,
    required this.reason,
    required this.savedForLater,
    required this.version,
    this.upc,
    this.appleId,
    this.releaseYear,
    this.trackCount,
    this.durationMs,
    this.artwork,
  });

  final String id;
  final String? upc;
  final String? appleId;
  final String title;
  final String artist;
  final int? releaseYear;

  /// The raw wire type (album, ep, single, live, compilation, soundtrack,
  /// mixtape, or something newer); see [typeLabel].
  final String type;
  final int? trackCount;
  final int? durationMs;
  final AlbumArtwork? artwork;
  final bool newToThem;

  /// The DJ's "why".
  final String reason;
  final bool savedForLater;

  /// The pick version this album was offered in.
  final int version;

  String get typeLabel => albumTypeLabel(type);

  AlbumPick copyWith({bool? savedForLater}) => AlbumPick(
    id: id,
    upc: upc,
    appleId: appleId,
    title: title,
    artist: artist,
    releaseYear: releaseYear,
    type: type,
    trackCount: trackCount,
    durationMs: durationMs,
    artwork: artwork,
    newToThem: newToThem,
    reason: reason,
    savedForLater: savedForLater ?? this.savedForLater,
    version: version,
  );

  factory AlbumPick.fromJson(Map<String, dynamic> json) => AlbumPick(
    id: json['id'] as String,
    upc: json['upc'] as String?,
    appleId: json['appleId'] as String?,
    title: json['title'] as String,
    artist: json['artist'] as String,
    releaseYear: json['releaseYear'] as int?,
    type: json['type'] as String? ?? '',
    trackCount: json['trackCount'] as int?,
    durationMs: json['durationMs'] as int?,
    artwork: AlbumArtwork.maybe(json['artwork']),
    newToThem: json['newToThem'] as bool? ?? false,
    reason: json['reason'] as String? ?? '',
    savedForLater: json['savedForLater'] as bool? ?? false,
    version: json['version'] as int? ?? 0,
  );
}

List<AlbumPick> _albumPicksFromJson(Object? json) => json == null
    ? const []
    : (json as List)
          .map((a) => AlbumPick.fromJson(a as Map<String, dynamic>))
          .toList();

/// An album session's current shortlist (server `AlbumPickState`): every
/// response that touches the pick carries all four together. [version] is
/// the session's queueVersion for an album session.
class AlbumPickState {
  const AlbumPickState({
    required this.version,
    this.pick,
    this.runnersUp = const [],
    this.passed = const [],
  });

  final int version;
  final AlbumPick? pick;
  final List<AlbumPick> runnersUp;
  final List<AlbumPick> passed;

  /// Sets [AlbumPick.savedForLater] on every appearance of [albumId] (the
  /// same album can be the pick and also sit in the passed-over history).
  AlbumPickState withSavedForLater(String albumId, bool saved) {
    AlbumPick mark(AlbumPick a) =>
        a.id == albumId ? a.copyWith(savedForLater: saved) : a;
    return AlbumPickState(
      version: version,
      pick: pick == null ? null : mark(pick!),
      runnersUp: runnersUp.map(mark).toList(),
      passed: passed.map(mark).toList(),
    );
  }

  /// Tolerant of absent keys: no pick, empty lists, version 0.
  factory AlbumPickState.fromJson(Map<String, dynamic> json) => AlbumPickState(
    version: json['version'] as int? ?? 0,
    pick: json['pick'] == null
        ? null
        : AlbumPick.fromJson(json['pick'] as Map<String, dynamic>),
    runnersUp: _albumPicksFromJson(json['runnersUp']),
    passed: _albumPicksFromJson(json['passed']),
  );
}

/// Whether a response body carries an album pick state (album turns, album
/// session reads, album error bodies).
bool _hasPickState(Map<String, dynamic> json) =>
    json.containsKey('pick') ||
    json.containsKey('runnersUp') ||
    json.containsKey('passed');

List<String>? _suggestionsFromJson(Object? json) =>
    json == null ? null : (json as List).cast<String>().toList();

/// One album on the listener's Listen later shelf (`GET /me/listen-later`).
class ListenLaterEntry {
  const ListenLaterEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.type,
    required this.savedAt,
    this.upc,
    this.appleId,
    this.releaseYear,
    this.trackCount,
    this.durationMs,
    this.artwork,
    this.sessionId,
    this.listenedAt,
    this.reason,
  });

  /// The album id.
  final String id;
  final String? upc;
  final String? appleId;
  final String title;
  final String artist;
  final int? releaseYear;
  final String type;
  final int? trackCount;
  final int? durationMs;
  final AlbumArtwork? artwork;

  /// The album session it was saved from, if any.
  final String? sessionId;
  final DateTime savedAt;
  final DateTime? listenedAt;

  /// The DJ's "why" in the session it came from; null without one.
  final String? reason;

  bool get listened => listenedAt != null;
  String get typeLabel => albumTypeLabel(type);

  factory ListenLaterEntry.fromJson(Map<String, dynamic> json) =>
      ListenLaterEntry(
        id: json['id'] as String,
        upc: json['upc'] as String?,
        appleId: json['appleId'] as String?,
        title: json['title'] as String,
        artist: json['artist'] as String,
        releaseYear: json['releaseYear'] as int?,
        type: json['type'] as String? ?? '',
        trackCount: json['trackCount'] as int?,
        durationMs: json['durationMs'] as int?,
        artwork: AlbumArtwork.maybe(json['artwork']),
        sessionId: json['sessionId'] as String?,
        savedAt: DateTime.parse(json['savedAt'] as String),
        listenedAt: json['listenedAt'] == null
            ? null
            : DateTime.parse(json['listenedAt'] as String),
        reason: json['reason'] as String?,
      );
}

class DjMessage {
  const DjMessage({
    required this.id,
    required this.role,
    required this.content,
    this.queueVersion,
    required this.createdAt,
  });

  final String id;
  final String role; // 'user' | 'dj'
  final String content;
  final int? queueVersion;
  final DateTime createdAt;

  factory DjMessage.fromJson(Map<String, dynamic> json) => DjMessage(
    id: json['id'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    queueVersion: json['queueVersion'] as int?,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class QueueTrack {
  const QueueTrack({
    required this.position,
    required this.trackId,
    required this.appleId,
    required this.title,
    required this.artist,
    this.spotifyId,
    this.reason,
    this.durationMs,
    this.artworkUrl,
    this.artworkWidth,
    this.artworkHeight,
    this.artworkBgColor,
    this.newToYou = false,
  });

  final int position;
  final String trackId;
  // Nullable: a queued track's Apple Music match can be absent server-side
  // (tracks.apple_id is a nullable column) even though the happy-path
  // playback/playlist flow always expects one.
  final String? appleId;
  final String title;
  final String artist;
  // Peer of appleId, never a replacement (tracks.spotify_id): present for
  // tracks that came in through a Spotify export or a pasted seed, and what
  // the "Open in Spotify" output actions key on.
  final String? spotifyId;
  final String? reason;
  final int? durationMs;
  final String? artworkUrl;
  final int? artworkWidth;
  final int? artworkHeight;
  final String? artworkBgColor;
  // A pick from outside the listener's library. The server already sends
  // false for not-personal sessions, so the clients render it as given; an
  // older server omits it.
  final bool newToYou;

  factory QueueTrack.fromJson(Map<String, dynamic> json) => QueueTrack(
    position: json['position'] as int,
    trackId: json['trackId'] as String,
    appleId: json['appleId'] as String?,
    title: json['title'] as String,
    artist: json['artist'] as String,
    spotifyId: json['spotifyId'] as String?,
    reason: json['reason'] as String?,
    durationMs: json['durationMs'] as int?,
    artworkUrl: json['artworkUrl'] as String?,
    artworkWidth: json['artworkWidth'] as int?,
    artworkHeight: json['artworkHeight'] as int?,
    artworkBgColor: json['artworkBgColor'] as String?,
    newToYou: json['newToYou'] as bool? ?? false,
  );
}

/// Shared by every response shape that embeds a queue snapshot (session
/// detail, turn results, queue-ops results, and DJ error bodies).
List<QueueTrack> queueTracksFromJson(Object? json) => (json as List)
    .map((q) => QueueTrack.fromJson(q as Map<String, dynamic>))
    .toList();

/// For bodies whose queue is absent for album sessions (session detail, turn
/// results): no key reads as an empty queue. A present-but-null queue is
/// still a drift error, as before.
List<QueueTrack> _optionalQueue(Map<String, dynamic> json) =>
    json.containsKey('queue') ? queueTracksFromJson(json['queue']) : const [];

class SessionDetail {
  const SessionDetail({
    required this.session,
    required this.messages,
    required this.queue,
    this.sessionTitle,
    this.playlistSeed,
    this.supportsInsert = false,
    this.pickState,
    this.suggestions,
  });

  SessionKind get kind => session.kind;

  /// Album sessions only: the current shortlist. Their reads carry no queue.
  final AlbumPickState? pickState;

  /// An album create whose first turn failed honestly: refinement pills.
  final List<String>? suggestions;

  /// Missing legacy field is unknown rather than a synthetic empty seed.
  final PlaylistSeedState? playlistSeed;
  final DjSession session;
  final List<DjMessage> messages;
  final List<QueueTrack> queue;

  /// Present only on a create-session response whose very first turn called
  /// `rename_session` (see the server's routes/sessions.ts) — [session.title]
  /// already reflects this same value in that case, so most callers have no
  /// need of this field; it exists for parity with [TurnResult]'s own.
  final String? sessionTitle;

  /// Whether this server understands the `insert` queue op — a CAPABILITY
  /// flag, not session state (server: `routes/sessions.ts`). The arrangement
  /// screen offers Undo on a swipe-remove only when it is true, so a client
  /// talking to an older deploy (which never sends the key) simply never
  /// shows an affordance the server would reject.
  final bool supportsInsert;

  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final session = DjSession.fromJson(json['session'] as Map<String, dynamic>);
    return SessionDetail(
      session: session,
      messages: (json['messages'] as List)
          .map((m) => DjMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
      queue: _optionalQueue(json),
      pickState: session.kind == SessionKind.album || _hasPickState(json)
          ? AlbumPickState.fromJson(json)
          : null,
      suggestions: _suggestionsFromJson(json['suggestions']),
      sessionTitle: json['sessionTitle'] as String?,
      supportsInsert: json['supportsInsert'] as bool? ?? false,
      playlistSeed: json.containsKey('playlistSeed')
          ? PlaylistSeedState.fromJson(
              playlistContextObject(json['playlistSeed']),
            )
          : null,
    );
  }
}

class TurnResult {
  const TurnResult({
    required this.djMessage,
    required this.queue,
    required this.queueVersion,
    this.sessionTitle,
    this.pickState,
    this.suggestions,
  });

  /// Album turns only: the shortlist after this turn. [queueVersion] is its
  /// version (the server's `version`), and [queue] is empty.
  final AlbumPickState? pickState;

  /// An album turn that failed honestly: refinement pills, else null.
  final List<String>? suggestions;

  final DjMessage djMessage;
  final List<QueueTrack> queue;
  final int queueVersion;

  /// Present ONLY when the DJ renamed the session (via the `rename_session`
  /// tool) during this very turn — see `dj_providers.dart`'s ChatNotifier,
  /// which adopts it into the cached session title without a refetch.
  final String? sessionTitle;

  factory TurnResult.fromJson(Map<String, dynamic> json) => TurnResult(
    djMessage: DjMessage.fromJson(json['djMessage'] as Map<String, dynamic>),
    queue: _optionalQueue(json),
    queueVersion: (json['queueVersion'] ?? json['version']) as int,
    sessionTitle: json['sessionTitle'] as String?,
    pickState: _hasPickState(json) ? AlbumPickState.fromJson(json) : null,
    suggestions: _suggestionsFromJson(json['suggestions']),
  );
}

class QueueOpsResult {
  const QueueOpsResult({
    required this.queueVersion,
    required this.requested,
    required this.added,
    required this.removed,
    required this.queue,
  });

  final int queueVersion;
  final int requested;
  final int added;
  final int removed;
  final List<QueueTrack> queue;

  factory QueueOpsResult.fromJson(Map<String, dynamic> json) => QueueOpsResult(
    queueVersion: json['queueVersion'] as int,
    requested: json['requested'] as int,
    added: json['added'] as int,
    removed: json['removed'] as int,
    queue: queueTracksFromJson(json['queue']),
  );
}

/// A durable per-user taste note the DJ saved via `remember_preference` (see
/// `docs/superpowers/plans/2026-08-30-p4-taste-learning.md` Task 2/4).
/// `GET /me/memories` returns these newest-first; DELETE is hard — a
/// forgotten note is gone for good, there's no restore server-side.
class DjMemory {
  const DjMemory({
    required this.id,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String note;
  final DateTime createdAt;

  factory DjMemory.fromJson(Map<String, dynamic> json) => DjMemory(
    id: json['id'] as String,
    note: json['note'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// Manual queue-ops are remove/move/insert (0-based positions) — swap/extend
/// need the DJ and are rejected by the server with a 400 `dj_required`.
sealed class QueueOp {
  const QueueOp();

  const factory QueueOp.remove(int position) = _RemoveOp;
  const factory QueueOp.move(int from, int to) = _MoveOp;

  /// Puts a track the user just removed back where it was — the arrangement
  /// screen's Undo (`docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`).
  /// Manual-only: the DJ never sees track ids, so it is absent from the
  /// model's own edit_queue schema. [position] is clamped server-side to
  /// `[0, length]`, so an Undo can't fail on an off-by-one.
  const factory QueueOp.insert(int position, String trackId) = _InsertOp;

  Map<String, dynamic> toJson();
}

class _RemoveOp extends QueueOp {
  const _RemoveOp(this.position);
  final int position;

  @override
  Map<String, dynamic> toJson() => {'op': 'remove', 'position': position};
}

class _InsertOp extends QueueOp {
  const _InsertOp(this.position, this.trackId);
  final int position;
  final String trackId;

  @override
  Map<String, dynamic> toJson() => {
    'op': 'insert',
    'position': position,
    'trackId': trackId,
  };
}

class _MoveOp extends QueueOp {
  const _MoveOp(this.from, this.to);
  final int from;
  final int to;

  @override
  Map<String, dynamic> toJson() => {'op': 'move', 'from': from, 'to': to};
}
