import Foundation

/// Loads API keys from `Secrets.plist` (excluded from source control).
/// See `Secrets.plist.example` for the required structure.
enum SecretsProvider {

    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        else {
            return [:]
        }
        return dict
    }()

    // MARK: - MicroCMS

    static var microCMSAPIKey: String? {
        secrets["MICROCMS_API_KEY"]
    }

    // MARK: - YouTube InnerTube

    static var innerTubeKeyWebRemix: String {
        secrets["INNERTUBE_KEY_WEB_REMIX"] ?? ""
    }

    static var innerTubeKeyIOS: String {
        secrets["INNERTUBE_KEY_IOS"] ?? ""
    }

    static var innerTubeKeyTVHTML5: String {
        secrets["INNERTUBE_KEY_TVHTML5"] ?? ""
    }

    static var innerTubeKeyAndroidMusic: String {
        secrets["INNERTUBE_KEY_ANDROID_MUSIC"] ?? ""
    }

    static var innerTubeKeyWeb: String {
        secrets["INNERTUBE_KEY_WEB"] ?? ""
    }

    static var innerTubeKeyAndroidVR: String {
        secrets["INNERTUBE_KEY_ANDROID_VR"] ?? ""
    }

    // MARK: - AdMob

    /// Production AdMob banner ad unit ID. `nil` if not configured in Secrets.plist.
    /// Callers (e.g. `AdManager`) MUST fall back to Google's public test ID when nil.
    static var adMobBannerUnitID: String? {
        nonEmpty(secrets["AdMobBannerUnitID"])
    }

    /// Production AdMob interstitial ad unit ID. `nil` if not configured in Secrets.plist.
    /// Callers (e.g. `AdManager`) MUST fall back to Google's public test ID when nil.
    static var adMobInterstitialUnitID: String? {
        nonEmpty(secrets["AdMobInterstitialUnitID"])
    }

    // MARK: - Push Notifications

    /// Base URL for the Cloudflare Worker APNs dispatcher.
    static var pushNotificationBaseURL: URL? {
        if let customUrlString = nonEmpty(secrets["PUSH_NOTIFICATION_BASE_URL"]),
           let url = URL(string: customUrlString) {
            return url
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value, !v.isEmpty else { return nil }
        // Sentinel rejection (review finding 2026-05-02): example/template files
        // ship placeholder strings like `ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX`
        // or `YOUR_API_KEY_HERE`. Treat them as missing so callers can fall back
        // to safe defaults rather than ship a malformed ID to production.
        let upper = v.uppercased()
        if upper.contains("XXXXXX") || upper.contains("YOUR_") || upper.contains("PLACEHOLDER") {
            return nil
        }
        return v
    }
}
