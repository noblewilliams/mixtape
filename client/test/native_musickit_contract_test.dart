import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native library paging filters unsupported Apple catalog IDs', () {
    final source = File('ios/Runner/MusicKitBridge.swift').readAsStringSync();

    expect(source, contains(r'^[A-Za-z0-9._~-]{1,128}$'));
    expect(source, contains('isSupportedAppleSongID'));
    expect(source, contains(r'isSupportedAppleSongID($0.playbackStoreID)'));
  });

  test('native playlist snapshots stay behind one cancellable actor', () {
    final bridge = File('ios/Runner/MusicKitBridge.swift').readAsStringSync();
    final store = File(
      'ios/Runner/PlaylistSnapshotStore.swift',
    ).readAsStringSync();

    expect(store, contains('actor PlaylistSnapshotStore'));
    expect(store, contains('MusicLibraryRequest<Playlist>'));
    expect(store, contains('preferredSource: .library'));
    expect(store, contains('MusicDataRequest.currentCountryCode'));
    expect(store, contains('nextBatch'));
    expect(store, contains('Task.checkCancellation()'));
    expect(store, contains('enumerated()'));
    expect(store, contains('SHA256.hash'));
    expect(store, contains('artworkBgColor'));
    expect(store, contains('maxPlaylists'));
    expect(store, contains('maxEntries'));
    expect(store, contains('maxOpaqueIdLength = 512'));
    expect(store, contains('maxArtworkUrlLength = 2_048'));
    expect(store, contains('validOpaqueId'));
    expect(store, contains('boundedRequiredText'));
    expect(store, contains('normalizedISRC'));
    expect(store, contains('validArtworkURL'));
    expect(store, isNot(contains('MusicLibrary.shared.add')));
    expect(store, isNot(contains('createPlaylist')));
    expect(store, isNot(contains('MusicLibrary.shared.edit')));

    for (final method in [
      'beginPlaylistSnapshot',
      'fetchPlaylistSnapshotPage',
      'fetchPlaylistEntryPage',
      'cancelPlaylistSnapshot',
      'releasePlaylistSnapshot',
    ]) {
      expect(bridge, contains('case "$method"'));
    }
  });

  test('native playlist snapshots derive exact typed catalog identity', () {
    final store = File(
      'ios/Runner/PlaylistSnapshotStore.swift',
    ).readAsStringSync();

    expect(store, contains('struct PlaylistEntryCatalogIdentity'));
    expect(store, contains('entry.playParameters'));
    expect(store, contains('item?.playParameters'));
    expect(store, contains('entry.url'));
    expect(store, contains('item?.url'));
    expect(store, contains('struct LibrarySongCatalogCrosswalk'));
    expect(store, contains('MusicLibraryRequest<Song>()'));
    expect(store, contains(r'filter(matching: \.id, memberOf:'));
    expect(store, contains('song.isrc'));
    expect(store, isNot(contains('MusicDataRequest(urlRequest: request)')));
    expect(store, isNot(contains('/v1/me/library/songs')));
    expect(store, isNot(contains('titleSnapshot.lowercased()')));
    expect(store, isNot(contains('artistSnapshot.lowercased()')));
  });
}
