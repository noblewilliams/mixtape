import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api/api_client.dart';
import '../auth/token_store.dart';
import 'dj_models.dart';

/// Thrown for DJ-domain errors the server distinguishes with a `kind` (its
/// `error` field): 502 (upstream LLM/curation hiccup) and 409 'conflict'
/// turn failures, plus both 400 shapes (queue-ops validation, dj_required,
/// zod). `message` is always safe to render verbatim — server-side these are
/// documented as "listener-ready" apology copy. `queue`/`queueVersion` are
/// attached when the body carried a fresher snapshot (a failed turn can
/// still have mutated the queue). `sessionId` is present only for a
/// create-session failure whose session row persisted despite the error
/// (POST /sessions echoes it so the caller can still navigate to it).
class DjApiException implements Exception {
  DjApiException({
    required this.kind,
    required this.message,
    this.queue,
    this.queueVersion,
    this.sessionId,
  });

  final String kind;
  final String message;
  final List<QueueTrack>? queue;
  final int? queueVersion;
  final String? sessionId;

  @override
  String toString() => 'DjApiException($kind): $message';
}

/// Thrown specifically for a queue-ops 409 `{error:'stale', queue,
/// queueVersion}` — per the 409 rule, the body's queue/version is always
/// trusted directly (no separate refetch needed).
class StaleQueueException implements Exception {
  StaleQueueException({required this.queue, required this.queueVersion});

  final List<QueueTrack> queue;
  final int queueVersion;

  @override
  String toString() => 'StaleQueueException(v$queueVersion)';
}

const _genericDjErrorMessage = 'The DJ ran into a problem — please try again.';
const _genericInvalidMessage = 'That request was invalid.';
const _genericStaleMessage = 'The queue changed — showing the latest.';
const _genericMalformedResponseMessage = 'Got an unexpected response — please try again.';

/// Typed client for the P3a DJ session API (sessions, transcript, queue).
///
/// DJ turns (session create, chat message) run an LLM round trip — 20 to 40s
/// in practice — well past [ApiClient]'s 30s default, which every other
/// (fast) route relies on staying tight. Rather than widen that default for
/// the whole app, [DjApi] owns its OWN [ApiClient] instance, over the same
/// [TokenStore], with a 120s timeout: [ApiClient]'s public surface and
/// default stay exactly as they are for every non-DJ caller.
///
/// [DjApi] has exactly four exit types: [DjApiException] (a DJ-domain error
/// body, or a 200 whose body didn't parse), [StaleQueueException] (a
/// queue-ops version conflict), [ApiException] (any status this class
/// doesn't specially interpret — 401/403/404/500/... — passed through
/// unchanged), and [NetworkException] (transport-level failure, from
/// [ApiClient] itself). Nothing else escapes a call.
class DjApi {
  DjApi({
    required String baseUrl,
    required TokenStore tokenStore,
    http.Client? inner,
    Duration timeout = const Duration(seconds: 120),
  }) : _client = ApiClient(baseUrl: baseUrl, tokenStore: tokenStore, inner: inner, timeout: timeout);

  /// Builds a [DjApi] over the SAME baseUrl/tokenStore as an existing
  /// [ApiClient] (typically the app's shared one) — structural sharing so
  /// the pairing can't drift out of sync — but with its own longer-timeout
  /// [ApiClient] underneath, per this class's doc comment. [inner] is an
  /// optional override (e.g. a test's MockClient); it is NOT taken from
  /// [base] (which doesn't expose its own).
  factory DjApi.from(ApiClient base, {http.Client? inner, Duration timeout = const Duration(seconds: 120)}) =>
      DjApi(baseUrl: base.baseUrl, tokenStore: base.tokenStore, inner: inner, timeout: timeout);

  final ApiClient _client;

  Duration get timeout => _client.timeout;

  Future<SessionDetail> createSession(String prompt) =>
      _call(() => _client.postJson('/sessions', {'prompt': prompt}), SessionDetail.fromJson);

  Future<List<DjSession>> listSessions() => _call(
        () => _client.getJson('/sessions'),
        (json) => (json['sessions'] as List)
            .map((s) => DjSession.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  Future<SessionDetail> getSession(String id) =>
      _call(() => _client.getJson('/sessions/$id'), SessionDetail.fromJson);

  Future<TurnResult> sendMessage(String id, String text) =>
      _call(() => _client.postJson('/sessions/$id/messages', {'text': text}), TurnResult.fromJson);

  /// [ops] are remove/move only (0-based positions) — swap/extend need the
  /// DJ and come back as a 400 `dj_required`. [expectedVersion] is the
  /// caller's last-known queueVersion; omit it only when there is none yet.
  Future<QueueOpsResult> applyQueueOps(String id, List<QueueOp> ops, int? expectedVersion) => _call(
        () => _client.postJson('/sessions/$id/queue-ops', {
          'ops': ops.map((o) => o.toJson()).toList(),
          if (expectedVersion != null) 'expectedVersion': expectedVersion,
        }),
        QueueOpsResult.fromJson,
      );

  Future<DjSession> setStatus(String id, String status) => _call(
        () => _client.patchJson('/sessions/$id', {'status': status}),
        (json) => DjSession.fromJson(json['session'] as Map<String, dynamic>),
      );

  void close() => _client.close();

  Future<T> _call<T>(
    Future<http.Response> Function() request,
    T Function(Map<String, dynamic> json) parse,
  ) async {
    final http.Response res;
    try {
      res = await request();
    } on ApiException catch (e) {
      throw _translate(e);
    }
    // A 200 body that isn't valid JSON, isn't a JSON object, or is missing a
    // key `parse` needs is a server/client drift bug, not a DJ-domain
    // error — surfaced as its own typed exit rather than an uncaught
    // FormatException or type-cast error reaching the UI layer.
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return parse(decoded);
    } catch (_) {
      // fall through to the typed exit below
    }
    throw DjApiException(kind: 'malformed_response', message: _genericMalformedResponseMessage);
  }

  Exception _translate(ApiException e) {
    switch (e.statusCode) {
      case 409:
        return _translate409(e.body);
      case 502:
        return _translateMessageBody(e.body, fallback: _genericDjErrorMessage);
      case 400:
        return _translate400(e.body);
      default:
        // Anything else (401/403/404/500/...) isn't part of the DJ error
        // taxonomy — pass the original ApiException through unchanged.
        return e;
    }
  }

  Exception _translate409(String body) {
    final decoded = _tryDecode(body);
    if (decoded != null && decoded['error'] == 'stale') {
      try {
        return StaleQueueException(
          queue: queueTracksFromJson(decoded['queue']),
          queueVersion: decoded['queueVersion'] as int,
        );
      } catch (_) {
        // Malformed 'stale' body (missing/bad queue or queueVersion) — never
        // a secondary parse error. Degrades to a plain error bubble in the
        // transcript; kind is still 'stale', so a caller that would rather
        // recover than show an error can instead treat this kind as a signal
        // to refetch the session (GET /:id) for a fresh queue.
        return DjApiException(kind: 'stale', message: _genericStaleMessage);
      }
    }
    return _translateMessageBody(body, fallback: _genericDjErrorMessage, decoded: decoded);
  }

  /// 502s, and 409 turn-conflicts, both use the same
  /// `{error, message, queue?, queueVersion?, sessionId?}` shape (see
  /// sessions.ts's djErrorBody). `kind` carries the server's `error` field
  /// verbatim; `message` is listener-ready.
  DjApiException _translateMessageBody(
    String body, {
    required String fallback,
    Map<String, dynamic>? decoded,
  }) {
    decoded ??= _tryDecode(body);
    if (decoded == null) return DjApiException(kind: 'unknown', message: fallback);

    final kind = decoded['error'] is String ? decoded['error'] as String : 'unknown';
    final message = decoded['message'] is String ? decoded['message'] as String : fallback;
    List<QueueTrack>? queue;
    try {
      final rawQueue = decoded['queue'];
      if (rawQueue != null) queue = queueTracksFromJson(rawQueue);
    } catch (_) {
      queue = null;
    }
    final queueVersion = decoded['queueVersion'] is int ? decoded['queueVersion'] as int : null;
    final sessionId = decoded['sessionId'] is String ? decoded['sessionId'] as String : null;
    return DjApiException(
      kind: kind,
      message: message,
      queue: queue,
      queueVersion: queueVersion,
      sessionId: sessionId,
    );
  }

  /// The two known 400 shapes are told apart by whether `error` is a plain
  /// string:
  ///  - `{error, message}` (hand-written: `dj_required`, `invalid_ops`, ...)
  ///    — `kind` keeps the server's `error` string verbatim (Task 2's
  ///    providers branch on it, e.g. 'dj_required'), `message` preferred,
  ///    falling back to a generic string only if `message` is missing.
  ///  - zod's default validator failure, actually
  ///    `{success:false, error:{name:'ZodError', message:'<serialized
  ///    issues blob>'}}` — `error` is a Map here, not a string, and its
  ///    `message` is an internal diagnostic blob, NEVER fit to render.
  ///    Always `kind: 'invalid'` with the generic fallback message.
  /// A malformed or otherwise-unrecognized body never throws a secondary
  /// parse error — it falls back to `kind: 'invalid'` + a generic message.
  DjApiException _translate400(String body) {
    final decoded = _tryDecode(body);
    if (decoded == null) return DjApiException(kind: 'invalid', message: _genericInvalidMessage);

    final errorField = decoded['error'];
    if (errorField is String) {
      final message = decoded['message'] is String ? decoded['message'] as String : _genericInvalidMessage;
      return DjApiException(kind: errorField, message: message);
    }
    return DjApiException(kind: 'invalid', message: _genericInvalidMessage);
  }

  Map<String, dynamic>? _tryDecode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
