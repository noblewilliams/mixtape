import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native library paging filters unsupported Apple catalog IDs', () {
    final source = File('ios/Runner/MusicKitBridge.swift').readAsStringSync();

    expect(source, contains(r'^[A-Za-z0-9._~-]{1,128}$'));
    expect(source, contains('isSupportedAppleSongID'));
    expect(
      source,
      contains(r'isSupportedAppleSongID($0.playbackStoreID)'),
    );
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
}
