import Flutter
import MediaPlayer

/// Bridges the on-device music library (MediaPlayer) to Dart.
/// P1 scope: authorization + paged library read with play counts.
class MusicKitBridge: NSObject {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mixtape/musickit", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestAuthorization":
        requestAuthorization(result: result)
      case "fetchLibrarySongs":
        let args = call.arguments as? [String: Any] ?? [:]
        let offset = args["offset"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 200
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
    DispatchQueue.global(qos: .userInitiated).async {
      let all = MPMediaQuery.songs().items ?? []
      // Only songs with an Apple Music catalog identity; local-only rips have "0"/empty.
      let catalog = all.filter { !$0.playbackStoreID.isEmpty && $0.playbackStoreID != "0" }
      let page = catalog.dropFirst(offset).prefix(limit)
      let songs: [[String: Any?]] = page.map { item in
        [
          "appleId": item.playbackStoreID,
          "title": item.title ?? "Unknown",
          "artist": item.artist ?? "Unknown",
          "album": item.albumTitle,
          "genre": item.genre,
          "playCount": item.playCount,
          "lastPlayedAt": item.lastPlayedDate.map { Int($0.timeIntervalSince1970 * 1000) },
          "dateAdded": Int(item.dateAdded.timeIntervalSince1970 * 1000),
        ]
      }
      DispatchQueue.main.async {
        result(["songs": songs, "total": catalog.count])
      }
    }
  }
}
