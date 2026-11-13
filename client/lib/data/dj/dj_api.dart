import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api/api_client.dart';
import '../auth/token_store.dart';
import 'dj_models.dart';
import 'turn_stream.dart';
import '../playlists/playlist_context_models.dart';

export 'turn_stream.dart'
    show TurnProgress, TurnSessionStarted, TurnStep, TurnStreamOpened;

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
    this.pickState,
    this.step,
  });

  final String kind;
  final String message;
  final List<QueueTrack>? queue;
  final int? queueVersion;
  final String? sessionId;

  /// Album error bodies only: the shortlist when a version landed before the
  /// failure (the server's `pick`/`runnersUp`/`passed`/`version`).
  final AlbumPickState? pickState;

  /// Album error bodies only: which step of the album loop failed.
  final String? step;

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

/// Thrown when `POST /sessions` refuses a new mix because an anonymous
/// listener reached the cap (403 `{error:'anonymous_cap', limit}`). The
/// composer catches this to offer sign-in; follow-up turns are never capped.
class AnonymousCapException implements Exception {
  const AnonymousCapException(this.limit);

  final int limit;

  @override
  String toString() => 'AnonymousCapException($limit)';
}

/// Why a shared mix can't be read or saved: an unknown token (404
/// `not_found`) or a share its owner stopped (410 `revoked`).
enum SharedMixGoneReason { notFound, revoked }

/// A share link that no longer opens (spec 2026-11-13 shared-mixes). Both
/// reasons read the same to the listener: [message].
class SharedMixGoneException implements Exception {
  const SharedMixGoneException(this.reason);

  final SharedMixGoneReason reason;

  /// The listener-facing copy, the same for both reasons.
  static const String message = "This mix isn't shared anymore.";

  @override
  String toString() => 'SharedMixGoneException(${reason.name})';
}

/// `POST /sessions/:id/share` answered 409 `name_required`: the recipient
/// sees the sharer's first name, so the caller opens the name page first.
class ShareNameRequiredException implements Exception {
  const ShareNameRequiredException();

  @override
  String toString() => 'ShareNameRequiredException';
}

/// `POST /sessions/:id/share` answered 422 `empty_mix`: nothing to share.
class EmptyMixException implements Exception {
  const EmptyMixException();

  @override
  String toString() => 'EmptyMixException';
}

/// The server's ANONYMOUS_MIX_CAP, used when a cap body omits `limit`.
const _defaultAnonymousCap = 3;

const _genericDjErrorMessage = 'The DJ ran into a problem — please try again.';
const _genericInvalidMessage = 'That request was invalid.';
const _genericStaleMessage = 'The queue changed — showing the latest.';
const _albumPicksOffMessage = 'Album picks are not available right now.';
const _anonymousAlbumsMessage = 'Sign in to get album picks.';
const _genericMalformedResponseMessage =
    'Got an unexpected response — please try again.';

/// Typed client for the P3a DJ session API (sessions, transcript, queue).
///
/// DJ turns (session create, chat message) run an LLM round trip — 20 to 40s
/// in practice — well past [ApiClient]'s 30s default, which every other
/// (fast) route relies on staying tight. Rather than widen that default for
/// the whole app, [DjApi] owns its OWN [ApiClient] instance, over the same
/// [TokenStore], with a 120s timeout: [ApiClient]'s public surface and
/// default stay exactly as they are for every non-DJ caller.
///
/// [DjApi] has exactly five exit types: [DjApiException] (a DJ-domain error
/// body, a 200 whose body didn't parse, or the album refusals: 404
/// `album_picks_off` and 403 `anonymous_albums`), [StaleQueueException] (a
/// queue-ops version conflict), [AnonymousCapException] (an anonymous
/// listener's new-mix cap), [ApiException] (any status this class
/// doesn't specially interpret — 401/404/500/..., and any 403 other than
/// the cap — passed through unchanged), and [NetworkException] (transport-level failure, from
/// [ApiClient] itself). Nothing else escapes a call.
///
/// The mix turns can also stream their progress ([DjApiTurnProgress]): the
/// same requests with `Accept: text/event-stream`, ending in the same five
/// exit types. On a stream, `streamIdleTimeout` (45s by default, reset by
/// every byte including the server's 15s keepalives) replaces the total
/// timeout once the response headers are in.
class DjApi {
  DjApi({
    required String baseUrl,
    required TokenStore tokenStore,
    http.Client? inner,
    Duration timeout = const Duration(seconds: 120),
    Duration streamIdleTimeout = const Duration(seconds: 45),
    Future<void> Function(String token)? onUnauthorized,
  }) : _client = ApiClient(
         baseUrl: baseUrl,
         tokenStore: tokenStore,
         inner: inner,
         timeout: timeout,
         onUnauthorized: onUnauthorized,
       ),
       // The public shared-mix read: it carries the session when there is
       // one (the owner check) but never signs anyone out on a 401.
       _publicClient = ApiClient(
         baseUrl: baseUrl,
         tokenStore: tokenStore,
         inner: inner,
         timeout: timeout,
       ),
       _streamIdleTimeout = streamIdleTimeout {
    _builtByDjApi[this] = true;
  }

  /// Builds a [DjApi] over the SAME baseUrl/tokenStore as an existing
  /// [ApiClient] (typically the app's shared one) — structural sharing so
  /// the pairing can't drift out of sync — but with its own longer-timeout
  /// [ApiClient] underneath, per this class's doc comment. [inner] is an
  /// optional override (e.g. a test's MockClient); it is NOT taken from
  /// [base] (which doesn't expose its own).
  factory DjApi.from(
    ApiClient base, {
    http.Client? inner,
    Duration timeout = const Duration(seconds: 120),
    Duration streamIdleTimeout = const Duration(seconds: 45),
  }) => DjApi(
    baseUrl: base.baseUrl,
    tokenStore: base.tokenStore,
    inner: inner,
    timeout: timeout,
    streamIdleTimeout: streamIdleTimeout,
    onUnauthorized: base.onUnauthorized,
  );

  final ApiClient _client;
  final ApiClient _publicClient;
  final Duration _streamIdleTimeout;

  Duration get timeout => _client.timeout;

  /// [kind] rides the wire only for an album session; a mix sends exactly
  /// what it always did, so an older server never sees an unknown key.
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) => _createSession(prompt, playlistSeed: playlistSeed, kind: kind);

  /// An album session answers JSON whatever it is asked, so an album create
  /// never asks for a stream: its request stays exactly today's.
  Future<SessionDetail> _createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  }) => _turn(
    '/sessions',
    {
      'prompt': prompt,
      if (playlistSeed != null) 'playlistSeed': playlistSeed.toJson(),
      if (kind == SessionKind.album) 'kind': 'album',
    },
    SessionDetail.fromJson,
    kind == SessionKind.album ? null : onProgress,
  );

  Future<List<DjSession>> listSessions() => _call(
    () => _client.getJson('/sessions'),
    (json) => (json['sessions'] as List)
        .map((s) => DjSession.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  Future<SessionDetail> getSession(String id) =>
      _call(() => _client.getJson('/sessions/$id'), SessionDetail.fromJson);

  Future<TurnResult> sendMessage(String id, String text) =>
      _sendMessage(id, text);

  Future<TurnResult> _sendMessage(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) => _turn(
    '/sessions/$id/messages',
    {'text': text},
    TurnResult.fromJson,
    onProgress,
  );

  /// The wire half of [DjApiRemake.sendRemake]: the same endpoint and error
  /// translation as [sendMessage], with the remake flag.
  Future<TurnResult> _sendRemake(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  }) => _turn(
    '/sessions/$id/messages',
    {'text': remakeText, 'remake': true},
    TurnResult.fromJson,
    onProgress,
  );

  /// [ops] are remove/move only (0-based positions) — swap/extend need the
  /// DJ and come back as a 400 `dj_required`. [expectedVersion] is the
  /// caller's last-known queueVersion; omit it only when there is none yet.
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) => _call(
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

  /// PATCH `/sessions/:id` with `{title}` — the server trims/sanitizes and
  /// caps it at 60 characters for display (same discipline as a
  /// DJ-driven rename via `rename_session`); a title that's empty or
  /// whitespace-only after that sanitize step comes back as a 400
  /// `invalid_title` [DjApiException]. Mirrors [setStatus]'s shape, echoing
  /// the updated session row.
  Future<DjSession> setCaseColor(String id, String caseColor) => _call(
    () => _client.patchJson('/sessions/$id', {'caseColor': caseColor}),
    (json) => DjSession.fromJson(json['session'] as Map<String, dynamic>),
  );

  Future<DjSession> renameSession(String id, String title) => _call(
    () => _client.patchJson('/sessions/$id', {'title': title}),
    (json) => DjSession.fromJson(json['session'] as Map<String, dynamic>),
  );

  /// Fire-and-forget from the caller's perspective (see queue_screen.dart's
  /// post-play/post-save wiring) — but NOT from this method's: it throws the
  /// normal exit taxonomy like every other call here ([DjApiException],
  /// [ApiException], [NetworkException]). Swallowing failures is the
  /// caller's job, deliberately, so this class stays uniform.
  Future<void> postSessionEvent(String sessionId, String type) => _callVoid(
    () => _client.postJson('/sessions/$sessionId/events', {'type': type}),
  );

  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) => _callVoid(
    () => _client.postJson('/playlists/creation-receipts', {
      'sessionId': sessionId,
      'appleLibraryId': appleLibraryId,
    }),
  );

  /// `GET /me/memories` — newest-first, capped at 50 server-side.
  Future<List<DjMemory>> listMemories() => _call(
    () => _client.getJson('/me/memories'),
    (json) => (json['memories'] as List)
        .map((m) => DjMemory.fromJson(m as Map<String, dynamic>))
        .toList(),
  );

  /// `DELETE /me/memories/:id` — hard delete, owner-scoped server-side (a
  /// 404 on someone else's id surfaces as a plain [ApiException], not part
  /// of the DJ error taxonomy).
  Future<void> deleteMemory(String id) =>
      _callVoid(() => _client.deleteJson('/me/memories/$id'));

  /// `POST /sessions/:id/pick` with `{albumId}`: make a runner-up the pick.
  /// [expectedVersion] fences on the caller's last-known pick version; a
  /// lost race is a [DjApiException] of kind `stale`.
  Future<AlbumPickState> choosePick(
    String sessionId, {
    required String albumId,
    int? expectedVersion,
  }) => _call(
    () => _client.postJson('/sessions/$sessionId/pick', {
      'albumId': albumId,
      if (expectedVersion != null) 'expectedVersion': expectedVersion,
    }),
    AlbumPickState.fromJson,
  );

  /// `POST /sessions/:id/pick` with `{version}`: go back to an earlier
  /// shortlist (written as a new version server-side).
  Future<AlbumPickState> goBackToPick(
    String sessionId, {
    required int version,
    int? expectedVersion,
  }) => _call(
    () => _client.postJson('/sessions/$sessionId/pick', {
      'version': version,
      if (expectedVersion != null) 'expectedVersion': expectedVersion,
    }),
    AlbumPickState.fromJson,
  );

  /// `GET /me/listen-later` in server order: unlistened newest-saved first,
  /// then listened newest-listened first.
  Future<List<ListenLaterEntry>> listListenLater() => _call(
    () => _client.getJson('/me/listen-later'),
    (json) => (json['entries'] as List)
        .map((e) => ListenLaterEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// `PUT /me/listen-later/:albumId`. [sessionId] names the album session
  /// it was saved from; a re-save without one keeps the row's source.
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) =>
      _call(
        () => _client.putJson('/me/listen-later/$albumId', {
          if (sessionId != null) 'sessionId': sessionId,
        }),
        (json) =>
            ListenLaterEntry.fromJson(json['entry'] as Map<String, dynamic>),
      );

  /// `DELETE /me/listen-later/:albumId` (a soft removal server-side).
  Future<void> unsaveForLater(String albumId) =>
      _callVoid(() => _client.deleteJson('/me/listen-later/$albumId'));

  /// `POST /me/listen-later/:albumId/listened`; keeps the first listened
  /// date. A 404 (not on the shelf) passes through as [ApiException].
  Future<ListenLaterEntry> markListened(String albumId) => _call(
    () => _client.postJson('/me/listen-later/$albumId/listened', const {}),
    (json) => ListenLaterEntry.fromJson(json['entry'] as Map<String, dynamic>),
  );

  void close() {
    _client.close();
    _publicClient.close();
  }

  // Shared mixes (spec 2026-11-13 shared-mixes, API table). Reached through
  // [DjApiSharedMixes].

  Future<SharedMix> _getSharedMix(String token) => _shareCall(
    () => _publicClient.getJson('/shared/${Uri.encodeComponent(token)}'),
    SharedMix.fromJson,
    _shareTokenError,
  );

  Future<void> _saveSharedMix(String token) => _shareCallVoid(
    () => _client.postJson(
      '/shared/${Uri.encodeComponent(token)}/save',
      const <String, Object?>{},
    ),
    _shareTokenError,
  );

  Future<void> _removeSharedMix(String token) => _shareCallVoid(
    () => _client.deleteJson('/shared/${Uri.encodeComponent(token)}/save'),
    _shareTokenError,
  );

  Future<List<SharedMixRow>> _listSharedMixes() => _call(
    () => _client.getJson('/me/shared-mixes'),
    (json) => (json['mixes'] as List)
        .map((m) => SharedMixRow.fromJson(m as Map<String, dynamic>))
        .toList(),
  );

  Future<ShareLinkResult> _shareSession(String sessionId) => _shareCall(
    () => _client.postJson(
      '/sessions/$sessionId/share',
      const <String, Object?>{},
    ),
    ShareLinkResult.fromJson,
    _shareCreateError,
  );

  Future<void> _stopSharing(String sessionId) =>
      _callVoid(() => _client.deleteJson('/sessions/$sessionId/share'));

  Future<T> _shareCall<T>(
    Future<http.Response> Function() request,
    T Function(Map<String, dynamic> json) parse,
    Exception Function(ApiException e) translate,
  ) async {
    final http.Response res;
    try {
      res = await request();
    } on ApiException catch (e) {
      throw translate(e);
    }
    return _parse(res.body, parse);
  }

  Future<void> _shareCallVoid(
    Future<http.Response> Function() request,
    Exception Function(ApiException e) translate,
  ) async {
    try {
      await request();
    } on ApiException catch (e) {
      throw translate(e);
    }
  }

  /// The token routes: 404 `not_found` and 410 are a link that no longer
  /// opens; anything else (429 included) maps as every other call.
  Exception _shareTokenError(ApiException e) {
    if (e.statusCode == 410) {
      return const SharedMixGoneException(SharedMixGoneReason.revoked);
    }
    if (e.statusCode == 404 && _tryDecode(e.body)?['error'] == 'not_found') {
      return const SharedMixGoneException(SharedMixGoneReason.notFound);
    }
    return _translate(e);
  }

  /// `POST /sessions/:id/share`: 409 `name_required` and 422 `empty_mix`;
  /// anything else (a 404 for an album or someone else's mix, a 429) maps as
  /// every other call.
  Exception _shareCreateError(ApiException e) {
    final error = _tryDecode(e.body)?['error'];
    if (e.statusCode == 409 && error == 'name_required') {
      return const ShareNameRequiredException();
    }
    if (e.statusCode == 422 && error == 'empty_mix') {
      return const EmptyMixException();
    }
    return _translate(e);
  }

  /// A mix turn. Without [onProgress] it is exactly today's JSON request.
  Future<T> _turn<T>(
    String path,
    Map<String, Object?> body,
    T Function(Map<String, dynamic> json) parse,
    void Function(TurnProgress progress)? onProgress,
  ) => onProgress == null
      ? _call(() => _client.postJson(path, body), parse)
      : _streamedTurn(path, body, parse, onProgress);

  /// The turn asking for a stream. Every way out is one of today's: a JSON
  /// answer (an older server, a refusal before the turn) goes through
  /// today's mapping; a `result` goes through today's parse; an `error`
  /// throws what today's status and body would have; a dropped or quiet
  /// stream is a [NetworkException], as a timeout is today.
  Future<T> _streamedTurn<T>(
    String path,
    Map<String, Object?> body,
    T Function(Map<String, dynamic> json) parse,
    void Function(TurnProgress progress) onProgress,
  ) async {
    void report(TurnProgress progress) {
      try {
        onProgress(progress);
      } catch (_) {
        // A caption must never break the turn.
      }
    }

    final StreamingReply reply;
    try {
      reply = await _client.postEventStream(
        path,
        body,
        idleTimeout: _streamIdleTimeout,
      );
    } on ApiException catch (e) {
      throw _translate(e);
    }
    switch (reply) {
      case WholeReply(:final response):
        return _parse(response.body, parse);
      case final EventStreamReply stream:
        report(const TurnStreamOpened());
        return switch (await readTurnStream(stream.bytes, report)) {
          TurnStreamResult(:final body) => _parse(body, parse),
          // Through the client, so an in-band 401 still signs out.
          TurnStreamError(:final status, :final body) => throw _translate(
            stream.failure(status, body),
          ),
          TurnStreamMalformed() => throw DjApiException(
            kind: 'malformed_response',
            message: _genericMalformedResponseMessage,
          ),
        };
    }
  }

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
    return _parse(res.body, parse);
  }

  /// A 200 body that isn't valid JSON, isn't a JSON object, or is missing a
  /// key [parse] needs is a server/client drift bug, not a DJ-domain
  /// error — surfaced as its own typed exit rather than an uncaught
  /// FormatException or type-cast error reaching the UI layer.
  T _parse<T>(String body, T Function(Map<String, dynamic> json) parse) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return parse(decoded);
    } catch (_) {
      // fall through to the typed exit below
    }
    throw DjApiException(
      kind: 'malformed_response',
      message: _genericMalformedResponseMessage,
    );
  }

  /// Same success/error-status handling as [_call], but for endpoints whose
  /// caller never reads the 200 body (`postSessionEvent`, `deleteMemory`) —
  /// both are documented server-side as returning `{ok:true}`, but nothing
  /// here actually depends on that shape. [_call] would wrongly manufacture
  /// a `malformed_response` [DjApiException] for a call that otherwise
  /// succeeded if the body were ever empty or non-JSON (e.g. a bare 200 with
  /// no body, which some proxies/edge runtimes produce for a void response) —
  /// this path tolerates any 200 body content, or none at all, as success.
  Future<void> _callVoid(Future<http.Response> Function() request) async {
    try {
      await request();
    } on ApiException catch (e) {
      throw _translate(e);
    }
  }

  Exception _translate(ApiException e) {
    switch (e.statusCode) {
      case 409:
        return _translate409(e.body);
      case 502:
        return _translateMessageBody(e.body, fallback: _genericDjErrorMessage);
      case 400:
        return _translate400(e.body);
      case 404:
        // The album flag is off server-side: a known condition the UI words,
        // unlike a plain not_found.
        if (_tryDecode(e.body)?['error'] == 'album_picks_off') {
          return DjApiException(
            kind: 'album_picks_off',
            message: _albumPicksOffMessage,
          );
        }
        return e;
      case 403:
        if (AiConsentRequiredException.matches(e.statusCode, e.body)) {
          return const AiConsentRequiredException();
        }
        final decoded = _tryDecode(e.body);
        if (decoded?['error'] == 'anonymous_albums') {
          return DjApiException(
            kind: 'anonymous_albums',
            message: _anonymousAlbumsMessage,
          );
        }
        if (decoded?['error'] == 'anonymous_cap') {
          final limit = decoded?['limit'];
          return AnonymousCapException(
            limit is int ? limit : _defaultAnonymousCap,
          );
        }
        // Any other 403 isn't part of the DJ error taxonomy.
        return e;
      default:
        // Anything else (401/404/500/...) isn't part of the DJ error
        // taxonomy — pass the original ApiException through unchanged.
        return e;
    }
  }

  Exception _translate409(String body) {
    final decoded = _tryDecode(body);
    if (decoded != null && decoded['error'] == 'stale') {
      // The pick route's stale shape is `{error:'stale', version}` with no
      // queue: the caller refetches the session for the fresh shortlist.
      if (decoded['queue'] == null) {
        return DjApiException(kind: 'stale', message: _genericStaleMessage);
      }
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
    return _translateMessageBody(
      body,
      fallback: _genericDjErrorMessage,
      decoded: decoded,
    );
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
    if (decoded == null) {
      return DjApiException(kind: 'unknown', message: fallback);
    }

    final kind = decoded['error'] is String
        ? decoded['error'] as String
        : 'unknown';
    final message = decoded['message'] is String
        ? decoded['message'] as String
        : fallback;
    List<QueueTrack>? queue;
    // Independent of the try/catch below: the body can legitimately carry
    // `queue` without `queueVersion` (or vice versa) — e.g. a create-session
    // failure's queue snapshot with no version concept attached — and that's
    // not the asymmetry this method guards against. A queue without a
    // version is preserved here at the API layer (the server may
    // legitimately omit one), but it's never adopted into ChatState —
    // position-based ops (remove/move) need a version to target against, so
    // dj_providers.dart's _atomicQueueSnapshot requires both together before
    // adopting either. Today the server always sends both together, so this
    // asymmetry is currently theoretical, not observed.
    var queueVersion = decoded['queueVersion'] is int
        ? decoded['queueVersion'] as int
        : null;
    try {
      final rawQueue = decoded['queue'];
      if (rawQueue != null) queue = queueTracksFromJson(rawQueue);
    } catch (_) {
      // A queue blob that fails to parse must not leave a queueVersion
      // dangling without it — a version paired with garbage-in-place-of-a-
      // queue is worse than having neither (same rule the providers apply
      // to adoption; see dj_providers.dart's atomic queue-snapshot helper).
      queue = null;
      queueVersion = null;
    }
    final sessionId = decoded['sessionId'] is String
        ? decoded['sessionId'] as String
        : null;
    // Album error bodies carry the shortlist only when a version landed
    // before the failure; a body that fails to parse carries none.
    AlbumPickState? pickState;
    if (decoded['version'] is int) {
      try {
        pickState = AlbumPickState.fromJson(decoded);
      } catch (_) {
        pickState = null;
      }
    }
    return DjApiException(
      kind: kind,
      message: message,
      queue: queue,
      queueVersion: queueVersion,
      sessionId: sessionId,
      pickState: pickState,
      step: decoded['step'] is String ? decoded['step'] as String : null,
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
    if (decoded == null) {
      return DjApiException(kind: 'invalid', message: _genericInvalidMessage);
    }

    final errorField = decoded['error'];
    if (errorField is String) {
      final message = decoded['message'] is String
          ? decoded['message'] as String
          : _genericInvalidMessage;
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

/// What a [DjApi] stand-in implements to answer [DjApiRemake.sendRemake]
/// itself (the real [DjApi] does not need to).
abstract interface class DjRemakeSender {
  Future<TurnResult> sendRemake(String id);
}

/// The remake turn: posts [remakeText] with `remake: true` (mix sessions
/// only; an album session answers 409 `wrong_session_kind`).
///
/// An extension rather than a [DjApi] member on purpose: every test fake
/// `implements DjApi`, so a new member is a compile error in each one,
/// including fakes in files this change must not touch. A fake that
/// implements [DjRemakeSender] answers the call; the real [DjApi] posts.
/// Fold it into [DjApi] when the fakes can be updated together.
extension DjApiRemake on DjApi {
  Future<TurnResult> sendRemake(String id) => switch (this) {
    final DjRemakeSender sender => sender.sendRemake(id),
    _ => _sendRemake(id),
  };
}

/// What a [DjApi] stand-in implements to answer [DjApiSharedMixes] itself
/// (the real [DjApi] does not need to).
abstract interface class DjSharedMixes {
  Future<SharedMix> getSharedMix(String token);
  Future<void> saveSharedMix(String token);
  Future<void> removeSharedMix(String token);
  Future<List<SharedMixRow>> listSharedMixes();
  Future<ShareLinkResult> shareSession(String sessionId);
  Future<void> stopSharing(String sessionId);
}

/// Shared mixes (spec 2026-11-13 shared-mixes, API table). An extension for
/// the reason [DjApiRemake] gives; a stand-in implements [DjSharedMixes].
///
/// Exits, beyond [DjApi]'s usual ones: [SharedMixGoneException] (404
/// `not_found` / 410 `revoked` on the token routes),
/// [ShareNameRequiredException] (409) and [EmptyMixException] (422) on
/// [shareSession]. A 429 is a plain [ApiException]. [getSharedMix] works with
/// or without a session and never signs the listener out, whatever it gets.
extension DjApiSharedMixes on DjApi {
  /// `GET /shared/:token`.
  Future<SharedMix> getSharedMix(String token) => switch (this) {
    final DjSharedMixes s => s.getSharedMix(token),
    _ => _getSharedMix(token),
  };

  /// `POST /shared/:token/save` (idempotent; the owner's own is a no-op).
  Future<void> saveSharedMix(String token) => switch (this) {
    final DjSharedMixes s => s.saveSharedMix(token),
    _ => _saveSharedMix(token),
  };

  /// `DELETE /shared/:token/save`; works on a revoked share too.
  Future<void> removeSharedMix(String token) => switch (this) {
    final DjSharedMixes s => s.removeSharedMix(token),
    _ => _removeSharedMix(token),
  };

  /// `GET /me/shared-mixes`, newest save first.
  Future<List<SharedMixRow>> listSharedMixes() => switch (this) {
    final DjSharedMixes s => s.listSharedMixes(),
    _ => _listSharedMixes(),
  };

  /// `POST /sessions/:id/share`: the same token until the queue changes.
  Future<ShareLinkResult> shareSession(String sessionId) => switch (this) {
    final DjSharedMixes s => s.shareSession(sessionId),
    _ => _shareSession(sessionId),
  };

  /// `DELETE /sessions/:id/share`: revokes every link to the mix.
  Future<void> stopSharing(String sessionId) => switch (this) {
    final DjSharedMixes s => s.stopSharing(sessionId),
    _ => _stopSharing(sessionId),
  };
}

/// The [DjApi] instances its own constructor built, so [DjApiTurnProgress]
/// can tell the real client from a stand-in that `implements DjApi` (one
/// never runs the constructor).
final Expando<bool> _builtByDjApi = Expando('DjApi');

/// What a [DjApi] stand-in implements to answer [DjApiTurnProgress] itself,
/// for instance to report made-up steps.
abstract interface class DjTurnProgressSender {
  Future<SessionDetail> createSessionWithProgress(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  });

  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  });

  Future<TurnResult> sendRemakeWithProgress(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  });
}

/// The mix turns, reporting their progress while they run (spec:
/// 2026-11-13-dj-turn-steps-design.md). With [onProgress] given they ask
/// for `text/event-stream`; [onProgress] then hears [TurnStreamOpened] when
/// the server answered with a stream, [TurnSessionStarted] (create only)
/// and each [TurnStep]. Its exceptions are swallowed. A server that answers
/// JSON (an older one, a refusal before the turn, an album) reports
/// nothing. Results and exceptions are exactly those of [DjApi.createSession],
/// [DjApi.sendMessage] and [DjApiRemake.sendRemake]; without [onProgress]
/// each call is that one.
///
/// An extension rather than an optional parameter on those members for the
/// reason [DjApiRemake] gives: every test fake `implements DjApi`, so a new
/// parameter is a compile error in each one. A stand-in that implements
/// [DjTurnProgressSender] answers these calls; any other stand-in answers
/// through its plain calls, so it reports no progress, like an older
/// server. Fold these into [DjApi] when the fakes can be updated together.
extension DjApiTurnProgress on DjApi {
  Future<SessionDetail> createSessionWithProgress(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
    void Function(TurnProgress progress)? onProgress,
  }) => switch (this) {
    final DjTurnProgressSender sender => sender.createSessionWithProgress(
      prompt,
      playlistSeed: playlistSeed,
      kind: kind,
      onProgress: onProgress,
    ),
    _ when _builtByDjApi[this] == true => _createSession(
      prompt,
      playlistSeed: playlistSeed,
      kind: kind,
      onProgress: onProgress,
    ),
    _ => createSession(prompt, playlistSeed: playlistSeed, kind: kind),
  };

  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) => switch (this) {
    final DjTurnProgressSender sender => sender.sendMessageWithProgress(
      id,
      text,
      onProgress: onProgress,
    ),
    _ when _builtByDjApi[this] == true => _sendMessage(
      id,
      text,
      onProgress: onProgress,
    ),
    _ => sendMessage(id, text),
  };

  Future<TurnResult> sendRemakeWithProgress(
    String id, {
    void Function(TurnProgress progress)? onProgress,
  }) => switch (this) {
    final DjTurnProgressSender sender => sender.sendRemakeWithProgress(
      id,
      onProgress: onProgress,
    ),
    _ when _builtByDjApi[this] == true => _sendRemake(
      id,
      onProgress: onProgress,
    ),
    _ => sendRemake(id),
  };
}
