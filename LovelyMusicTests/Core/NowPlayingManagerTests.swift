import MediaPlayer
import XCTest

@testable import LovelyMusic

@MainActor
final class NowPlayingManagerTests: XCTestCase {

    private func makeSong(duration: Int? = 240, thumbnail: String? = nil) -> Song {
        Song(
            id: "abc12345678",
            title: "Test Title",
            artistName: "Test Artist",
            artistId: nil,
            albumName: "Test Album",
            albumId: nil,
            duration: duration,
            thumbnailURL: thumbnail
        )
    }

    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    // MARK: - F2 — Duration ≤ 0 omitted

    func testSetNowPlayingInfo_omitsDurationWhenZero() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: 0)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNotNil(info)
        XCTAssertNil(
            info?[MPMediaItemPropertyPlaybackDuration],
            "Duration must be omitted when value is 0 to avoid 'live stream' classification")
    }

    func testSetNowPlayingInfo_omitsDurationWhenNegative() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: -1)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNil(info?[MPMediaItemPropertyPlaybackDuration])
    }

    func testSetNowPlayingInfo_includesDurationWhenPositive() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: 240)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, 240)
    }

    // MARK: - F6 — MediaType set

    func testSetNowPlayingInfo_setsMediaTypeAudio() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: 100)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(
            info?[MPNowPlayingInfoPropertyMediaType] as? UInt,
            MPNowPlayingInfoMediaType.audio.rawValue
        )
    }

    // MARK: - F4 — Pre-rendered fallback artwork is non-empty

    func testFallbackArtwork_isNonEmpty() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(thumbnail: nil), duration: 100)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let artwork = info?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertNotNil(artwork, "Fallback artwork must be present even when song has no thumbnail")
        let image = artwork?.image(at: CGSize(width: 300, height: 300))
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(
            image?.size.width ?? 0, 0,
            "Pre-rendered fallback must have non-zero width")
        XCTAssertGreaterThan(
            image?.size.height ?? 0, 0,
            "Pre-rendered fallback must have non-zero height")
    }

    // MARK: - F7 — updatePlaybackState is a no-op before setNowPlayingInfo

    func testUpdatePlaybackState_isNoOp_beforeFirstSetNowPlayingInfo() {
        // Ensure clean slate — no info dictionary has been written yet.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let manager = NowPlayingManager()
        manager.updatePlaybackState(isPlaying: true, currentTime: 10, rate: 1.0)

        XCTAssertNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo,
            "updatePlaybackState must not write a degenerate dictionary lacking title/artist"
        )
    }

    func testUpdatePlaybackState_isNoOp_whenInfoLacksTitle() {
        // Simulate a third party (or stale state) writing only state keys.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]

        let manager = NowPlayingManager()
        manager.updatePlaybackState(isPlaying: true, currentTime: 30, rate: 1.0)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(
            info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, 0.0,
            "Should not have updated elapsed time when no title is present"
        )
    }

    func testUpdatePlaybackState_appliesAfterSetNowPlayingInfo() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: 240)
        manager.updatePlaybackState(isPlaying: true, currentTime: 42, rate: 1.0)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, 42)
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        // Title preserved (proves we didn't blow away the dictionary).
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Test Title")
    }

    // MARK: - Clearing

    func testUpdateNowPlayingInfo_withNilSong_clearsCenter() {
        let manager = NowPlayingManager()
        manager.updateNowPlayingInfo(song: makeSong(), duration: 100)
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

        manager.updateNowPlayingInfo(song: nil, duration: 0)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
}
