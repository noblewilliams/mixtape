import Flutter
import MediaPlayer

/// Bridges the on-device music library (MediaPlayer) to Dart.
/// P1 scope: authorization + paged library read with play counts.
class MusicKitBridge: NSObject {
  private static let queue = DispatchQueue(label: "mixtape.musickit.bridge")
  private static var catalogCache: [MPMediaItem] = []

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
      case "playQueue":
        let args = call.arguments as? [String: Any] ?? [:]
        let appleIds = args["appleIds"] as? [String] ?? []
        playQueue(appleIds: appleIds, result: result)
      case "createPlaylist":
        let args = call.arguments as? [String: Any] ?? [:]
        let name = args["name"] as? String ?? ""
        let appleIds = args["appleIds"] as? [String] ?? []
        createPlaylist(name: name, appleIds: appleIds, result: result)
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
            result(FlutterError(code: "play_failed", message: "could not start playback", details: nil))
            return
          }
          player.play()
          result(true)
        }
      }
    }
  }

  // MARK: - Playlist creation

  private static func createPlaylist(name: String, appleIds: [String], result: @escaping FlutterResult) {
    guard !name.isEmpty, !appleIds.isEmpty else {
      result(FlutterError(code: "empty_playlist", message: "name and tracks are required", details: nil))
      return
    }
    DispatchQueue.main.async {
      let metadata = MPMediaPlaylistCreationMetadata(name: name)
      MPMediaLibrary.default().getPlaylist(with: UUID(), creationMetadata: metadata) { playlist, error in
        DispatchQueue.main.async {
          guard let playlist = playlist, error == nil else {
            result(FlutterError(code: "playlist_failed", message: "could not create playlist", details: nil))
            return
          }
          addItems(appleIds, to: playlist, index: 0, added: 0, failed: 0, result: result)
        }
      }
    }
  }

  /// Adds `appleIds[index...]` to `playlist` one at a time via a recursive
  /// completion chain — NOT a DispatchGroup, which would deadlock waiting
  /// for N completions to all signal back to the main thread while each
  /// completion itself hops back to main. A per-item failure is counted and
  /// the chain continues; it never aborts the whole batch.
  private static func addItems(
    _ appleIds: [String],
    to playlist: MPMediaPlaylist,
    index: Int,
    added: Int,
    failed: Int,
    result: @escaping FlutterResult
  ) {
    guard index < appleIds.count else {
      result(["added": added, "failed": failed])
      return
    }
    playlist.addItem(withProductID: appleIds[index]) { error in
      DispatchQueue.main.async {
        let nextAdded = added + (error == nil ? 1 : 0)
        let nextFailed = failed + (error == nil ? 0 : 1)
        addItems(appleIds, to: playlist, index: index + 1, added: nextAdded, failed: nextFailed, result: result)
      }
    }
  }

  private static func requestAuthorization(result: @escaping FlutterResult) {
    MPMediaLibrary.requestAuthorization { status in
      DispatchQueue.main.async { result(status == .authorized) }
    }
  }

  private static func fetchLibrarySongs(offset: Int, limit: Int, result: @escaping FlutterResult) {
    queue.async {
      // Snapshot per sync: offset 0 refreshes; later pages read the same array, so a
      // library mutation mid-sync can't shift offsets and drop songs. Serial queue = no concurrent rebuilds.
      if offset == 0 {
        let all = MPMediaQuery.songs().items ?? []
        // Only songs with an Apple Music catalog identity; local-only rips have "0"/empty.
        catalogCache = all.filter { !$0.playbackStoreID.isEmpty && $0.playbackStoreID != "0" }
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
