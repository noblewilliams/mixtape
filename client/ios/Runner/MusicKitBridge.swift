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
      default:
        result(FlutterMethodNotImplemented)
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
      let songs: [[String: Any?]] = page.map { item in
        [
          "appleId": item.playbackStoreID,
          // Sentinel required: the server rejects empty title/artist (zod min(1)); nil here would 400 the whole 200-song chunk.
          "title": item.title ?? "Unknown",
          "artist": item.artist ?? "Unknown",
          "album": item.albumTitle,
          "genre": item.genre,
          "playCount": item.playCount,
          "lastPlayedAt": item.lastPlayedDate.map { Int($0.timeIntervalSince1970 * 1000) },
          "dateAdded": Int(item.dateAdded.timeIntervalSince1970 * 1000),
        ]
      }
      if offset + songs.count >= catalog.count && offset > 0 {
        // Last page of a multi-page sync: release the ~10k MPMediaItem refs held by the snapshot.
        catalogCache = []
      }
      DispatchQueue.main.async {
        result(["songs": songs, "total": catalog.count])
      }
    }
  }
}
