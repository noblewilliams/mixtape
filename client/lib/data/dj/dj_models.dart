/// DJ conversation domain models — mirrors the P3a server contract in
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`. Manual `fromJson`
/// (no codegen), matching the rest of the data layer.
library;

import '../playlists/playlist_context_models.dart';

class DjSession {
  const DjSession({
    required this.id,
    required this.title,
    required this.status,
    required this.queueVersion,
    required this.updatedAt,
    this.notPersonal = false,
    this.caseColor,
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

  factory DjSession.fromJson(Map<String, dynamic> json) => DjSession(
    caseColor: json['caseColor'] as String?,
    id: json['id'] as String,
    title: json['title'] as String,
    status: json['status'] as String,
    queueVersion: json['queueVersion'] as int,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    notPersonal: json['notPersonal'] as bool? ?? false,
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

class SessionDetail {
  const SessionDetail({
    required this.session,
    required this.messages,
    required this.queue,
    this.sessionTitle,
    this.playlistSeed,
    this.supportsInsert = false,
  });

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

  factory SessionDetail.fromJson(Map<String, dynamic> json) => SessionDetail(
    session: DjSession.fromJson(json['session'] as Map<String, dynamic>),
    messages: (json['messages'] as List)
        .map((m) => DjMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    queue: queueTracksFromJson(json['queue']),
    sessionTitle: json['sessionTitle'] as String?,
    supportsInsert: json['supportsInsert'] as bool? ?? false,
    playlistSeed: json.containsKey('playlistSeed')
        ? PlaylistSeedState.fromJson(
            playlistContextObject(json['playlistSeed']),
          )
        : null,
  );
}

class TurnResult {
  const TurnResult({
    required this.djMessage,
    required this.queue,
    required this.queueVersion,
    this.sessionTitle,
  });

  final DjMessage djMessage;
  final List<QueueTrack> queue;
  final int queueVersion;

  /// Present ONLY when the DJ renamed the session (via the `rename_session`
  /// tool) during this very turn — see `dj_providers.dart`'s ChatNotifier,
  /// which adopts it into the cached session title without a refetch.
  final String? sessionTitle;

  factory TurnResult.fromJson(Map<String, dynamic> json) => TurnResult(
    djMessage: DjMessage.fromJson(json['djMessage'] as Map<String, dynamic>),
    queue: queueTracksFromJson(json['queue']),
    queueVersion: json['queueVersion'] as int,
    sessionTitle: json['sessionTitle'] as String?,
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
