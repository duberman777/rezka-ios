import Foundation
import XCTest
@testable import RezkaPort

final class WatchRecordSyncTests: XCTestCase {
    private func decodeHistory(_ json: String) throws -> [WatchRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(LossyArray<WatchRecord>.self, from: Data(json.utf8)).elements
    }

    func testAndroidRecordWithoutSynopsisStillResumes() throws {
        // The previous API dropped synopses longer than 1200 characters from Android records.
        let records = try decodeHistory("""
        [{"item":{"id":"123","title":"Film","genre":"Drama","page":"https://omnirezka.tv/films/drama/123-film.html",
          "isSeries":false,"kind":"movie","symbol":"F","paletteIndex":0,
          "rezka":{"movieID":"123","pageURL":"https://omnirezka.tv/films/drama/123-film.html","isSeries":false,
            "translators":[{"id":"56","name":"Dub","isPremium":false,"isSelected":true,"flags":{}}],"seasons":[],"playerFlags":{}}},
          "position":1234.5,"duration":6000,"updatedAt":1760000000000,"completed":false,"translator":"56","translatorID":"56"}]
        """)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].item.synopsis, "")
        XCTAssertEqual(records[0].translatorID, "56")
        XCTAssertEqual(records[0].resumePosition(for: PlaybackRequest(mediaID: "123", translatorID: "56")), 1234.5)
    }

    func testOneUnreadableRecordDoesNotDiscardTheRest() throws {
        let records = try decodeHistory("""
        [{"item":{"id":"bad"},"position":1,"duration":2,"updatedAt":1},
         {"item":{"id":"7","title":"Series","kind":"series","rezka":{"movieID":"7","pageURL":"https://omnirezka.tv/series/7-s.html","isSeries":true}},
          "position":42,"duration":2400,"updatedAt":1760000000000,"seasonID":"1","episodeID":"2"}]
        """)
        XCTAssertEqual(records.map(\.item.id), ["7"])
        XCTAssertEqual(records[0].item.rezka?.translators, [])
        XCTAssertEqual(records[0].resumePosition(for: PlaybackRequest(mediaID: "7", season: "1", episode: "2")), 42)
    }

    func testSyncServerAddressIsHTTPSAndOptional() throws {
        XCTAssertNil(try SyncServerAddress.normalized("  "))
        XCTAssertEqual(try SyncServerAddress.normalized("sync.example.com")?.absoluteString, "https://sync.example.com")
        XCTAssertEqual(try SyncServerAddress.normalized("https://Example.com/rezka-sync/")?.absoluteString, "https://example.com/rezka-sync")
        XCTAssertThrowsError(try SyncServerAddress.normalized("http://sync.example.com"))
        XCTAssertThrowsError(try SyncServerAddress.normalized("https://sync.example.com/?a=1"))
    }
}
