/// Listening-export import, onboarding, and seed models — mirrors the
/// server contracts in `server/src/listening/contracts.ts`,
/// `server/src/seeds/contracts.ts`, and the `/me/onboarding`,
/// `/me/music-sources`, `/me/funnel-events`, `/me/interview`,
/// `/me/artist-seeds`, and `/me/seed-tracks` routes. Manual `fromJson`
/// (no codegen), matching the rest of the data layer; a response that does
/// not fit throws [ListeningModelException].
library;

import 'dart:convert';

import '../api/api_client.dart';

class ListeningModelException implements Exception {
  const ListeningModelException();

  @override
  String toString() => 'ListeningModelException';
}

/// The `error` codes the listening, playlist, and seed routes answer with.
/// Every other body (zod detail objects, plain text) reads as null.
enum ListeningApiErrorCode {
  notFound('not_found'),
  syncConflict('sync_conflict'),
  invalidState('invalid_state'),
  countMismatch('count_mismatch'),
  invalidId('invalid_id'),
  invalidRequest('invalid_request'),
  invalidStorefront('invalid_storefront'),
  upstream('upstream');

  const ListeningApiErrorCode(this.wire);

  final String wire;

  static ListeningApiErrorCode? fromWire(String? value) {
    for (final code in values) {
      if (code.wire == value) return code;
    }
    return null;
  }

  /// Reads the `{ error: code }` body of a failed response.
  static ListeningApiErrorCode? of(ApiException error) {
    Object? decoded;
    try {
      decoded = jsonDecode(error.body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final code = decoded['error'];
    return code is String ? fromWire(code) : null;
  }
}

/// Body of `POST /ingest/listening/imports`. The source is always the
/// Spotify export on this client; the package says which chunk types the
/// run carries (a type the package lacks must be expected as zero).
class BeginListeningImport {
  const BeginListeningImport({
    this.source = 'spotify_export',
    required this.package,
    required this.timeZone,
    required this.country,
    required this.expectedTracks,
    required this.expectedDays,
    required this.expectedLibraryTracks,
    required this.expectedArtists,
    required this.unresolvedRows,
    required this.unresolvedPlays,
  });

  final String source;
  final String package;
  final String timeZone;
  final String? country;
  final int expectedTracks;
  final int expectedDays;
  final int expectedLibraryTracks;
  final int expectedArtists;
  final int unresolvedRows;
  final int unresolvedPlays;

  Map<String, Object?> toJson() => {
        'source': source,
        'package': package,
        'timeZone': timeZone,
        'country': country,
        'expectedTracks': expectedTracks,
        'expectedDays': expectedDays,
        'expectedLibraryTracks': expectedLibraryTracks,
        'expectedArtists': expectedArtists,
        'unresolvedRows': unresolvedRows,
        'unresolvedPlays': unresolvedPlays,
      };
}

class ListeningImportRun {
  const ListeningImportRun({required this.importId, required this.expiresAt});

  final String importId;
  final DateTime expiresAt;

  factory ListeningImportRun.fromJson(Map<String, dynamic> json) => ListeningImportRun(
        importId: readString(json, 'importId'),
        expiresAt: readEpochMillis(json, 'expiresAt'),
      );
}

class ListeningImportSummary {
  const ListeningImportSummary({
    required this.tracks,
    required this.days,
    required this.libraryTracks,
    required this.artists,
    required this.unresolvedRows,
    required this.unresolvedPlays,
    required this.ledgerFrom,
    required this.ledgerTo,
    required this.likedRemoved,
    required this.likedRemovalSkipped,
  });

  final int tracks;
  final int days;
  final int libraryTracks;
  final int artists;
  final int unresolvedRows;
  final int unresolvedPlays;

  /// Bounds of this source's ledger after the run (`YYYY-MM-DD`); null for a
  /// package with no days.
  final String? ledgerFrom;
  final String? ledgerTo;

  /// Account re-import: liked rows marked out of the library, or the removal
  /// skipped because a live Apple library owns library membership.
  final int likedRemoved;
  final bool likedRemovalSkipped;

  factory ListeningImportSummary.fromJson(Map<String, dynamic> json) => ListeningImportSummary(
        tracks: readNonnegativeInt(json, 'tracks'),
        days: readNonnegativeInt(json, 'days'),
        libraryTracks: readNonnegativeInt(json, 'libraryTracks'),
        artists: readNonnegativeInt(json, 'artists'),
        unresolvedRows: readNonnegativeInt(json, 'unresolvedRows'),
        unresolvedPlays: readNonnegativeInt(json, 'unresolvedPlays'),
        ledgerFrom: readOptionalString(json, 'ledgerFrom'),
        ledgerTo: readOptionalString(json, 'ledgerTo'),
        likedRemoved: readNonnegativeInt(json, 'likedRemoved'),
        likedRemovalSkipped: readBool(json, 'likedRemovalSkipped'),
      );
}

class DeleteSourceResult {
  const DeleteSourceResult({
    required this.deletedDays,
    required this.deletedTracks,
    required this.unlibraried,
  });

  final int deletedDays;
  final int deletedTracks;
  final int unlibraried;

  factory DeleteSourceResult.fromJson(Map<String, dynamic> json) => DeleteSourceResult(
        deletedDays: readNonnegativeInt(json, 'deletedDays'),
        deletedTracks: readNonnegativeInt(json, 'deletedTracks'),
        unlibraried: readNonnegativeInt(json, 'unlibraried'),
      );
}

class PlaylistSyncRun {
  const PlaylistSyncRun({required this.syncId, required this.expiresAt});

  final String syncId;
  final DateTime expiresAt;

  factory PlaylistSyncRun.fromJson(Map<String, dynamic> json) => PlaylistSyncRun(
        syncId: readString(json, 'syncId'),
        expiresAt: readEpochMillis(json, 'expiresAt'),
      );
}

class PlaylistSyncSummary {
  const PlaylistSyncSummary({
    required this.playlists,
    required this.entries,
    required this.resolvedEntries,
    required this.unresolvedEntries,
  });

  final int playlists;
  final int entries;
  final int resolvedEntries;
  final int unresolvedEntries;

  factory PlaylistSyncSummary.fromJson(Map<String, dynamic> json) => PlaylistSyncSummary(
        playlists: readNonnegativeInt(json, 'playlists'),
        entries: readNonnegativeInt(json, 'entries'),
        resolvedEntries: readNonnegativeInt(json, 'resolvedEntries'),
        unresolvedEntries: readNonnegativeInt(json, 'unresolvedEntries'),
      );
}

/// One connected source, as `/me/music-sources` and `/me/onboarding` list
/// them. A bare row (begin registered the source, nothing landed) has a null
/// [lastImportedAt].
class MusicSource {
  const MusicSource({
    required this.source,
    required this.connectedAt,
    required this.lastImportedAt,
    required this.ledgerFrom,
    required this.ledgerTo,
  });

  /// `apple_live`, `apple_export`, or `spotify_export`.
  final String source;
  final DateTime connectedAt;
  final DateTime? lastImportedAt;
  final String? ledgerFrom;
  final String? ledgerTo;

  factory MusicSource.fromJson(Map<String, dynamic> json) => MusicSource(
        source: readString(json, 'source'),
        connectedAt: readDate(json, 'connectedAt'),
        lastImportedAt: readOptionalDate(json, 'lastImportedAt'),
        ledgerFrom: readOptionalString(json, 'ledgerFrom'),
        ledgerTo: readOptionalString(json, 'ledgerTo'),
      );
}

class OnboardingState {
  const OnboardingState({
    required this.userId,
    required this.sources,
    required this.hasLibrary,
    required this.chosenService,
    required this.markedRequestedAt,
    required this.interviewCompletedAt,
    required this.importCompletedAt,
  });

  /// The signed-in listener, so device-local state (the "service chosen"
  /// flag) can be keyed per account.
  final String userId;
  final List<MusicSource> sources;
  final bool hasLibrary;

  /// `spotify`, `apple`, or null when the listener has not chosen yet.
  final String? chosenService;
  final DateTime? markedRequestedAt;
  final DateTime? interviewCompletedAt;
  final DateTime? importCompletedAt;

  factory OnboardingState.fromJson(Map<String, dynamic> json) => OnboardingState(
        userId: readString(json, 'userId'),
        sources: musicSourcesFromJson(json['sources']),
        hasLibrary: readBool(json, 'hasLibrary'),
        chosenService: readOptionalString(json, 'chosenService'),
        markedRequestedAt: readOptionalDate(json, 'markedRequestedAt'),
        interviewCompletedAt: readOptionalDate(json, 'interviewCompletedAt'),
        importCompletedAt: readOptionalDate(json, 'importCompletedAt'),
      );

  /// This state with the device-local service choice overlaid.
  OnboardingState withChosenService(String service) => OnboardingState(
        userId: userId,
        sources: sources,
        hasLibrary: hasLibrary,
        chosenService: service,
        markedRequestedAt: markedRequestedAt,
        interviewCompletedAt: interviewCompletedAt,
        importCompletedAt: importCompletedAt,
      );
}

List<MusicSource> musicSourcesFromJson(Object? json) =>
    asList(json).map((value) => MusicSource.fromJson(asObject(value))).toList(growable: false);

/// The funnel steps this client posts, in funnel order; the server records
/// `interview_completed` itself.
enum FunnelEventType {
  choseSpotify('chose_spotify'),
  markedRequested('marked_requested'),
  fileInspected('file_inspected'),
  importCompleted('import_completed'),
  firstPersonalMix('first_personal_mix'),
  firstOutput('first_output');

  const FunnelEventType(this.wire);

  final String wire;
}

/// The five-turn interview the waiting state runs before any mix.
class InterviewAnswers {
  const InterviewAnswers({
    required this.neverSkip,
    required this.playsMost,
    required this.listensWhen,
    required this.neverWants,
    required this.era,
  });

  final List<String> neverSkip;
  final String playsMost;
  final String listensWhen;
  final String neverWants;
  final String era;

  Map<String, Object?> toJson(String surface) => {
        'surface': surface,
        'neverSkip': List<String>.of(neverSkip),
        'playsMost': playsMost,
        'listensWhen': listensWhen,
        'neverWants': neverWants,
        'era': era,
      };
}

class InterviewResult {
  const InterviewResult({
    required this.seeds,
    required this.notesSaved,
    required this.notesDuplicate,
    required this.notesCapped,
  });

  final int seeds;
  final int notesSaved;
  final int notesDuplicate;
  final int notesCapped;

  factory InterviewResult.fromJson(Map<String, dynamic> json) {
    final notes = asObject(json['notes']);
    return InterviewResult(
      seeds: readNonnegativeInt(json, 'seeds'),
      notesSaved: readNonnegativeInt(notes, 'saved'),
      notesDuplicate: readNonnegativeInt(notes, 'duplicate'),
      notesCapped: readNonnegativeInt(notes, 'capped'),
    );
  }
}

class ArtistSeed {
  const ArtistSeed({
    required this.name,
    required this.spotifyId,
    required this.source,
    required this.createdAt,
  });

  final String name;
  final String? spotifyId;

  /// `interview`, `pasted`, or `export`.
  final String source;
  final DateTime createdAt;

  factory ArtistSeed.fromJson(Map<String, dynamic> json) => ArtistSeed(
        name: readString(json, 'name'),
        spotifyId: readOptionalString(json, 'spotifyId'),
        source: readString(json, 'source'),
        createdAt: readDate(json, 'createdAt'),
      );
}

List<ArtistSeed> artistSeedsFromJson(Object? json) =>
    asList(json).map((value) => ArtistSeed.fromJson(asObject(value))).toList(growable: false);

class SeedTrack {
  const SeedTrack({
    required this.trackId,
    required this.spotifyId,
    required this.title,
    required this.artist,
    required this.album,
  });

  final String trackId;
  final String? spotifyId;
  final String title;
  final String artist;
  final String? album;

  factory SeedTrack.fromJson(Map<String, dynamic> json) => SeedTrack(
        trackId: readString(json, 'trackId'),
        spotifyId: readOptionalString(json, 'spotifyId'),
        title: readString(json, 'title'),
        artist: readString(json, 'artist'),
        album: readOptionalString(json, 'album'),
      );
}

class ResolvedSeedTrack {
  const ResolvedSeedTrack({
    required this.spotifyId,
    required this.trackId,
    required this.title,
    required this.artist,
  });

  final String spotifyId;
  final String trackId;
  final String title;
  final String artist;

  factory ResolvedSeedTrack.fromJson(Map<String, dynamic> json) => ResolvedSeedTrack(
        spotifyId: readString(json, 'spotifyId'),
        trackId: readString(json, 'trackId'),
        title: readString(json, 'title'),
        artist: readString(json, 'artist'),
      );
}

class SeedTracksResult {
  const SeedTracksResult({required this.resolved, required this.unresolved});

  final List<ResolvedSeedTrack> resolved;

  /// The pasted ids that did not become a track, in request order.
  final List<String> unresolved;

  factory SeedTracksResult.fromJson(Map<String, dynamic> json) => SeedTracksResult(
        resolved: asList(json['resolved'])
            .map((value) => ResolvedSeedTrack.fromJson(asObject(value)))
            .toList(growable: false),
        unresolved: asList(json['unresolved']).map((value) {
          if (value is! String) throw const ListeningModelException();
          return value;
        }).toList(growable: false),
      );
}

class DeleteSeedTrackResult {
  const DeleteSeedTrackResult({required this.removed, required this.deleted});

  final bool removed;

  /// True when the user_tracks row itself went (nothing else kept it).
  final bool deleted;

  factory DeleteSeedTrackResult.fromJson(Map<String, dynamic> json) => DeleteSeedTrackResult(
        removed: readBool(json, 'removed'),
        deleted: readBool(json, 'deleted'),
      );
}

// Field readers shared by every model above and by ListeningApi.

Map<String, dynamic> asObject(Object? value) {
  if (value is! Map<String, dynamic>) throw const ListeningModelException();
  return value;
}

List<dynamic> asList(Object? value) {
  if (value is! List<dynamic>) throw const ListeningModelException();
  return value;
}

String readString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw const ListeningModelException();
  return value;
}

String? readOptionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw const ListeningModelException();
  return value;
}

bool readBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw const ListeningModelException();
  return value;
}

int readNonnegativeInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw const ListeningModelException();
  return value;
}

DateTime readEpochMillis(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw const ListeningModelException();
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

DateTime readDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw const ListeningModelException();
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const ListeningModelException();
  return parsed;
}

DateTime? readOptionalDate(Map<String, dynamic> json, String key) =>
    json[key] == null ? null : readDate(json, key);
