import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testPlaylistEntryCatalogIdentityReadsExactAppleMusicSongURL() {
    XCTAssertEqual(
      PlaylistEntryCatalogIdentity.catalogId(
        fromMusicURL: URL(
          string: "https://music.apple.com/ng/album/beat-it/269572838?i=269573341"
        )
      ),
      "269573341"
    )
    XCTAssertNil(
      PlaylistEntryCatalogIdentity.catalogId(
        fromMusicURL: URL(
          string: "https://example.com/ng/album/beat-it/269572838?i=269573341"
        )
      )
    )
    XCTAssertNil(
      PlaylistEntryCatalogIdentity.catalogId(
        fromMusicURL: URL(
          string: "http://music.apple.com/ng/album/beat-it/269572838?i=269573341"
        )
      )
    )
  }

  func testPlaylistEntryCatalogIdentityReadsEncodedPlayParameters() {
    let encoded = Data(
      #"{"id":"i.library","kind":"song","isLibrary":true,"catalogId":"269573341"}"#.utf8
    )

    XCTAssertEqual(
      PlaylistEntryCatalogIdentity.catalogId(fromEncodedPlayParameters: encoded),
      "269573341"
    )
  }

  func testPlaylistEntryCatalogIdentityRejectsUnsafeOrAmbiguousValues() {
    XCTAssertNil(
      PlaylistEntryCatalogIdentity.catalogId(
        fromEncodedPlayParameters: Data(#"{"catalogId":"bad,id"}"#.utf8)
      )
    )
    XCTAssertNil(
      PlaylistEntryCatalogIdentity.catalogId(
        fromMusicURL: URL(
          string: "https://music.apple.com/ng/album/example/1?i=first&i=second"
        )
      )
    )
  }

  func testLibrarySongCatalogCrosswalkMapsExactIDsInBoundedBatches() async throws {
    let recorder = LibrarySongRequestRecorder()
    let crosswalk = LibrarySongCatalogCrosswalk { ids in
      await recorder.append(ids)
      return ids.map { id in
        LibrarySongCatalogCrosswalk.SongValue(
          libraryId: id,
          catalogId: "catalog.\(id.dropFirst(2))",
          isrc: nil
        )
      }
    }
    let ids = (0..<51).map { "i.\($0)" }

    let result = try await crosswalk.resolve(librarySongIds: ids)

    XCTAssertEqual(result.count, 51)
    XCTAssertEqual(result["i.7"]?.catalogId, "catalog.7")
    let requests = await recorder.values
    XCTAssertEqual(requests.count, 3)
    XCTAssertTrue(requests.allSatisfy { $0.count <= 25 })
    XCTAssertEqual(Set(requests.flatMap { $0 }), Set(ids))
  }

  func testLibrarySongCatalogCrosswalkRejectsExtrasAndDuplicates() async throws {
    let crosswalk = LibrarySongCatalogCrosswalk { _ in
      [
        .init(libraryId: "i.requested", catalogId: "first", isrc: nil),
        .init(libraryId: "i.requested", catalogId: "second", isrc: nil),
        .init(libraryId: "i.extra", catalogId: "must-not-leak", isrc: nil),
      ]
    }

    let result = try await crosswalk.resolve(librarySongIds: ["i.requested"])

    XCTAssertTrue(result.isEmpty)
  }
}

private struct ProbeError: LocalizedError {
  let reason: String
  var errorDescription: String? { reason }
}

private final class FakePlaylist: @unchecked Sendable {
  var songs: [String] = []
}

extension RunnerTests {
  private func writer(
    resolve: @escaping ([String]) async throws -> [String: String] = { ids in
      Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    },
    create: @escaping () async throws -> FakePlaylist = { FakePlaylist() },
    add: @escaping (String, FakePlaylist) async throws -> FakePlaylist = { song, playlist in
      playlist.songs.append(song)
      return playlist
    },
    fallback: (([String]) async throws -> (added: Int, failed: Int))? = nil
  ) -> MixPlaylistWriter<String, FakePlaylist> {
    MixPlaylistWriter(
      resolveBatch: resolve, create: create, add: add, libraryId: { _ in "p.new" },
      fallback: fallback)
  }

  // Production has no MusicKit-path save, ever: the typed path fails on
  // device. The MediaPlayer path (no developer token) must take over.
  func testMixPlaylistFallsBackWhenCatalogLookupFails() async {
    let received = FakePlaylist()
    let outcome = await writer(
      resolve: { _ in throw ProbeError(reason: "developer token request failed") },
      fallback: { ids in received.songs = ids; return (added: ids.count, failed: 0) }
    ).write(appleIds: ["b", "a", "b"])

    guard case let .saved(added, failed, libraryId) = outcome else {
      return XCTFail("expected a save, got \(outcome)")
    }
    XCTAssertEqual(received.songs, ["b", "a", "b"])
    XCTAssertEqual(added, 3)
    XCTAssertEqual(failed, 0)
    XCTAssertNil(libraryId)
  }

  func testMixPlaylistFallsBackWhenCreationFails() async {
    let outcome = await writer(
      create: { throw ProbeError(reason: "permission denied") },
      fallback: { ids in (added: ids.count - 1, failed: 1) }
    ).write(appleIds: ["a", "b"])

    guard case let .saved(added, failed, _) = outcome else {
      return XCTFail("expected a save, got \(outcome)")
    }
    XCTAssertEqual(added, 1)
    XCTAssertEqual(failed, 1)
  }

  func testMixPlaylistReportsBothReasonsWhenFallbackAlsoFails() async {
    let outcome = await writer(
      create: { throw ProbeError(reason: "permission denied") },
      fallback: { _ in throw ProbeError(reason: "media library refused") }
    ).write(appleIds: ["a"])

    guard case let .failed(message, detail) = outcome else {
      return XCTFail("expected a failure, got \(outcome)")
    }
    XCTAssertEqual(message, "Could not create playlist.")
    XCTAssertEqual(detail?.contains("permission denied"), true)
    XCTAssertEqual(detail?.contains("media library refused"), true)
  }

  // A playlist MusicKit already created must never be duplicated by the
  // fallback: once creation succeeds, add failures are counted, not retried.
  func testMixPlaylistDoesNotFallBackAfterCreationSucceeds() async {
    let fellBack = FakePlaylist()
    let outcome = await writer(
      add: { _, _ in throw ProbeError(reason: "not addable") },
      fallback: { _ in fellBack.songs.append("x"); return (added: 1, failed: 0) }
    ).write(appleIds: ["a"])

    XCTAssertTrue(fellBack.songs.isEmpty)
    guard case let .saved(added, failed, libraryId) = outcome else {
      return XCTFail("expected a save, got \(outcome)")
    }
    XCTAssertEqual(added, 0)
    XCTAssertEqual(failed, 1)
    XCTAssertEqual(libraryId, "p.new")
  }

  @MainActor func testMixPlaylistFallbackSaveOmitsLibraryId() {
    let value = MixPlaylistWriter<String, FakePlaylist>.flutterResult(
      .saved(added: 2, failed: 0, libraryId: nil)
    ) as? [String: Any]

    XCTAssertEqual(value?["added"] as? Int, 2)
    XCTAssertNil(value?["appleLibraryId"])
  }

  // The founder's 2026-11-22 report: "Couldn't save the playlist — Could not
  // create playlist." with no reason, because the bridge discarded Apple's
  // error. A catalogue lookup failure must say so and carry Apple's reason.
  func testMixPlaylistCatalogLookupFailureCarriesStageAndAppleReason() async {
    let outcome = await writer(resolve: { _ in
      throw ProbeError(reason: "developer token request failed")
    }).write(appleIds: ["1440903547"])

    guard case let .failed(message, detail) = outcome else {
      return XCTFail("expected a failure, got \(outcome)")
    }
    XCTAssertEqual(message, "Could not find the songs in Apple Music.")
    XCTAssertEqual(detail?.contains("developer token request failed"), true)
  }

  func testMixPlaylistCreationFailureCarriesStageAndAppleReason() async {
    let outcome = await writer(create: {
      throw ProbeError(reason: "permission denied")
    }).write(appleIds: ["1440903547"])

    guard case let .failed(message, detail) = outcome else {
      return XCTFail("expected a failure, got \(outcome)")
    }
    XCTAssertEqual(message, "Could not create playlist.")
    XCTAssertEqual(detail?.contains("permission denied"), true)
  }

  @MainActor func testMixPlaylistFailureBecomesFlutterErrorWithDetails() {
    let error = MixPlaylistWriter<String, FakePlaylist>.flutterResult(
      .failed(message: "Could not create playlist.", detail: "permission denied")
    ) as? FlutterError

    XCTAssertEqual(error?.code, "playlist_failed")
    XCTAssertEqual(error?.message, "Could not create playlist.")
    XCTAssertEqual(error?.details as? String, "permission denied")
  }

  func testMixPlaylistAddsInOrderAndCountsUnresolvedAndFailedAdds() async {
    let outcome = await writer(
      resolve: { ids in
        Dictionary(uniqueKeysWithValues: ids.filter { $0 != "missing" }.map { ($0, $0) })
      },
      add: { song, playlist in
        if song == "refused" { throw ProbeError(reason: "not addable") }
        playlist.songs.append(song)
        return playlist
      }
    ).write(appleIds: ["b", "missing", "a", "refused", "b"])

    guard case let .saved(added, failed, libraryId) = outcome else {
      return XCTFail("expected a save, got \(outcome)")
    }
    XCTAssertEqual(added, 3)
    XCTAssertEqual(failed, 2)
    XCTAssertEqual(libraryId, "p.new")
  }

  func testMixPlaylistWithNoResolvableSongsCreatesNothing() async {
    let created = FakePlaylist()
    let outcome = await writer(
      resolve: { _ in [:] },
      create: { created.songs.append("created"); return created }
    ).write(appleIds: ["1"])

    XCTAssertTrue(created.songs.isEmpty)
    guard case let .failed(message, _) = outcome else {
      return XCTFail("expected a failure, got \(outcome)")
    }
    XCTAssertEqual(message, "No songs could be resolved.")
  }
}

private actor LibrarySongRequestRecorder {
  private(set) var values: [[String]] = []

  func append(_ ids: [String]) {
    values.append(ids)
  }
}
