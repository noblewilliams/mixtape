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

  test('Info.plist lets Files hand ZIP archives to the app', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>CFBundleDocumentTypes</key>'));
    expect(plist, contains('<string>public.zip-archive</string>'));
    expect(plist, contains('<key>CFBundleTypeRole</key>\n\t\t\t<string>Viewer</string>'));
    expect(plist, contains('<key>LSHandlerRank</key>\n\t\t\t<string>Alternate</string>'));
    expect(plist, contains('<key>LSSupportsOpeningDocumentsInPlace</key>\n\t<true/>'));
    // "Open in Spotify" probes the app scheme before falling back to https
    // (queue_screen.dart); iOS answers canOpenURL only for declared schemes.
    expect(
      plist,
      contains('<key>LSApplicationQueriesSchemes</key>\n\t<array>\n\t\t<string>spotify</string>\n\t</array>'),
    );
    // The share-sheet path (C5) goes through the document type above, so
    // there is still no custom URL scheme to declare.
    expect(plist, isNot(contains('CFBundleURLTypes')));
  });

  test('a ZIP handed to the app is copied out of its security scope and passed to Dart', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    // The document-type open path. The launch options carry the same URL on
    // a cold start and the open hook runs straight after, so copying there
    // as well would leave a second copy of the export behind: one path only.
    expect(source, contains('open url: URL'));
    expect(source, isNot(contains('launchOptions?[.url]')));
    // A document opened in place is only readable inside its scope, so the
    // file is copied into our own temporary directory under a fresh name
    // before the scope ends and the import reads it. The scope is balanced
    // by a `defer` on the acquire, so no return path can leak it.
    expect(
      source,
      contains(
        'let scoped = url.startAccessingSecurityScopedResource()\n'
        '    defer {\n'
        '      if scoped { url.stopAccessingSecurityScopedResource() }\n'
        '    }',
      ),
    );
    expect(source, contains('temporaryDirectory'));
    expect(source, contains('UUID().uuidString'));
    // The channel Dart listens on, plus the buffer a cold start drains.
    expect(source, contains('mixtape/open-archive'));
    expect(source, contains('invokeMethod("onOpenedArchive"'));
    expect(source, contains('case "getPendingArchive"'));
    expect(source, contains('pendingArchive = nil'));
    // A file that could not be copied at all is said so by name, rather than
    // silently doing nothing.
    expect(source, contains('"error": "unreadable"'));
    // The name of a listener's export file is theirs: never logged.
    expect(source, isNot(contains('print(')));
    expect(source, isNot(contains('NSLog')));
  });

  test('the copies of handed-over archives never outlive the import that reads them', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    // Everything under tmp/opened-archives is a listener's whole export —
    // the identity and payment files the parser refuses to read included.
    expect(source, contains('"opened-archives"'));
    // A copy from a previous launch is dead: the import that would have read
    // it went with the process, so the directory is emptied before anything
    // else runs.
    final launch = source.indexOf('didFinishLaunchingWithOptions launchOptions');
    final purge = source.indexOf('purgeOpenedArchives()', launch);
    expect(purge, greaterThan(launch));
    expect(purge, lessThan(source.indexOf('GeneratedPluginRegistrant', launch)));
    expect(source, contains('removeItem(at: openedArchivesDirectory)'));
    // Dart deletes each copy the moment its import is over, and only ever
    // our own copies: a path anywhere else is refused, not deleted.
    expect(source, contains('case "deleteOpenedArchive"'));
    expect(source, contains('hasPrefix(root.path + "/")'));
    // Mail and "Copy to Mixtape" hand the file over through our own Inbox;
    // that copy is ours to remove once it has been copied.
    expect(source, contains('Inbox'));
    expect(source, contains('removeItem(at: url)'));
  });
}
