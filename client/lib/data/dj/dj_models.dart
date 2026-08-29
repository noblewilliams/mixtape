/// DJ conversation domain models — mirrors the P3a server contract in
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md`. Manual `fromJson`
/// (no codegen), matching the rest of the data layer.
library;

class DjSession {
  const DjSession({
    required this.id,
    required this.title,
    required this.status,
    required this.queueVersion,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String status; // 'active' | 'archived'
  final int queueVersion;
  final DateTime updatedAt;

  factory DjSession.fromJson(Map<String, dynamic> json) => DjSession(
        id: json['id'] as String,
        title: json['title'] as String,
        status: json['status'] as String,
        queueVersion: json['queueVersion'] as int,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
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
    this.reason,
    this.durationMs,
  });

  final int position;
  final String trackId;
  // Nullable: a queued track's Apple Music match can be absent server-side
  // (tracks.apple_id is a nullable column) even though the happy-path
  // playback/playlist flow always expects one.
  final String? appleId;
  final String title;
  final String artist;
  final String? reason;
  final int? durationMs;

  factory QueueTrack.fromJson(Map<String, dynamic> json) => QueueTrack(
        position: json['position'] as int,
        trackId: json['trackId'] as String,
        appleId: json['appleId'] as String?,
        title: json['title'] as String,
        artist: json['artist'] as String,
        reason: json['reason'] as String?,
        durationMs: json['durationMs'] as int?,
      );
}

/// Shared by every response shape that embeds a queue snapshot (session
/// detail, turn results, queue-ops results, and DJ error bodies).
List<QueueTrack> queueTracksFromJson(Object? json) =>
    (json as List).map((q) => QueueTrack.fromJson(q as Map<String, dynamic>)).toList();

class SessionDetail {
  const SessionDetail({required this.session, required this.messages, required this.queue});

  final DjSession session;
  final List<DjMessage> messages;
  final List<QueueTrack> queue;

  factory SessionDetail.fromJson(Map<String, dynamic> json) => SessionDetail(
        session: DjSession.fromJson(json['session'] as Map<String, dynamic>),
        messages: (json['messages'] as List)
            .map((m) => DjMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        queue: queueTracksFromJson(json['queue']),
      );
}

class TurnResult {
  const TurnResult({required this.djMessage, required this.queue, required this.queueVersion});

  final DjMessage djMessage;
  final List<QueueTrack> queue;
  final int queueVersion;

  factory TurnResult.fromJson(Map<String, dynamic> json) => TurnResult(
        djMessage: DjMessage.fromJson(json['djMessage'] as Map<String, dynamic>),
        queue: queueTracksFromJson(json['queue']),
        queueVersion: json['queueVersion'] as int,
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

/// Manual queue-ops are remove/move only (0-based positions) — swap/extend
/// need the DJ and are rejected by the server with a 400 `dj_required`.
sealed class QueueOp {
  const QueueOp();

  const factory QueueOp.remove(int position) = _RemoveOp;
  const factory QueueOp.move(int from, int to) = _MoveOp;

  Map<String, dynamic> toJson();
}

class _RemoveOp extends QueueOp {
  const _RemoveOp(this.position);
  final int position;

  @override
  Map<String, dynamic> toJson() => {'op': 'remove', 'position': position};
}

class _MoveOp extends QueueOp {
  const _MoveOp(this.from, this.to);
  final int from;
  final int to;

  @override
  Map<String, dynamic> toJson() => {'op': 'move', 'from': from, 'to': to};
}
