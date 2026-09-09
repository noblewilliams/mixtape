import '../../import/collection_review.dart';
import 'dart:convert';

import '../api/api_client.dart';
import 'listening_models.dart';

/// Typed client for the listening-export import protocol
/// (`/ingest/listening/*`), the Spotify-export playlist sync
/// (`/ingest/playlists/syncs` with `source: 'spotify_export'`), and the
/// onboarding, funnel, interview, and seed routes under `/me`.
///
/// Errors follow the rest of the data layer: a 4xx/5xx is the
/// [ApiClient]'s [ApiException] (read its code with
/// [ListeningApiErrorCode.of]), a transport failure is [NetworkException],
/// and a 2xx body that does not fit its model is [ListeningModelException].
class ListeningApi {
  const ListeningApi(this._client, {this.surface = 'ios'});

  final ApiClient _client;

  /// The `surface` every funnel event and interview carries.
  final String surface;

  static const String playlistSyncSource = 'spotify_export';

  Future<CollectionContext> getCollectionReview() async =>
      CollectionContext.fromJson(
        _decode(
          (await _client.getJson('/ingest/listening/spotify/review')).body,
        ),
      );

  Future<ListeningImportRun> beginImport(BeginListeningImport body) async {
    final response = await _client.postJson(
      '/ingest/listening/imports',
      body.toJson(),
    );
    return ListeningImportRun.fromJson(_decode(response.body));
  }

  Future<int> putTracks(String importId, List<Map<String, Object?>> rows) =>
      _putChunk('/ingest/listening/imports/$importId/tracks', {'tracks': rows});

  Future<int> putDays(String importId, List<Map<String, Object?>> rows) =>
      _putChunk('/ingest/listening/imports/$importId/days', {'days': rows});

  Future<int> putLibrary(String importId, List<Map<String, Object?>> rows) =>
      _putChunk('/ingest/listening/imports/$importId/library', {
        'tracks': rows,
      });

  Future<int> putArtists(String importId, List<Map<String, Object?>> rows) =>
      _putChunk('/ingest/listening/imports/$importId/artists', {
        'artists': rows,
      });

  Future<ListeningImportSummary> completeImport(String importId) async {
    final response = await _client.postJson(
      '/ingest/listening/imports/$importId/complete',
      const <String, Object?>{},
    );
    return ListeningImportSummary.fromJson(_decode(response.body));
  }

  Future<DeleteSourceResult> deleteSource(String source) async {
    final response = await _client.deleteJson(
      '/ingest/listening/sources/$source',
    );
    return DeleteSourceResult.fromJson(_decode(response.body));
  }

  /// Opens a playlist sync for the Spotify export. A Spotify export carries
  /// no Apple storefront, and the server refuses one.
  Future<PlaylistSyncRun> beginPlaylistSync({
    required int expectedPlaylists,
    required int expectedEntries,
    List<Map<String, Object?>>? review,
  }) async {
    final response = await _client.postJson('/ingest/playlists/syncs', {
      if (review != null) 'review': review,
      'source': playlistSyncSource,
      'storefront': null,
      'expectedPlaylists': expectedPlaylists,
      'expectedEntries': expectedEntries,
    });
    return PlaylistSyncRun.fromJson(_decode(response.body));
  }

  Future<int> putPlaylists(
    String syncId,
    List<Map<String, Object?>> playlists,
  ) => _putChunk('/ingest/playlists/syncs/$syncId/playlists', {
    'playlists': playlists,
  });

  Future<int> putPlaylistEntries(
    String syncId,
    String playlistAppleId,
    List<Map<String, Object?>> entries,
  ) => _putChunk('/ingest/playlists/syncs/$syncId/entries', {
    'playlistAppleId': playlistAppleId,
    'entries': entries,
  });

  Future<PlaylistSyncSummary> completePlaylistSync(String syncId) async {
    final response = await _client.postJson(
      '/ingest/playlists/syncs/$syncId/complete',
      const <String, Object?>{},
    );
    return PlaylistSyncSummary.fromJson(_decode(response.body));
  }

  Future<OnboardingState> getOnboarding() async {
    final response = await _client.getJson('/me/onboarding');
    return OnboardingState.fromJson(_decode(response.body));
  }

  Future<List<MusicSource>> getMusicSources() async {
    final response = await _client.getJson('/me/music-sources');
    return musicSourcesFromJson(_decode(response.body)['sources']);
  }

  /// Records one funnel step. Callers that must never block or fail on it
  /// wrap this fire-and-forget (see the import service).
  Future<void> postFunnelEvent(FunnelEventType type) async {
    await _client.postJson('/me/funnel-events', {
      'type': type.wire,
      'surface': surface,
    });
  }

  Future<InterviewResult> postInterview(InterviewAnswers answers) async {
    final response = await _client.postJson(
      '/me/interview',
      answers.toJson(surface),
    );
    return InterviewResult.fromJson(_decode(response.body));
  }

  Future<List<ArtistSeed>> getArtistSeeds() async {
    final response = await _client.getJson('/me/artist-seeds');
    return artistSeedsFromJson(_decode(response.body)['seeds']);
  }

  /// Replaces the interview-sourced seeds; answers with the full list.
  Future<List<ArtistSeed>> putArtistSeeds(List<String> names) async {
    final response = await _client.putJson('/me/artist-seeds', {
      'names': names,
    });
    return artistSeedsFromJson(_decode(response.body)['seeds']);
  }

  Future<List<SeedTrack>> getSeedTracks() async {
    final response = await _client.getJson('/me/seed-tracks');
    return asList(_decode(response.body)['tracks'])
        .map((value) => SeedTrack.fromJson(asObject(value)))
        .toList(growable: false);
  }

  Future<SeedTracksResult> postSeedTracks(List<String> spotifyIds) async {
    final response = await _client.postJson('/me/seed-tracks', {
      'spotifyIds': spotifyIds,
    });
    return SeedTracksResult.fromJson(_decode(response.body));
  }

  Future<DeleteSeedTrackResult> deleteSeedTrack(String trackId) async {
    final response = await _client.deleteJson('/me/seed-tracks/$trackId');
    return DeleteSeedTrackResult.fromJson(_decode(response.body));
  }

  Future<int> _putChunk(String path, Map<String, Object?> body) async {
    final response = await _client.putJson(path, body);
    return readNonnegativeInt(_decode(response.body), 'accepted');
  }

  Map<String, dynamic> _decode(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const ListeningModelException();
    }
    return asObject(decoded);
  }
}
