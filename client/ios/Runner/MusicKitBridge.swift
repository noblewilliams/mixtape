import Flutter
import MediaPlayer
import MusicKit

/// Bridges the on-device music library (MediaPlayer) to Dart.
/// P1 scope: authorization + paged library read with play counts.
class MusicKitBridge: NSObject {
  private static let queue = DispatchQueue(label: "mixtape.musickit.bridge")
  private static var catalogCache: [MPMediaItem] = []
  private static let playlistSnapshots = PlaylistSnapshotStore()

  /// MusicKit declares playbackStoreID as opaque. Keep a bounded set of URL-
  /// safe, comma-free characters that matches the server/catalog contract.
  private static func isSupportedAppleSongID(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9._~-]{1,128}$"#,
      options: .regularExpression
    ) != nil
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/musickit", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestAuthorization":
        requestAuthorization(result: result)
      case "fetchLibrarySongs":
        let args = call.arguments as? [String: Any] ?? [:]
        let offset = max(0, args["offset"] as? Int ?? 0)
        let limit = max(0, args["limit"] as? Int ?? 200)
        fetchLibrarySongs(offset: offset, limit: limit, result: result)
      case "beginPlaylistSnapshot":
        beginPlaylistSnapshot(result: result)
      case "fetchPlaylistSnapshotPage":
        let args = call.arguments as? [String: Any] ?? [:]
        fetchPlaylistSnapshotPage(args: args, result: result)
      case "fetchPlaylistEntryPage":
        let args = call.arguments as? [String: Any] ?? [:]
        fetchPlaylistEntryPage(args: args, result: result)
      case "cancelPlaylistSnapshot":
        cancelPlaylistSnapshot(result: result)
      case "releasePlaylistSnapshot":
        let args = call.arguments as? [String: Any] ?? [:]
        releasePlaylistSnapshot(args: args, result: result)
      case "playQueue":
        let args = call.arguments as? [String: Any] ?? [:]
        let appleIds = args["appleIds"] as? [String] ?? []
        playQueue(appleIds: appleIds, result: result)
      case "createPlaylist":
        let args = call.arguments as? [String: Any] ?? [:]
        let name = args["name"] as? String ?? ""
        let appleIds = args["appleIds"] as? [String] ?? []
        let author = args["author"] as? String
        let description = args["description"] as? String
        createPlaylist(
          name: name, appleIds: appleIds, author: author,
          description: description, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Playback hand-off
  //
  // Hand-off: once we call play(), playback lives in the Music app via the
  // system player — it survives our app closing. MPMusicPlayerController is
  // main-thread-only (unlike the library-read path above), so this runs
  // entirely on the main thread rather than the serial `queue` used for
  // fetchLibrarySongs.
  private static func playQueue(appleIds: [String], result: @escaping FlutterResult) {
    guard !appleIds.isEmpty else {
      result(FlutterError(code: "empty_queue", message: "cannot play an empty queue", details: nil))
      return
    }
    DispatchQueue.main.async {
      let player = MPMusicPlayerController.systemMusicPlayer
      player.setQueue(with: appleIds)
      player.prepareToPlay { error in
        DispatchQueue.main.async {
          guard error == nil else {
            result(FlutterError(
              code: "play_failed",
              message: "could not start playback",
              details: error?.localizedDescription
            ))
            return
          }
          player.play()
          result(true)
        }
      }
    }
  }

  // MARK: - Playlist creation

  private static func createPlaylist(
    name: String, appleIds: [String], author: String?, description: String?,
    result: @escaping FlutterResult
  ) {
    guard !name.isEmpty, !appleIds.isEmpty else {
      result(FlutterError(code: "empty_playlist", message: "name and tracks are required", details: nil))
      return
    }
    Task { @MainActor in
      do {
        // Resolve exact songs before creating anything. Do not guess a
        // MusicKit ID from a MediaPlayer persistent ID or playlist metadata.
        var songs: [String: Song] = [:]
        let validIds = Array(Set(appleIds.filter { isSupportedAppleSongID($0) })).sorted()
        for offset in stride(from: 0, to: validIds.count, by: 25) {
          let ids = Array(validIds[offset..<min(offset + 25, validIds.count)])
          let request = MusicCatalogResourceRequest<Song>(matching: \.id,
            memberOf: ids.map { MusicItemID($0) })
          let response = try await request.response()
          for song in response.items where ids.contains(song.id.rawValue) {
            songs[song.id.rawValue] = song
          }
        }
        guard !songs.isEmpty else {
          result(FlutterError(code: "playlist_failed", message: "No songs could be resolved.", details: nil))
          return
        }
        var playlist = try await MusicLibrary.shared.createPlaylist(
          name: name, description: description, authorDisplayName: author)
        let libraryId = playlist.id.rawValue
        var added = 0
        var failed = 0
        // Sequential additions preserve requested order and duplicate entries.
        // Once creation succeeds, always report its ID, including partial saves.
        for id in appleIds {
          guard let song = songs[id] else { failed += 1; continue }
          do {
            playlist = try await MusicLibrary.shared.add(song, to: playlist)
            added += 1
          } catch {
            failed += 1
          }
        }
        result(["added": added, "failed": failed, "appleLibraryId": libraryId])
      } catch {
        result(FlutterError(code: "playlist_failed", message: "Could not create playlist.", details: nil))
      }
    }
  }

  private static func requestAuthorization(result: @escaping FlutterResult) {
    MPMediaLibrary.requestAuthorization { status in
      DispatchQueue.main.async { result(status == .authorized) }
    }
  }

  // MARK: - Immutable playlist snapshot

  private static func beginPlaylistSnapshot(result: @escaping FlutterResult) {
    Task {
      do {
        let header = try await playlistSnapshots.begin()
        completeOnMain(result, value: [
          "snapshotId": header.snapshotId,
          "storefront": header.storefront,
          "totalPlaylists": header.totalPlaylists,
          "totalEntries": header.totalEntries,
        ])
      } catch {
        completeSnapshotError(result, error: error)
      }
    }
  }

  private static func fetchPlaylistSnapshotPage(
    args: [String: Any], result: @escaping FlutterResult
  ) {
    guard
      let snapshotId = args["snapshotId"] as? String, !snapshotId.isEmpty,
      let offset = args["offset"] as? Int, offset >= 0,
      let requestedLimit = args["limit"] as? Int
    else {
      completeSnapshotError(result, code: "invalid_arguments")
      return
    }
    let limit = min(50, max(1, requestedLimit))
    Task {
      do {
        let page = try await playlistSnapshots.playlistPage(
          snapshotId: snapshotId, offset: offset, limit: limit)
        let values: [[String: Any?]] = page.values.map { playlist in
          [
            "appleLibraryId": playlist.appleLibraryId,
            "appleCatalogId": playlist.appleCatalogId,
            "name": playlist.name,
            "description": playlist.description,
            "curatorName": playlist.curatorName,
            "artworkUrlTemplate": playlist.artworkUrlTemplate,
            "artworkWidth": playlist.artworkWidth,
            "artworkHeight": playlist.artworkHeight,
            "artworkBgColor": playlist.artworkBgColor,
            "kind": playlist.kind,
            "canEdit": playlist.canEdit,
            "appleDateAdded": playlist.appleDateAdded,
            "appleLastModifiedAt": playlist.appleLastModifiedAt,
            "sourceFingerprint": playlist.sourceFingerprint,
            "entryCount": playlist.entries.count,
          ]
        }
        completeOnMain(result, value: ["playlists": values, "total": page.total])
      } catch {
        completeSnapshotError(result, error: error)
      }
    }
  }

  private static func fetchPlaylistEntryPage(
    args: [String: Any], result: @escaping FlutterResult
  ) {
    guard
      let snapshotId = args["snapshotId"] as? String, !snapshotId.isEmpty,
      let playlistId = args["playlistAppleId"] as? String, !playlistId.isEmpty,
      let offset = args["offset"] as? Int, offset >= 0,
      let requestedLimit = args["limit"] as? Int
    else {
      completeSnapshotError(result, code: "invalid_arguments")
      return
    }
    let limit = min(200, max(1, requestedLimit))
    Task {
      do {
        let page = try await playlistSnapshots.entryPage(
          snapshotId: snapshotId, playlistId: playlistId, offset: offset, limit: limit)
        let values: [[String: Any?]] = page.values.map { entry in
          [
            "position": entry.position,
            "appleLibraryEntryId": entry.appleLibraryEntryId,
            "appleLibraryTrackId": entry.appleLibraryTrackId,
            "appleCatalogId": entry.appleCatalogId,
            "isrcSnapshot": entry.isrcSnapshot,
            "titleSnapshot": entry.titleSnapshot,
            "artistSnapshot": entry.artistSnapshot,
            "albumSnapshot": entry.albumSnapshot,
            "durationMsSnapshot": entry.durationMsSnapshot,
            "artworkUrlTemplateSnapshot": entry.artworkUrlTemplateSnapshot,
            "artworkWidthSnapshot": entry.artworkWidthSnapshot,
            "artworkHeightSnapshot": entry.artworkHeightSnapshot,
            "artworkBgColorSnapshot": entry.artworkBgColorSnapshot,
          ]
        }
        completeOnMain(result, value: ["entries": values, "total": page.total])
      } catch {
        completeSnapshotError(result, error: error)
      }
    }
  }

  private static func cancelPlaylistSnapshot(result: @escaping FlutterResult) {
    Task {
      let cancelled = await playlistSnapshots.cancel()
      completeOnMain(result, value: cancelled)
    }
  }

  private static func releasePlaylistSnapshot(
    args: [String: Any], result: @escaping FlutterResult
  ) {
    guard let snapshotId = args["snapshotId"] as? String, !snapshotId.isEmpty else {
      completeSnapshotError(result, code: "invalid_arguments")
      return
    }
    Task {
      do {
        let released = try await playlistSnapshots.release(snapshotId: snapshotId)
        completeOnMain(result, value: released)
      } catch {
        completeSnapshotError(result, error: error)
      }
    }
  }

  private static func completeSnapshotError(
    _ result: @escaping FlutterResult, error: Error
  ) {
    if let storeError = error as? PlaylistSnapshotStore.StoreError {
      completeSnapshotError(result, code: storeError.rawValue)
    } else if error is CancellationError {
      completeSnapshotError(result, code: "snapshot_cancelled")
    } else {
      completeSnapshotError(result, code: "snapshot_failed")
    }
  }

  private static func completeSnapshotError(
    _ result: @escaping FlutterResult, code: String
  ) {
    completeOnMain(
      result,
      value: FlutterError(code: code, message: "playlist snapshot failed", details: nil)
    )
  }

  private static func completeOnMain(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private static func fetchLibrarySongs(offset: Int, limit: Int, result: @escaping FlutterResult) {
    queue.async {
      // Snapshot per sync: offset 0 refreshes; later pages read the same array, so a
      // library mutation mid-sync can't shift offsets and drop songs. Serial queue = no concurrent rebuilds.
      if offset == 0 {
        let all = MPMediaQuery.songs().items ?? []
        // Only supported Apple catalog identities; local-only rips use "0"/empty,
        // and filtering here keeps one malformed opaque ID from rejecting a page.
        catalogCache = all.filter {
          $0.playbackStoreID != "0" && isSupportedAppleSongID($0.playbackStoreID)
        }
      } else if catalogCache.isEmpty {
        // Cold start at offset > 0: there's no snapshot to page from. Without this guard we'd
        // silently return an empty/zero page that reads as "sync complete" to the caller.
        DispatchQueue.main.async {
          result(FlutterError(code: "no_snapshot", message: "fetchLibrarySongs must start at offset 0", details: nil))
        }
        return
      }
      let catalog = catalogCache
      let page = catalog.dropFirst(offset).prefix(limit)
      // tracks is a globally shared catalog: the release year must not depend on the
      // syncing device's timezone, so pin it to UTC rather than the calendar default.
      var utcCal = Calendar(identifier: .gregorian)
      utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
      let songs: [[String: Any?]] = page.map { item in
        [
          "appleId": item.playbackStoreID,
          // Sentinel required: the server rejects empty title/artist (zod min(1)); nil OR "" here would 400 the whole 200-song chunk.
          "title": item.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown",
          "artist": item.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown",
          "album": item.albumTitle,
          "genre": item.genre,
          "releaseYear": item.releaseDate.flatMap { d -> Int? in
            guard abs(d.timeIntervalSince1970) > 86_400 else { return nil } // epoch sentinel = unknown
            return utcCal.dateComponents([.year], from: d).year
          },
          "explicit": item.isExplicitItem,
          "playCount": item.playCount,
          "lastPlayedAt": item.lastPlayedDate.map { Int($0.timeIntervalSince1970 * 1000) },
          "dateAdded": Int(item.dateAdded.timeIntervalSince1970 * 1000),
        ]
      }
      if offset + songs.count >= catalog.count {
        // Last page of the sync (including a single-page sync that covers the whole
        // catalog): release the ~10k MPMediaItem refs held by the snapshot.
        catalogCache = []
      }
      DispatchQueue.main.async {
        result(["songs": songs, "total": catalog.count])
      }
    }
  }
}
