import XCTest

@testable import LovelyMusic

/// S5.2 — Episode pageType detection (TDD RED phase).
///
/// Per the locked architectural decision (Option B, mirroring S5.1's
/// Podcast → Playlist{isPodcast:true} reduction), Episodes surface as the
/// existing `Song` entity with two new optional flags:
///   • `isEpisode: Bool = false`
///   • `episodeOf: String?` — show name (nil for non-episodes).
/// We do NOT introduce a new domain entity or `MusicSectionItem` case.
///
/// EXPECTED RED MODE: these tests fail to **compile** with
/// `extra argument 'isEpisode' in call` / `Value of type 'Song' has no
/// member 'isEpisode'` because the fields have not yet been added to
/// `Song`. The implementer's next step is to add both with safe defaults
/// so all existing positional and labelled `Song` initialisers keep
/// compiling.
final class SongEpisodeTests: XCTestCase {

    /// #1 RED — Default values: a freshly-constructed Song using the
    /// existing call shape must report `isEpisode == false` and
    /// `episodeOf == nil`. Guards against false-positives for the 99% of
    /// non-episode songs.
    func testSongDefaults_isEpisodeFalseAndEpisodeOfNil() {
        let song = Song(
            id: "vid_regular",
            title: "Just a Song",
            artistName: "Some Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 180,
            thumbnailURL: nil
        )
        XCTAssertFalse(
            song.isEpisode,
            "Newly-constructed Song must default to isEpisode=false."
        )
        XCTAssertNil(
            song.episodeOf,
            "Newly-constructed Song must default to episodeOf=nil."
        )
    }

    /// #2 RED — Episode flags can be set explicitly via the memberwise
    /// init and round-trip into the resulting struct.
    func testSongEpisodeFlags_setExplicitly_arePreserved() {
        let song = Song(
            id: "ep_video_id_1",
            title: "Episode 42: The AI Beat",
            artistName: "Hard Fork",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 2_400,
            thumbnailURL: nil,
            isEpisode: true,
            episodeOf: "Hard Fork"
        )
        XCTAssertTrue(song.isEpisode)
        XCTAssertEqual(song.episodeOf, "Hard Fork")
    }
}
