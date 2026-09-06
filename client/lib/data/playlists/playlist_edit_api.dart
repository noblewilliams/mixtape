import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../auth/token_store.dart';
import 'playlist_edit_models.dart';

const _genericEditError =
    'The DJ could not finish that playlist edit. Try again.';
const _genericInvalidError = 'That playlist edit request was invalid.';

class PlaylistEditApiException implements Exception {
  const PlaylistEditApiException({
    required this.kind,
    required this.message,
    this.draft,
  });

  final String kind;
  final String message;
  final PlaylistEditView? draft;

  @override
  String toString() => 'PlaylistEditApiException($kind)';
}

class PlaylistEditApi {
  PlaylistEditApi({
    required String baseUrl,
    required TokenStore tokenStore,
    http.Client? inner,
    Duration timeout = const Duration(seconds: 120),
  }) : _client = ApiClient(
         baseUrl: baseUrl,
         tokenStore: tokenStore,
         inner: inner,
         timeout: timeout,
       );

  factory PlaylistEditApi.from(
    ApiClient base, {
    http.Client? inner,
    Duration timeout = const Duration(seconds: 120),
  }) => PlaylistEditApi(
    baseUrl: base.baseUrl,
    tokenStore: base.tokenStore,
    inner: inner,
    timeout: timeout,
  );

  final ApiClient _client;

  Duration get timeout => _client.timeout;

  Future<PlaylistEditView> createOrResume(String playlistId) => _call(
    () => _client.postJson('/playlists/$playlistId/edit-draft', const {}),
    PlaylistEditView.fromJson,
  );

  Future<PlaylistEditThread> getThread(String draftId) => _call(
    () => _client.getJson('/playlist-edit-drafts/$draftId'),
    PlaylistEditThread.fromJson,
  );

  Future<PlaylistEditTurnResult> sendMessage(
    String draftId,
    String content,
    int expectedVersion,
  ) => _call(
    () => _client.postJson('/playlist-edit-drafts/$draftId/messages', {
      'content': content,
      'expectedVersion': expectedVersion,
    }),
    PlaylistEditTurnResult.fromJson,
  );

  void close() => _client.close();

  Future<T> _call<T>(
    Future<http.Response> Function() request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final http.Response response;
    try {
      response = await request();
    } on ApiException catch (error) {
      throw _translate(error);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return parse(decoded);
    } catch (error) {
      if (error is PlaylistEditModelException) rethrow;
    }
    throw const PlaylistEditModelException();
  }

  PlaylistEditApiException _translate(ApiException error) {
    final decoded = _decode(error.body);
    final serverKind = decoded?['error'];
    final kind = serverKind is String
        ? serverKind
        : error.statusCode == 502
        ? 'upstream'
        : error.statusCode == 409
        ? 'conflict'
        : 'invalid';
    final serverMessage = decoded?['message'];
    final fallback = error.statusCode == 400
        ? _genericInvalidError
        : _genericEditError;
    PlaylistEditView? draft;
    try {
      final rawDraft = decoded?['draft'];
      if (rawDraft is Map<String, dynamic>) {
        draft = PlaylistEditView.fromJson(rawDraft);
      }
    } catch (_) {
      draft = null;
    }
    return PlaylistEditApiException(
      kind: kind,
      message: serverMessage is String ? serverMessage : fallback,
      draft: draft,
    );
  }

  Map<String, dynamic>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }
}
