import 'dart:async';
import 'dart:convert';

import '../api/api_client.dart';

/// The streamed mix turn (spec: `docs/superpowers/specs/
/// 2026-11-13-dj-turn-steps-design.md`, "Wire contract"): SSE framing over
/// the response body of `POST /sessions` and `POST /sessions/:id/messages`
/// when the client asked with `Accept: text/event-stream`.
///
/// The server sends `session` (create only, first), any number of `step`
/// events, then exactly one of `result` (today's success body) or `error`
/// (`{status, body}`: today's status and error body), with `: keepalive`
/// comments between. A stream that ends before `result` or `error` is a
/// dropped connection.

/// One server-sent event: its name (`message` when the event had no
/// `event:` line) and its data lines joined with `\n`.
class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final String data;

  @override
  bool operator ==(Object other) =>
      other is SseEvent && other.event == event && other.data == data;

  @override
  int get hashCode => Object.hash(event, data);

  @override
  String toString() => 'SseEvent($event, $data)';
}

/// Decodes [bytes] as server-sent events.
///
/// Bytes decode as UTF-8 across chunk boundaries (a chunk may end inside a
/// character; a malformed sequence becomes U+FFFD rather than an error).
/// Lines end in LF, CRLF or CR. Lines starting with `:` are comments; `id`,
/// `retry` and unknown fields are ignored. An event is dispatched on its
/// blank line, so an event cut off by the end of [bytes] is never
/// dispatched. Errors from [bytes] pass through.
Stream<SseEvent> decodeSse(Stream<List<int>> bytes) async* {
  var name = '';
  final data = StringBuffer();
  var hasData = false;
  await for (final line
      in bytes
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) {
        yield SseEvent(name.isEmpty ? 'message' : name, data.toString());
      }
      name = '';
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        name = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
    }
  }
}

/// What a streamed turn reports while it runs. The final answer is not
/// progress: it is the call's return value or exception, as today.
sealed class TurnProgress {
  const TurnProgress();
}

/// The server answered with a stream (an older server, a refusal or an
/// album answers JSON and never sends this). Clients stop their timed
/// captions here and hold "listening" until the first [TurnStep].
final class TurnStreamOpened extends TurnProgress {
  const TurnStreamOpened();

  @override
  bool operator ==(Object other) => other is TurnStreamOpened;

  @override
  int get hashCode => (TurnStreamOpened).hashCode;

  @override
  String toString() => 'TurnStreamOpened()';
}

/// The create stream's `session` event: the new session's id, known before
/// the turn finishes.
final class TurnSessionStarted extends TurnProgress {
  const TurnSessionStarted(this.sessionId);

  final String sessionId;

  /// The `session` event's data, or null when it carries no session id.
  static TurnSessionStarted? fromJson(Object? json) {
    if (json is! Map) return null;
    final session = json['session'];
    if (session is! Map) return null;
    final id = session['id'];
    return id is String && id.isNotEmpty ? TurnSessionStarted(id) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is TurnSessionStarted && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;

  @override
  String toString() => 'TurnSessionStarted($sessionId)';
}

/// A `step` event: the DJ started a new kind of work.
///
/// [step] stays a raw string: the server may add steps, and a client
/// ignores one it does not know. The name fields are optional and only
/// ever names the listener already said or sees (spec, "Names"); render
/// them as plain text.
final class TurnStep extends TurnProgress {
  const TurnStep(
    this.step, {
    this.scope,
    this.artists,
    this.genres,
    this.playlist,
    this.title,
    this.count,
  });

  /// `listening`, `playlists`, `digging`, `picking`, `checking`, `editing`,
  /// `pressing`, `labelling`, `noting`, `writing`, or one added later.
  final String step;

  /// `library` or `catalogue` on `digging`.
  final String? scope;

  /// On `digging` and `picking`: the artists the brief named.
  final List<String>? artists;

  /// On the genre sound check (`checking`).
  final List<String>? genres;

  /// On `playlists`: the chosen playlist's name.
  final String? playlist;

  /// On `labelling`: the mix's new title.
  final String? title;

  /// On `pressing`: how many songs the queue now holds.
  final int? count;

  /// The `step` event's data, or null when it has no string `step`. A
  /// missing or mistyped name field is dropped, never thrown.
  static TurnStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final step = json['step'];
    if (step is! String || step.isEmpty) return null;
    final count = json['count'];
    return TurnStep(
      step,
      scope: _string(json['scope']),
      artists: _names(json['artists']),
      genres: _names(json['genres']),
      playlist: _string(json['playlist']),
      title: _string(json['title']),
      count: count is int ? count : null,
    );
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  /// Keeps the non-blank strings; null when none are left.
  static List<String>? _names(Object? value) {
    if (value is! List) return null;
    final names = [
      for (final name in value)
        if (_string(name) case final String kept) kept,
    ];
    return names.isEmpty ? null : List.unmodifiable(names);
  }

  @override
  bool operator ==(Object other) =>
      other is TurnStep &&
      other.step == step &&
      other.scope == scope &&
      _sameList(other.artists, artists) &&
      _sameList(other.genres, genres) &&
      other.playlist == playlist &&
      other.title == title &&
      other.count == count;

  @override
  int get hashCode => Object.hash(
    step,
    scope,
    artists == null ? null : Object.hashAll(artists!),
    genres == null ? null : Object.hashAll(genres!),
    playlist,
    title,
    count,
  );

  @override
  String toString() =>
      'TurnStep($step, scope: $scope, artists: $artists, genres: $genres, '
      'playlist: $playlist, title: $title, count: $count)';
}

bool _sameList(List<String>? a, List<String>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// How a streamed turn ended.
sealed class TurnStreamEnd {
  const TurnStreamEnd();
}

/// The `result` event: today's success body, as text.
final class TurnStreamResult extends TurnStreamEnd {
  const TurnStreamResult(this.body);

  final String body;
}

/// The `error` event: today's status, and today's error body as text (JSON
/// re-encoded from the event, or the event's string body as it is).
final class TurnStreamError extends TurnStreamEnd {
  const TurnStreamError(this.status, this.body);

  final int status;
  final String body;
}

/// An `error` event whose data has no integer status.
final class TurnStreamMalformed extends TurnStreamEnd {
  const TurnStreamMalformed();
}

/// Reads a streamed turn from [bytes]: hands each `session` and `step`
/// event to [onProgress] as it arrives, and answers with the `result` or
/// `error` event as soon as it arrives (the rest of [bytes] is not read).
/// Unknown events, and `session` or `step` events that do not parse, are
/// skipped.
///
/// [onProgress] is called synchronously and is not guarded: the caller
/// passes one that does not throw. Throws [NetworkException] when [bytes]
/// ends before a `result` or `error` event; errors from [bytes] pass
/// through.
Future<TurnStreamEnd> readTurnStream(
  Stream<List<int>> bytes,
  void Function(TurnProgress progress) onProgress,
) async {
  await for (final event in decodeSse(bytes)) {
    switch (event.event) {
      case 'session':
        if (TurnSessionStarted.fromJson(_tryDecode(event.data))
            case final started?) {
          onProgress(started);
        }
      case 'step':
        if (TurnStep.fromJson(_tryDecode(event.data)) case final step?) {
          onProgress(step);
        }
      case 'result':
        return TurnStreamResult(event.data);
      case 'error':
        return _errorEnd(_tryDecode(event.data));
    }
  }
  throw NetworkException(
    'The turn stream ended before its result or error event.',
  );
}

TurnStreamEnd _errorEnd(Object? data) {
  if (data is! Map) return const TurnStreamMalformed();
  final status = data['status'];
  if (status is! int) return const TurnStreamMalformed();
  final body = data['body'];
  return TurnStreamError(status, switch (body) {
    null => '',
    final String text => text,
    _ => jsonEncode(body),
  });
}

Object? _tryDecode(String data) {
  try {
    return jsonDecode(data);
  } on FormatException {
    return null;
  }
}
