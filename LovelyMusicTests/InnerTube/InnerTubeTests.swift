import XCTest
@testable import LovelyMusic

final class InnerTubeTests: XCTestCase {
    func testYouTubeClientConfigurations() {
        XCTAssertEqual(YouTubeClient.webRemix.clientName, "WEB_REMIX")
        XCTAssertEqual(YouTubeClient.ios.clientName, "IOS")
        XCTAssertEqual(YouTubeClient.androidVR.clientName, "ANDROID_VR")
    }
    
    func testContextCreation() {
        let locale = YouTubeLocale(gl: "VN", hl: "vi")
        let context = YouTubeClient.webRemix.toContext(locale: locale, visitorData: "test")
        XCTAssertEqual(context.client.clientName, "WEB_REMIX")
        XCTAssertEqual(context.client.gl, "VN")
        XCTAssertEqual(context.client.hl, "vi")
    }
}
