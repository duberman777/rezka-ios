import XCTest
import AVKit

@MainActor
final class RezkaUITests: XCTestCase {
    func testCategoryTilesScheduleAndMatchingPlaybackActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures", "--rezka-ui-polish"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 20))
        let categories = app.buttons["Categories"]
        for _ in 0..<3 where !categories.isHittable { app.swipeUp() }
        XCTAssertTrue(categories.isHittable)
        categories.tap()
        let western = app.buttons["category-movie-western"]
        XCTAssertTrue(western.waitForExistence(timeout: 10))
        capture(app, name: "Generated category tile grid")
        let family = app.buttons["category-movie-family"]
        XCTAssertLessThan(abs(western.frame.minY - family.frame.minY), 2)
        XCTAssertGreaterThan(family.frame.minX, western.frame.maxX)
        app.buttons["Anime"].tap()
        XCTAssertTrue(app.buttons["category-anime-mecha"].exists)
        app.buttons["Movies"].tap()
        western.tap()
        XCTAssertTrue(app.staticTexts["Глубина"].firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Глубина")).firstMatch.tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let download = app.buttons["download-title"]
        XCTAssertEqual(play.frame.height, download.frame.height, accuracy: 1)
        capture(app, name: "Matching native glass playback buttons")
        let schedule = app.buttons["expand-release-schedule"]
        for _ in 0..<10 where !schedule.isHittable { app.swipeUp() }
        XCTAssertTrue(schedule.isHittable)
        XCTAssertFalse(app.staticTexts["Глубина - даты выхода серий 1 сезона"].exists)
        capture(app, name: "Compact release schedule")
        schedule.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Show fewer episodes"), evaluatedWith: schedule)
        waitForExpectations(timeout: 5)
        capture(app, name: "Expanded release schedule")
        let finalEpisode = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Бездна сиротства")).firstMatch
        for _ in 0..<2 where !finalEpisode.exists { app.swipeUp() }
        XCTAssertTrue(finalEpisode.waitForExistence(timeout: 5))
        XCTAssertTrue(schedule.label.contains("Show fewer episodes"))
    }

    func testPlayerStaysFullScreenAcrossBothLandscapeDirections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures", "--rezka-ui-series"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 20))
        app.buttons["featured-title"].tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        if !play.isHittable { app.swipeUp() }
        play.tap()
        let player = app.otherElements["native-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        for orientation in [UIDeviceOrientation.landscapeRight, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let matchesScreen = NSPredicate { _, _ in
                let screen = app.windows.firstMatch.frame
                return player.exists && abs(player.frame.width - screen.width) < 2 && abs(player.frame.height - screen.height) < 2
            }
            expectation(for: matchesScreen, evaluatedWith: player)
            waitForExpectations(timeout: 8)
            XCTAssertFalse(app.buttons["episode-1-1"].isHittable)
            capture(app, name: "Full screen rotation \(orientation.rawValue)")
        }
        closeNativePlayer(app)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
    }

    func testPolishedDetailsAndFranchiseNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures", "--rezka-ui-polish"]
        app.launch()
        let featured = app.buttons["featured-title"]
        XCTAssertTrue(featured.waitForExistence(timeout: 20))
        featured.tap()
        XCTAssertTrue(app.buttons["play-title"].waitForExistence(timeout: 10))
        capture(app, name: "Polished title and playback settings")
        let more = app.buttons["Read more"]
        for _ in 0..<4 where !more.isHittable { app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(app.buttons["Show less"].exists)
        XCTAssertFalse(app.staticTexts["Duplicate website ratings"].exists)
        capture(app, name: "Story and cast portraits")
        let related = app.buttons["Ещё одна история с длинным названием для проверки переноса текста, 2025"]
        for _ in 0..<5 where !related.isHittable { app.swipeUp() }
        XCTAssertTrue(related.isHittable)
        capture(app, name: "Complete information and related titles")
        related.tap()
        XCTAssertTrue(app.buttons["play-title"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(related.waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testNativeScreenFitAndPlayButtonFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures"]
        app.launch()
        let featured = app.buttons["featured-title"]
        XCTAssertTrue(featured.waitForExistence(timeout: 20))
        let brand = app.staticTexts["Rezka"].firstMatch
        XCTAssertTrue(brand.exists)
        XCTAssertLessThan(brand.frame.minY, 120, "Content must start below the status bar without a compatibility border")
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Native home layout"
        home.lifetime = .keepAlways
        add(home)
        featured.tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        if !play.isHittable { app.swipeUp() }
        XCTAssertTrue(play.isEnabled)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Native detail layout"
        detail.lifetime = .keepAlways
        add(detail)
        play.tap()
        XCTAssertTrue(app.otherElements["native-player"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts["Something went wrong"].exists)
        XCUIDevice.shared.orientation = .landscapeRight
        let nativePlayer = app.otherElements["native-player"]
        let landscape = NSPredicate { _, _ in nativePlayer.frame.width > nativePlayer.frame.height }
        expectation(for: landscape, evaluatedWith: nativePlayer)
        waitForExpectations(timeout: 5)
        let player = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        player.name = "Native full screen player"
        player.lifetime = .keepAlways
        add(player)
        closeNativePlayer(app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(play.waitForExistence(timeout: 5))
    }

    func testEpisodesHidePremiumAndAdvanceAcrossSeasonBoundary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures", "--rezka-ui-series", "--rezka-ui-finished-episode"]
        app.launch()
        let featured = app.buttons["featured-title"]
        XCTAssertTrue(featured.waitForExistence(timeout: 20))
        featured.tap()
        let episode = app.buttons["episode-1-1"]
        if !episode.isHittable { app.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Premium dub"].exists)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "Season and episode list"
        list.lifetime = .keepAlways
        add(list)
        episode.tap()
        XCTAssertTrue(app.otherElements["native-player"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["next-episode"].exists)
        XCTAssertFalse(app.staticTexts["720p"].exists)
        closeNativePlayer(app)
        XCTAssertEqual(app.buttons["play-title"].label, "Play S2 E1")
    }
    func testAutoplayContinuesWithNextSeason() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures", "--rezka-ui-series", "--rezka-ui-finished-episode", "--rezka-ui-autoplay"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 20))
        app.buttons["featured-title"].tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        if !play.isHittable { app.swipeUp() }
        play.tap()
        let native = app.otherElements["native-player"]
        XCTAssertTrue(native.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value == %@", "Season 2, episode 1"), evaluatedWith: native)
        waitForExpectations(timeout: 20)
        closeNativePlayer(app)
    }

    func testCountryExclusionHidesCatalogueAndClearingRestoresTitles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["excluded-countries"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Italy")
        let toggle = app.switches["exclude-country-IT"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Excluded country setting"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(app.buttons["featured-title"].exists)
        app.tabBars.buttons["Settings"].tap()
        let clear = app.buttons["clear-country-exclusions"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 5))
    }

    func testNativePictureInPictureControlIsAvailable() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw XCTSkip("Picture in Picture is unavailable on this test device")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["featured-title"].waitForExistence(timeout: 20))
        app.buttons["featured-title"].tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        if !play.isHittable { app.swipeUp() }
        play.tap()
        let native = app.otherElements["native-player"]
        XCTAssertTrue(native.waitForExistence(timeout: 15))
        let pip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Picture in Picture")).firstMatch
        if !pip.exists { native.tap() }
        let controls = XCTAttachment(string: app.debugDescription)
        controls.name = "Native playback controls"
        controls.lifetime = .keepAlways
        add(controls)
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        XCTAssertTrue(pip.isEnabled)
        pip.tap()
        XCUIDevice.shared.press(.home)
        let floatingPlayer = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        floatingPlayer.name = "System Picture in Picture"
        floatingPlayer.lifetime = .keepAlways
        add(floatingPlayer)
        app.activate()
        XCTAssertTrue(native.waitForExistence(timeout: 5))
        closeNativePlayer(app)
    }

    func testCollectionTitlesOpenImmediatelyAndBackReturnsToCollection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--rezka-ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["Collections"].waitForExistence(timeout: 20))
        app.buttons["Collections"].tap()
        let collection = app.buttons["collection-Screen test collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 15))
        collection.tap()
        let title = app.buttons["catalogue-title-42"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        for _ in 0..<2 {
            title.tap()
            XCTAssertTrue(app.buttons["play-title"].waitForExistence(timeout: 10))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["play-title"].exists)
        }
    }

    func testLiveFeaturedPlaybackOnPhone() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live playback is checked on the paired iPhone")
        #else
        let app = XCUIApplication()
        app.launch()
        let featured = app.buttons["featured-title"]
        XCTAssertTrue(featured.waitForExistence(timeout: 45))
        featured.tap()
        let play = app.buttons["play-title"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        if !play.isHittable { app.swipeUp() }
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: play)
        waitForExpectations(timeout: 30)
        play.tap()
        XCTAssertTrue(app.otherElements["native-player"].waitForExistence(timeout: 40))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live iPhone native playback"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        closeNativePlayer(app)
        #endif
    }
    private func closeNativePlayer(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if !close.exists {
            app.otherElements["native-player"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        if close.waitForExistence(timeout: 3) { close.tap() }
        else { app.buttons["Done"].firstMatch.tap() }
    }
}
