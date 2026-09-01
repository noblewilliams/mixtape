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

private actor LibrarySongRequestRecorder {
  private(set) var values: [[String]] = []

  func append(_ ids: [String]) {
    values.append(ids)
  }
}
