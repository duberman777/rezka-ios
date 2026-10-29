#if os(iOS)
import AVKit
import XCTest
@testable import RezkaPort

@MainActor
final class PlaybackHistoryTests: XCTestCase {
    func testRepeatedViewAccessConstructsOnlyOnePlayer() {
        let lifecycle = PlaybackLifecycle()
        var creations = 0
        let first = lifecycle.player { creations += 1; return AVPlayer() }
        let second = lifecycle.player { creations += 1; return AVPlayer() }
        XCTAssertTrue(first === second)
        XCTAssertEqual(creations, 1)
    }

    func testPauseBufferTargetIsTenMinutesOrRemainingEpisodeDuration() {
        XCTAssertEqual(PauseBufferPolicy.requestedSeconds(at: 60, duration: 2400), 600)
        XCTAssertEqual(PauseBufferPolicy.requestedSeconds(at: 2300, duration: 2400), 100)
        XCTAssertEqual(PauseBufferPolicy.requestedSeconds(at: 2400, duration: 2400), 0)
        XCTAssertEqual(PauseBufferPolicy.requestedSeconds(at: 60, duration: .nan), 600)
    }

    func testPauseBufferIndicatorCountsOnlyContinuousDataFromThePlayhead() {
        func range(_ start: Double, _ duration: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
        // Out-of-order and overlapping ranges are merged. A later scene after
        // a gap must not be reported as immediately playable buffered data.
        let ranges = [range(150, 100), range(500, 100), range(100, 60), range(0, 50)]
        XCTAssertEqual(PauseBufferPolicy.bufferedSecondsAhead(at: 120, ranges: ranges), 130, accuracy: 0.001)
        XCTAssertEqual(PauseBufferPolicy.bufferedSecondsAhead(at: 300, ranges: ranges), 0)
        XCTAssertEqual(PauseBufferPolicy.bufferedSecondsAhead(at: .nan, ranges: ranges), 0)
        XCTAssertEqual(PauseBufferPolicy.bufferedSecondsAhead(at: 120, ranges: [.invalid]), 0)
        XCTAssertEqual(PauseBufferPolicy.bufferedSecondsAhead(at: 120, ranges: []), 0)
    }

    func testBackgroundCheckpointKeepsMinutesAndSecondsAfterRelaunch() throws {
        let suite = "RezkaCheckpointTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "42", title: "Series", kind: .series, genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 0)
        let request = PlaybackRequest(mediaID: "42", season: "2", episode: "3")
        let model = AppModel(defaults: defaults)
        model.recordProgress(for: item, position: 754.25, duration: 2400, request: request)
        // The final event between periodic observations must win.
        model.recordProgress(for: item, position: 755.875, duration: .nan, request: request)
        let relaunched = AppModel(defaults: defaults)
        let record = try XCTUnwrap(relaunched.episodeRecord(mediaID: "42", season: "2", episode: "3"))
        XCTAssertEqual(record.resumePosition(for: request), 755.875)
        XCTAssertEqual(record.positionLabel, "12:35")
        XCTAssertEqual(record.duration, 2400)
        XCTAssertNil(record.resumePosition(for: PlaybackRequest(mediaID: "42", season: "2", episode: "4")))
    }

    func testDelayedTeardownCannotOverwriteNewerPositionOrEpisode() throws {
        let suite = "RezkaDelayedCheckpointTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "42", title: "Series", kind: .series, genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 0)
        let episode3 = PlaybackRequest(mediaID: "42", season: "2", episode: "3")
        let episode4 = PlaybackRequest(mediaID: "42", season: "2", episode: "4")
        let model = AppModel(defaults: defaults)
        let oldTime = Date(timeIntervalSince1970: 100)
        let newTime = Date(timeIntervalSince1970: 200)
        model.recordProgress(for: item, position: 755.875, duration: 2400, request: episode3, recordedAt: newTime)
        model.recordProgress(for: item, position: 12, duration: 2400, request: episode3, recordedAt: oldTime)
        XCTAssertEqual(model.history.first?.position, 755.875)
        model.recordProgress(for: item, position: 30, duration: 2400, request: episode4, recordedAt: newTime)
        model.recordProgress(for: item, position: 755, duration: 2400, request: episode3, recordedAt: oldTime)
        let relaunched = AppModel(defaults: defaults)
        XCTAssertEqual(relaunched.history.first?.episodeID, "4")
        XCTAssertEqual(relaunched.history.first?.position, 30)
        XCTAssertEqual(relaunched.episodeRecord(mediaID: "42", season: "2", episode: "3")?.position, 755.875)
    }

    func testUnknownDurationUsesTheSelectedEpisodesSavedDuration() throws {
        let suite = "RezkaEpisodeDurationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "42", title: "Series", kind: .series, genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 0)
        let model = AppModel(defaults: defaults)
        let episode3 = PlaybackRequest(mediaID: "42", season: "2", episode: "3")
        model.recordProgress(for: item, position: 755, duration: 2400, request: episode3)
        model.recordProgress(for: item, position: 30, duration: 1800, request: PlaybackRequest(mediaID: "42", season: "2", episode: "4"))
        model.recordProgress(for: item, position: 756, duration: .nan, request: episode3)
        XCTAssertEqual(model.history.first?.duration, 2400)
    }

    func testPlayerCleanupIsSafeWhenCloseAndDismantleBothRun() {
        let lifecycle = PlaybackLifecycle()
        let player = AVPlayer()
        lifecycle.progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { _ in }
        XCTAssertTrue(lifecycle.stop(player: player))
        XCTAssertNil(lifecycle.progressObserver)
        XCTAssertFalse(lifecycle.stop(player: player))
    }

    func testCountryExclusionsPersistAndKeepSavedTitlesAvailable() throws {
        let suite = "RezkaCountryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let coProduction = MediaItem(id: "us-ru", title: "Co-production", kind: .movie, genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0, countryCodes: ["US", "RU"])
        let italian = MediaItem(id: "it", title: "Italian title", kind: .movie, genre: "Drama", synopsis: "", symbol: "film", paletteIndex: 0, countryCodes: ["IT"])
        model.upsert(coProduction)
        model.upsert(italian)
        model.toggleFavorite(coProduction)
        model.excludedCountryCodes = ["RU"]
        XCTAssertEqual(model.items.map(\.id), ["it"])
        XCTAssertEqual(model.favorites.map(\.id), ["us-ru"])
        XCTAssertEqual(model.visibleItems([coProduction, italian]).map(\.id), ["it"])
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.excludedCountryCodes, ["RU"])
        XCTAssertEqual(restored.items.map(\.id), ["it"])
        restored.excludedCountryCodes = []
        XCTAssertEqual(restored.items.count, 2)
    }
    func testPlaybackStartKeepsSavedEpisodeAndRelaunchRestoresExactPosition() throws {
        let suite = "RezkaHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "42", title: "Episode test", kind: .series, genre: "Drama", synopsis: "", symbol: "tv", paletteIndex: 0)
        let request = PlaybackRequest(mediaID: "42", translatorID: "7", season: "2", episode: "3")
        let model = AppModel(defaults: defaults)
        model.recordProgress(for: item, position: 754.25, duration: 2400, request: request)
        model.recordStart(item)
        XCTAssertEqual(model.history.first?.translatorID, "7")
        XCTAssertEqual(model.history.first?.resumePosition(for: request), 754.25)
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.history.first?.resumePosition(for: request), 754.25)
        XCTAssertEqual(restored.continueWatching.count, 1)
        restored.recordProgress(for: item, position: 900, duration: .nan, request: request)
        XCTAssertEqual(restored.history.first?.duration, 2400)
        XCTAssertEqual(restored.history.first?.position, 900)
        restored.recordProgress(for: item, position: 2400, duration: 2400, request: request)
        XCTAssertEqual(restored.episodeRecord(mediaID: "42", season: "2", episode: "3")?.progress, 1)
        let next = PlaybackRequest(mediaID: "42", translatorID: "7", season: "2", episode: "4")
        restored.recordProgress(for: item, position: 0, duration: 0, request: next)
        XCTAssertEqual(restored.history.first?.episodeID, "4")
        XCTAssertEqual(restored.history.first?.duration, 0)
        XCTAssertEqual(restored.continueWatching.count, 1)
        let relaunched = AppModel(defaults: defaults)
        XCTAssertEqual(relaunched.episodeRecord(mediaID: "42", season: "2", episode: "3")?.progress, 1)
        XCTAssertEqual(relaunched.history.first?.episodeID, "4")
    }
}
#endif
