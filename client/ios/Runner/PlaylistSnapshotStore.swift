import CoreGraphics
import CryptoKit
import Foundation
import MusicKit

/// Owns one immutable, fully materialized Apple Music playlist snapshot.
/// Callers page simple values from memory; they never participate in MusicKit
/// pagination, ordering, fingerprinting, or cancellation.
actor PlaylistSnapshotStore {
  static let maxPlaylists = 2_000
  static let maxEntries = 100_000

  enum StoreError: String, Error {
    case invalidStorefront = "invalid_storefront"
    case duplicatePlaylist = "duplicate_playlist"
    case duplicateEntry = "duplicate_entry"
    case nonProgressingPage = "non_progressing_page"
    case snapshotTooLarge = "snapshot_too_large"
    case libraryChanged = "library_changed"
    case noSnapshot = "no_snapshot"
    case snapshotMismatch = "snapshot_mismatch"
    case playlistNotFound = "playlist_not_found"
  }

  struct Header: Sendable {
    let snapshotId: String
    let storefront: String
    let totalPlaylists: Int
    let totalEntries: Int
  }

  struct PlaylistValue: Sendable {
    let appleLibraryId: String
    let appleCatalogId: String?
    let name: String
    let description: String?
    let curatorName: String?
    let artworkUrlTemplate: String?
    let artworkWidth: Int?
    let artworkHeight: Int?
    let artworkBgColor: String?
    let kind: String
    let canEdit: Bool
    let appleDateAdded: Int?
    let appleLastModifiedAt: Int?
    let sourceFingerprint: String
    let entries: [EntryValue]
  }

  struct EntryValue: Sendable {
    let position: Int
    let appleLibraryEntryId: String
    let appleLibraryTrackId: String?
    let appleCatalogId: String?
    let isrcSnapshot: String?
    let titleSnapshot: String
    let artistSnapshot: String
    let albumSnapshot: String?
    let durationMsSnapshot: Int?
    let artworkUrlTemplateSnapshot: String?
    let artworkWidthSnapshot: Int?
    let artworkHeightSnapshot: Int?
    let artworkBgColorSnapshot: String?
  }

  private struct Snapshot: Sendable {
    let header: Header
    let playlists: [PlaylistValue]
    let playlistIndex: [String: Int]
  }

  private struct ActiveMaterialization {
    let generation: UUID
    let task: Task<Snapshot, Error>
  }

  private struct ArtworkValue: Sendable {
    let url: String?
    let width: Int?
    let height: Int?
    let backgroundColor: String?
  }

  private struct PlaylistSignature: Equatable {
    let lastModifiedAt: Int?
  }

  private var activeMaterialization: ActiveMaterialization?
  private var snapshot: Snapshot?

  func begin() async throws -> Header {
    activeMaterialization?.task.cancel()
    activeMaterialization = nil
    snapshot = nil

    let generation = UUID()
    let snapshotId = generation.uuidString.lowercased()
    let task = Task { try await Self.materialize(snapshotId: snapshotId) }
    activeMaterialization = ActiveMaterialization(generation: generation, task: task)

    do {
      let materialized = try await task.value
      guard activeMaterialization?.generation == generation else {
        throw CancellationError()
      }
      activeMaterialization = nil
      snapshot = materialized
      return materialized.header
    } catch {
      if activeMaterialization?.generation == generation {
        activeMaterialization = nil
      }
      throw error
    }
  }

  func playlistPage(snapshotId: String, offset: Int, limit: Int) throws
    -> (values: [PlaylistValue], total: Int)
  {
    let current = try requireSnapshot(snapshotId)
    let values = Array(current.playlists.dropFirst(offset).prefix(limit))
    return (values, current.playlists.count)
  }

  func entryPage(snapshotId: String, playlistId: String, offset: Int, limit: Int) throws
    -> (values: [EntryValue], total: Int)
  {
    let current = try requireSnapshot(snapshotId)
    guard let index = current.playlistIndex[playlistId] else {
      throw StoreError.playlistNotFound
    }
    let entries = current.playlists[index].entries
    return (Array(entries.dropFirst(offset).prefix(limit)), entries.count)
  }

  @discardableResult
  func cancel() -> Bool {
    activeMaterialization?.task.cancel()
    activeMaterialization = nil
    snapshot = nil
    return true
  }

  @discardableResult
  func release(snapshotId: String) throws -> Bool {
    _ = try requireSnapshot(snapshotId)
    snapshot = nil
    return true
  }

  private func requireSnapshot(_ snapshotId: String) throws -> Snapshot {
    guard let snapshot else { throw StoreError.noSnapshot }
    guard snapshot.header.snapshotId == snapshotId else {
      throw StoreError.snapshotMismatch
    }
    return snapshot
  }

  private static func materialize(snapshotId: String) async throws -> Snapshot {
    try Task.checkCancellation()
    let storefront = try await MusicDataRequest.currentCountryCode.lowercased()
    guard storefront.range(of: "^[a-z]{2}$", options: .regularExpression) != nil else {
      throw StoreError.invalidStorefront
    }

    let sourcePlaylists = try await fetchAllPlaylists()
    guard sourcePlaylists.count <= maxPlaylists else { throw StoreError.snapshotTooLarge }

    var playlists: [PlaylistValue] = []
    playlists.reserveCapacity(sourcePlaylists.count)
    var playlistIndex: [String: Int] = [:]
    var totalEntries = 0

    for playlist in sourcePlaylists {
      try Task.checkCancellation()
      let playlistId = playlist.id.rawValue
      guard playlistIndex[playlistId] == nil else { throw StoreError.duplicatePlaylist }

      let detailed = try await playlist.with(.entries, preferredSource: .library)
      let sourceEntries = try await fetchAllEntries(detailed.entries)
      totalEntries += sourceEntries.count
      guard totalEntries <= maxEntries else { throw StoreError.snapshotTooLarge }

      var seenEntryIds = Set<String>()
      let entries = try sourceEntries.enumerated().map { position, entry in
        try Task.checkCancellation()
        let entryId = entry.id.rawValue
        guard seenEntryIds.insert(entryId).inserted else { throw StoreError.duplicateEntry }
        return makeEntry(entry, position: position)
      }
      let artwork = artworkValue(playlist.artwork)
      let lastModifiedAt = epochMilliseconds(playlist.lastModifiedDate)
      let fingerprint = fingerprint(
        playlistId: playlistId,
        lastModifiedAt: lastModifiedAt,
        entries: entries
      )
      let value = PlaylistValue(
        appleLibraryId: playlistId,
        appleCatalogId: nil,
        name: nonempty(playlist.name) ?? "Untitled Playlist",
        description: nonempty(playlist.standardDescription) ?? nonempty(playlist.shortDescription),
        curatorName: nonempty(playlist.curatorName),
        artworkUrlTemplate: artwork.url,
        artworkWidth: artwork.width,
        artworkHeight: artwork.height,
        artworkBgColor: artwork.backgroundColor,
        kind: normalizedKind(playlist.kind),
        canEdit: false,
        appleDateAdded: epochMilliseconds(playlist.libraryAddedDate),
        appleLastModifiedAt: lastModifiedAt,
        sourceFingerprint: fingerprint,
        entries: entries
      )
      playlistIndex[playlistId] = playlists.count
      playlists.append(value)
    }

    // MusicKit has no database-style read transaction. A second lightweight
    // playlist read catches additions, removals, or modification timestamps
    // that changed while the entry graph was being materialized.
    let finalPlaylists = try await fetchAllPlaylists()
    guard signatures(sourcePlaylists) == signatures(finalPlaylists) else {
      throw StoreError.libraryChanged
    }
    try await verifyStableEntries(
      finalPlaylists,
      materialized: playlists,
      expectedTotalEntries: totalEntries
    )

    return Snapshot(
      header: Header(
        snapshotId: snapshotId,
        storefront: storefront,
        totalPlaylists: playlists.count,
        totalEntries: totalEntries
      ),
      playlists: playlists,
      playlistIndex: playlistIndex
    )
  }

  private static func fetchAllPlaylists() async throws -> [Playlist] {
    var request = MusicLibraryRequest<Playlist>()
    request.limit = 100
    request.offset = 0
    var page = try await request.response().items
    var values: [Playlist] = []
    var seen = Set<String>()

    while true {
      try Task.checkCancellation()
      for playlist in page {
        guard seen.insert(playlist.id.rawValue).inserted else {
          throw StoreError.duplicatePlaylist
        }
        values.append(playlist)
        guard values.count <= maxPlaylists else { throw StoreError.snapshotTooLarge }
      }
      guard page.hasNextBatch else { break }
      guard let next = try await page.nextBatch(limit: 100), !next.isEmpty else {
        throw StoreError.nonProgressingPage
      }
      page = next
    }
    return values
  }

  private static func fetchAllEntries(
    _ initial: MusicItemCollection<Playlist.Entry>?
  ) async throws -> [Playlist.Entry] {
    guard var page = initial else { return [] }
    var values: [Playlist.Entry] = []
    var pageStarts = Set<String>()

    while true {
      try Task.checkCancellation()
      if let firstId = page.first?.id.rawValue {
        guard pageStarts.insert(firstId).inserted else {
          throw StoreError.nonProgressingPage
        }
      }
      values.append(contentsOf: page)
      guard values.count <= maxEntries else { throw StoreError.snapshotTooLarge }
      guard page.hasNextBatch else { break }
      guard let next = try await page.nextBatch(limit: 200), !next.isEmpty else {
        throw StoreError.nonProgressingPage
      }
      page = next
    }
    return values
  }

  private static func makeEntry(_ entry: Playlist.Entry, position: Int) -> EntryValue {
    let item = entry.item
    let artwork = artworkValue(entry.artwork ?? item?.artwork)
    return EntryValue(
      position: position,
      appleLibraryEntryId: entry.id.rawValue,
      appleLibraryTrackId: item?.id.rawValue,
      appleCatalogId: nil,
      isrcSnapshot: nonempty(entry.isrc),
      titleSnapshot: nonempty(entry.title) ?? nonempty(item?.title) ?? "Unknown",
      artistSnapshot: nonempty(entry.artistName) ?? nonempty(item?.artistName) ?? "Unknown",
      albumSnapshot: nonempty(entry.albumTitle) ?? nonempty(item?.albumTitle),
      durationMsSnapshot: durationMilliseconds(entry.duration ?? item?.duration),
      artworkUrlTemplateSnapshot: artwork.url,
      artworkWidthSnapshot: artwork.width,
      artworkHeightSnapshot: artwork.height,
      artworkBgColorSnapshot: artwork.backgroundColor
    )
  }

  private static func artworkValue(_ artwork: Artwork?) -> ArtworkValue {
    guard let artwork else {
      return ArtworkValue(url: nil, width: nil, height: nil, backgroundColor: nil)
    }
    let requestedUrl = artwork.url(width: 512, height: 512)
    let url = requestedUrl?.scheme?.lowercased() == "https" ? requestedUrl?.absoluteString : nil
    return ArtworkValue(
      url: url,
      width: artwork.maximumWidth > 0 ? artwork.maximumWidth : nil,
      height: artwork.maximumHeight > 0 ? artwork.maximumHeight : nil,
      backgroundColor: hexColor(artwork.backgroundColor)
    )
  }

  private static func hexColor(_ color: CGColor?) -> String? {
    guard
      let color,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
      let components = converted.components
    else { return nil }

    let rgb: [CGFloat]
    if components.count >= 3 {
      rgb = Array(components.prefix(3))
    } else if let gray = components.first {
      rgb = [gray, gray, gray]
    } else {
      return nil
    }
    let bytes = rgb.map { Int((min(1, max(0, $0)) * 255).rounded()) }
    return String(format: "%02x%02x%02x", bytes[0], bytes[1], bytes[2])
  }

  private static func normalizedKind(_ kind: Playlist.Kind?) -> String {
    guard let kind else { return "unknown" }
    switch kind {
    case .editorial: return "editorial"
    case .external: return "external"
    case .personalMix: return "personal_mix"
    case .replay: return "replay"
    case .userShared: return "user_shared"
    @unknown default: return "unknown"
    }
  }

  private static func signatures(_ playlists: [Playlist]) -> [String: PlaylistSignature]? {
    var values: [String: PlaylistSignature] = [:]
    for playlist in playlists {
      let id = playlist.id.rawValue
      guard values[id] == nil else { return nil }
      values[id] = PlaylistSignature(lastModifiedAt: epochMilliseconds(playlist.lastModifiedDate))
    }
    return values
  }

  private static func verifyStableEntries(
    _ playlists: [Playlist],
    materialized: [PlaylistValue],
    expectedTotalEntries: Int
  ) async throws {
    let expected = Dictionary(uniqueKeysWithValues: materialized.map { ($0.appleLibraryId, $0) })
    var verifiedTotal = 0

    for playlist in playlists {
      try Task.checkCancellation()
      guard let expectedPlaylist = expected[playlist.id.rawValue] else {
        throw StoreError.libraryChanged
      }
      let detailed = try await playlist.with(.entries, preferredSource: .library)
      let sourceEntries = try await fetchAllEntries(detailed.entries)
      guard sourceEntries.count == expectedPlaylist.entries.count else {
        throw StoreError.libraryChanged
      }
      verifiedTotal += sourceEntries.count
      guard verifiedTotal <= maxEntries else { throw StoreError.snapshotTooLarge }

      for (position, entry) in sourceEntries.enumerated() {
        let previous = expectedPlaylist.entries[position]
        guard
          entry.id.rawValue == previous.appleLibraryEntryId,
          entry.item?.id.rawValue == previous.appleLibraryTrackId
        else {
          throw StoreError.libraryChanged
        }
      }
    }

    guard verifiedTotal == expectedTotalEntries else { throw StoreError.libraryChanged }
  }

  private static func epochMilliseconds(_ date: Date?) -> Int? {
    guard let date else { return nil }
    let value = date.timeIntervalSince1970 * 1_000
    guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
    return Int(value.rounded())
  }

  private static func durationMilliseconds(_ duration: TimeInterval?) -> Int? {
    guard let duration, duration.isFinite, duration >= 0 else { return nil }
    let value = duration * 1_000
    guard value <= Double(Int.max) else { return nil }
    return Int(value.rounded())
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func fingerprint(
    playlistId: String,
    lastModifiedAt: Int?,
    entries: [EntryValue]
  ) -> String {
    var builder = FingerprintBuilder()
    builder.append("mixtape-playlist-snapshot-v1")
    builder.append(playlistId)
    builder.append(lastModifiedAt)
    builder.append(entries.count)
    for entry in entries {
      builder.append(entry.position)
      builder.append(entry.appleLibraryEntryId)
      builder.append(entry.appleLibraryTrackId)
      builder.append(entry.isrcSnapshot)
      builder.append(entry.titleSnapshot)
      builder.append(entry.artistSnapshot)
      builder.append(entry.albumSnapshot)
      builder.append(entry.durationMsSnapshot)
    }
    return SHA256.hash(data: builder.data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct FingerprintBuilder {
  private(set) var data = Data()

  mutating func append(_ value: String) {
    let bytes = Data(value.utf8)
    appendUInt64(UInt64(bytes.count))
    data.append(bytes)
  }

  mutating func append(_ value: String?) {
    guard let value else {
      data.append(0)
      return
    }
    data.append(1)
    append(value)
  }

  mutating func append(_ value: Int) {
    var signed = Int64(value).bigEndian
    withUnsafeBytes(of: &signed) { data.append(contentsOf: $0) }
  }

  mutating func append(_ value: Int?) {
    guard let value else {
      data.append(0)
      return
    }
    data.append(1)
    append(value)
  }

  private mutating func appendUInt64(_ value: UInt64) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}
