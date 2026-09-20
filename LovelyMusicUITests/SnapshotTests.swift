import XCTest

@MainActor
final class SnapshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // Real launch args only — seed onboarding + demo mode for reproducibility.
        app.launchArguments += [
            "-FASTLANE_SNAPSHOT", "YES",
            "-hasCompletedOnboarding",
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["REVIEW_MODE"] = "1"
        app.launchEnvironment["SNAPSHOT_OUTPUT_DIR"] = ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT_DIR"] ?? "/Users/lequangtrongtai/LovelyMusic/fastlane/screenshots/en-US"
        setupSnapshot(app)
        app.launch()
    }

    func test01_Home() {
        Thread.sleep(forTimeInterval: 3)
        snapshot("01_Home")
    }

    func test02_PlayerLyrics() {
        Thread.sleep(forTimeInterval: 2)
        openFullPlayer()
        let lyricsToggle = app.buttons["toggle_lyrics"]
        if lyricsToggle.waitForExistence(timeout: 3) {
            lyricsToggle.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        snapshot("02_PlayerLyrics")
    }

    func test03_PlayerControls() {
        Thread.sleep(forTimeInterval: 2)
        openFullPlayer()
        Thread.sleep(forTimeInterval: 1)
        snapshot("03_PlayerControls")
    }

    func test04_Search() {
        Thread.sleep(forTimeInterval: 2)
        let searchTab = app.buttons["tab_search"]
        if searchTab.waitForExistence(timeout: 3) { searchTab.tap() }
        Thread.sleep(forTimeInterval: 1)
        let searchField = app.textFields.firstMatch
        if searchField.waitForExistence(timeout: 3) {
            searchField.tap()
            searchField.typeText("music")
        }
        Thread.sleep(forTimeInterval: 2)
        snapshot("04_Search")
    }

    func test05_Playlist() {
        Thread.sleep(forTimeInterval: 2)
        let libraryTab = app.buttons["tab_library"]
        if libraryTab.waitForExistence(timeout: 3) { libraryTab.tap() }
        Thread.sleep(forTimeInterval: 1)
        let likedSongs = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Liked Songs'")).firstMatch
        if likedSongs.waitForExistence(timeout: 3) {
            likedSongs.tap()
        } else if app.staticTexts["Liked Songs"].exists {
            app.staticTexts["Liked Songs"].tap()
        }
        Thread.sleep(forTimeInterval: 2)
        snapshot("05_Playlist")
    }

    func test06_Artist() {
        Thread.sleep(forTimeInterval: 2)
        let homeTab = app.buttons["tab_home"]
        if homeTab.waitForExistence(timeout: 3) { homeTab.tap() }
        Thread.sleep(forTimeInterval: 1)
        let artistItem = app.buttons.matching(NSPredicate(format: "label CONTAINS 'by'")).firstMatch
        if artistItem.waitForExistence(timeout: 3) {
            artistItem.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        snapshot("06_Artist")
    }

    func test07_Library() {
        Thread.sleep(forTimeInterval: 2)
        let libraryTab = app.buttons["tab_library"]
        if libraryTab.waitForExistence(timeout: 3) { libraryTab.tap() }
        Thread.sleep(forTimeInterval: 2)
        snapshot("07_Library")
    }

    func test08_Paywall() {
        Thread.sleep(forTimeInterval: 2)
        let homeTab = app.buttons["tab_home"]
        if homeTab.waitForExistence(timeout: 3) { homeTab.tap() }
        Thread.sleep(forTimeInterval: 1)
        let goPremium = app.buttons["go_premium"]
        if goPremium.waitForExistence(timeout: 3) {
            goPremium.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        snapshot("08_Paywall")
    }

    private func openFullPlayer() {
        let homeTab = app.buttons["tab_home"]
        if homeTab.waitForExistence(timeout: 2) { homeTab.tap() }
        Thread.sleep(forTimeInterval: 1)
        let playButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'by' OR label CONTAINS 'Play'")).firstMatch
        if playButton.waitForExistence(timeout: 3) {
            playButton.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        let miniPlayer = app.otherElements["dock_mini_player"].firstMatch
        if miniPlayer.waitForExistence(timeout: 3) {
            miniPlayer.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}