import 'dart:convert';

import '../api/api_client.dart';
import 'playlist_context_models.dart';

/// These conflicts concern playlist context, never the mix's queue version.
class PlaylistContextException extends ApiException {
  PlaylistContextException(super.statusCode, super.body, this.code);

  final String? code;
  bool get isStale => statusCode == 409 && code == 'stale';
  bool get isIneligible => statusCode == 409 && code == 'playlist_not_eligible';

  @override
  String toString() => 'PlaylistContextException($statusCode)';
}

class PlaylistContextApi {
  const PlaylistContextApi(this._client);

  // The caller owns the authenticated client's lifetime.
  final ApiClient _client;

  /// Null means an older server omitted the field, not a cleared attachment.
  Future<PlaylistSeedState?> getSessionSeed(String sessionId) async {
    final response = await _request(() async {
      final response = await _client.getJson(
        '/sessions/${Uri.encodeComponent(sessionId)}',
      );
      return response.body;
    });
    if (!response.containsKey('playlistSeed')) return null;
    return PlaylistSeedState.fromJson(
      playlistContextObject(response['playlistSeed']),
    );
  }

  Future<PlaylistSeedState> selectSeed(
    String sessionId, {
    required String? playlistId,
    required int expectedRevision,
    bool excludeSourceTracks = false,
  }) async {
    final response = await _request(() async {
      final response = await _client.putJson(
        '/sessions/${Uri.encodeComponent(sessionId)}/playlist-seed',
        {
          'playlistId': playlistId,
          'expectedRevision': expectedRevision,
          'excludeSourceTracks': excludeSourceTracks,
        },
      );
      return response.body;
    });
    return PlaylistSeedState.fromJson(
      playlistContextObject(response['playlistSeed']),
    );
  }

  /// Read the canonical playlist afterwards before presenting confirmed success.
  Future<void> confirmTaste(
    String playlistId, {
    required bool confirmed,
  }) async {
    final response = await _request(() async {
      final response = await _client.putJson(
        '/playlists/${Uri.encodeComponent(playlistId)}/taste-confirmation',
        {'confirmed': confirmed},
      );
      return response.body;
    });
    if (response['ok'] != true) throw const PlaylistContextModelException();
  }

  Future<Map<String, dynamic>> _request(Future<String> Function() call) async {
    late String body;
    try {
      body = await call();
    } on ApiException catch (error) {
      String? code;
      try {
        final value = jsonDecode(error.body);
        if (value is Map<String, dynamic> && value['error'] is String) {
          code = value['error'] as String;
        }
      } catch (_) {
        // Non-JSON failures retain their original HTTP status.
      }
      throw PlaylistContextException(error.statusCode, error.body, code);
    }
    try {
      return playlistContextObject(jsonDecode(body));
    } on FormatException {
      throw const PlaylistContextModelException();
    }
  }
}
