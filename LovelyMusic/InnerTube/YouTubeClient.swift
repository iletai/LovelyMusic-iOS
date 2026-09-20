import Foundation

struct YouTubeClient {
    let clientName: String
    let clientId: String
    let clientVersion: String
    let apiKey: String
    let userAgent: String
    let osVersion: String?
    let referer: String?
    let deviceMake: String?
    let deviceModel: String?
    let platform: String?

    init(
        clientName: String,
        clientId: String,
        clientVersion: String,
        apiKey: String,
        userAgent: String,
        osVersion: String? = nil,
        referer: String? = nil,
        deviceMake: String? = nil,
        deviceModel: String? = nil,
        platform: String? = nil
    ) {
        self.clientName = clientName
        self.clientId = clientId
        self.clientVersion = clientVersion
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.osVersion = osVersion
        self.referer = referer
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.platform = platform
    }

    func toContext(locale: YouTubeLocale, visitorData: String?) -> InnerTubeContext {
        InnerTubeContext(
            client: InnerTubeContext.Client(
                clientName: clientName,
                clientVersion: clientVersion,
                osVersion: osVersion,
                gl: locale.gl,
                hl: locale.hl,
                visitorData: visitorData,
                deviceMake: deviceMake,
                deviceModel: deviceModel,
                platform: platform,
                userAgent: userAgent
            )
        )
    }
}

extension YouTubeClient {
    static let refererYouTubeMusic = "https://music.youtube.com/"

    // Keep in sync with clientVersion — YouTube may cross-check UA and client metadata.
    static let userAgentWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
    static let userAgentAndroid = "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A.240805.005) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36"
    static let userAgentIOS = "com.google.ios.youtube/21.03.2 (iPhone16,2; U; CPU_iPhone_OS_18_3_2 like Mac OS X)"

    /// Generates a date-based WEB_REMIX client version in the format YouTube uses:
    /// `1.YYYYMMDD.01.00`. YouTube treats stale client versions as degraded sessions,
    /// returning fewer/older recommendations. Using today's date (UTC) ensures the
    /// app always appears as a fresh client installation.
    private static var dynamicWebRemixVersion: String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return "1.\(formatter.string(from: now)).01.00"
    }

    // Dynamic version ensures YouTube always treats us as a current client,
    // returning the latest content/recommendations without degradation.
    static let webRemix = YouTubeClient(
        clientName: "WEB_REMIX",
        clientId: "67",
        clientVersion: dynamicWebRemixVersion,
        apiKey: SecretsProvider.innerTubeKeyWebRemix,
        userAgent: userAgentWeb,
        referer: refererYouTubeMusic,
        platform: "DESKTOP"
    )

    static let ios = YouTubeClient(
        clientName: "IOS",
        clientId: "5",
        clientVersion: "21.03.2",
        apiKey: SecretsProvider.innerTubeKeyIOS,
        userAgent: userAgentIOS,
        osVersion: "18.3.2.22D82",
        deviceMake: "Apple",
        deviceModel: "iPhone16,2",
        platform: "MOBILE"
    )

    // MARK: - Deprecated clients (removed from YouTube, kept for reference)
    // tvhtml5 — removed by YouTube Jan 2026
    // androidMusic (ID 21) — blocked since Dec 2024
    // web (ID 1) — now requires SABR (Streaming ABR), unusable

    // VISIONOS (ID 101) — returns hlsManifestUrl + direct URLs with no byte-range limit.
    // Added yt-dlp 2026-07-09 as ANDROID_VR replacement. No PO token required.
    static let userAgentVisionOS = "com.google.vr.youtube/1.02 (Apple Vision Pro; U; visionOS 26.5 like Mac OS X)"

    static let visionOS = YouTubeClient(
        clientName: "VISIONOS",
        clientId: "101",
        clientVersion: "1.02",
        apiKey: SecretsProvider.innerTubeKeyAndroidVR,
        userAgent: userAgentVisionOS,
        osVersion: "26.5",
        deviceMake: "Apple",
        deviceModel: "RealityDevice17,1",
        platform: "MOBILE"
    )

    static let userAgentAndroidVR = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    static let androidVR = YouTubeClient(
        clientName: "ANDROID_VR",
        clientId: "28",
        clientVersion: "1.65.10",
        apiKey: SecretsProvider.innerTubeKeyAndroidVR,
        userAgent: userAgentAndroidVR,
        osVersion: "12L",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        platform: "MOBILE"
    )
}
