import 'dart:convert';

import '../api/api_client.dart';
import 'playlist_models.dart';

class PlaylistApi {
  const PlaylistApi(this._client);

  final ApiClient _client;

  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async {
    final path = Uri(
      path: '/playlists',
      queryParameters: {
        'status': status.wireValue,
        if (query != null) 'q': query,
        'limit': '$limit',
        if (cursor != null) 'cursor': cursor,
      },
    ).toString();
    final response = await _client.getJson(path);

    try {
      final json = _object(jsonDecode(response.body));
      final playlists = _list(json['playlists'])
          .map((value) => PlaylistSummary.fromJson(_object(value)))
          .toList(growable: false);
      return PlaylistPage(
        playlists: playlists,
        nextCursor: _optionalString(json['nextCursor']),
      );
    } on PlaylistModelException {
      rethrow;
    } catch (_) {
      throw const PlaylistModelException();
    }
  }

  Future<PlaylistDetail> get(
    String id, {
    int entryLimit = 200,
    String? entryCursor,
  }) async {
    final path = Uri(
      path: '/playlists/$id',
      queryParameters: {
        'entryLimit': '$entryLimit',
        if (entryCursor != null) 'entryCursor': entryCursor,
      },
    ).toString();
    final response = await _client.getJson(path);

    try {
      final json = _object(jsonDecode(response.body));
      final entries = _list(json['entries'])
          .map((value) => PlaylistEntry.fromJson(_object(value)))
          .toList(growable: false);
      return PlaylistDetail(
        playlist: PlaylistSummary.fromJson(_object(json['playlist'])),
        entries: entries,
        nextEntryCursor: _optionalString(json['nextEntryCursor']),
      );
    } on PlaylistModelException {
      rethrow;
    } catch (_) {
      throw const PlaylistModelException();
    }
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) throw const PlaylistModelException();
  return value;
}

List<dynamic> _list(Object? value) {
  if (value is! List<dynamic>) throw const PlaylistModelException();
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}
