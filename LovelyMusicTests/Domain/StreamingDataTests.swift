import XCTest
@testable import LovelyMusic

final class StreamingDataTests: XCTestCase {
    func testBestAudioFormat() {
        let formats = [
            StreamFormat(itag: 140, url: "https://audio1", mimeType: "audio/mp4", bitrate: 128000, contentLength: nil, quality: nil, audioQuality: "AUDIO_QUALITY_MEDIUM", audioSampleRate: "44100", audioChannels: 2, approxDurationMs: nil, width: nil, height: nil),
            StreamFormat(itag: 251, url: "https://audio2", mimeType: "audio/webm", bitrate: 160000, contentLength: nil, quality: nil, audioQuality: "AUDIO_QUALITY_HIGH", audioSampleRate: "48000", audioChannels: 2, approxDurationMs: nil, width: nil, height: nil),
            StreamFormat(itag: 22, url: "https://video1", mimeType: "video/mp4", bitrate: 720000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let best = data.bestAudioFormat()
        XCTAssertNotNil(best)
        // Only audio/mp4 is compatible with AVPlayer; audio/webm is excluded
        XCTAssertEqual(best?.itag, 140)
        XCTAssertEqual(best?.bitrate, 128000)
    }

    func testBestAudioFormatNoAudio() {
        let formats = [
            StreamFormat(itag: 22, url: "https://video1", mimeType: "video/mp4", bitrate: 720000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        XCTAssertNil(data.bestAudioFormat())
    }

    func testBestAudioFormatEmpty() {
        let data = StreamingData(formats: [], adaptiveFormats: [], expiresAt: nil)
        XCTAssertNil(data.bestAudioFormat())
    }

    func testBestAudioFormatSingleAudio() {
        let formats = [
            StreamFormat(itag: 140, url: "https://audio1", mimeType: "audio/mp4", bitrate: 128000, contentLength: nil, quality: nil, audioQuality: "AUDIO_QUALITY_MEDIUM", audioSampleRate: "44100", audioChannels: 2, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let best = data.bestAudioFormat()
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.itag, 140)
    }

    func testStreamFormatIsAudioOnly() {
        let audioFormat = StreamFormat(itag: 140, url: nil, mimeType: "audio/mp4", bitrate: 128000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil)
        let videoFormat = StreamFormat(itag: 22, url: nil, mimeType: "video/mp4", bitrate: 720000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil)
        XCTAssertTrue(audioFormat.isAudioOnly)
        XCTAssertFalse(videoFormat.isAudioOnly)
    }

    func testBestAudioFormatNilBitrate() {
        let formats = [
            StreamFormat(itag: 140, url: "https://audio1", mimeType: "audio/mp4", bitrate: nil, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
            StreamFormat(itag: 251, url: "https://audio2", mimeType: "audio/webm", bitrate: 160000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let best = data.bestAudioFormat()
        // Only audio/mp4 is compatible; itag 140 with nil bitrate (treated as 0) is selected
        XCTAssertEqual(best?.itag, 140)
    }

    func testBestAudioFormatFallbackToLowestBitrate() {
        let formats = [
            StreamFormat(itag: 140, url: "https://audio1", mimeType: "audio/mp4", bitrate: 300000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
            StreamFormat(itag: 141, url: "https://audio2", mimeType: "audio/mp4", bitrate: 500000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        // Both exceed high quality limit (256000), fallback picks lowest bitrate
        let best = data.bestAudioFormat(quality: .high)
        XCTAssertEqual(best?.itag, 140)
        XCTAssertEqual(best?.bitrate, 300000)
    }

    func testBestAudioFormatExcludesNilUrl() {
        let formats = [
            StreamFormat(itag: 140, url: nil, mimeType: "audio/mp4", bitrate: 128000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
            StreamFormat(itag: 141, url: "https://audio2", mimeType: "audio/mp4", bitrate: 64000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: [], adaptiveFormats: formats, expiresAt: nil)
        let best = data.bestAudioFormat()
        XCTAssertEqual(best?.itag, 141)
    }

    func testAllFormatsCombinesFormatsAndAdaptive() {
        let regular = [
            StreamFormat(itag: 18, url: "https://v1", mimeType: "video/mp4", bitrate: 500000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let adaptive = [
            StreamFormat(itag: 140, url: "https://a1", mimeType: "audio/mp4", bitrate: 128000, contentLength: nil, quality: nil, audioQuality: nil, audioSampleRate: nil, audioChannels: nil, approxDurationMs: nil, width: nil, height: nil),
        ]
        let data = StreamingData(formats: regular, adaptiveFormats: adaptive, expiresAt: nil)
        XCTAssertEqual(data.allFormats.count, 2)
    }

    func testExpiresAt() {
        let before = Date()
        let data = StreamingData(formats: [], adaptiveFormats: [], expiresAt: Date().addingTimeInterval(3600))
        XCTAssertNotNil(data.expiresAt)
        XCTAssertTrue(data.expiresAt! > before)
    }
}
