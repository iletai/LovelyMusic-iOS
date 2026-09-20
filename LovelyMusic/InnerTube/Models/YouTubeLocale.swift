import Foundation

struct YouTubeLocale {
    var gl: String
    var hl: String

    static var `default`: YouTubeLocale {
        YouTubeLocale(
            gl: Locale.current.region?.identifier ?? "US",
            hl: Locale.current.language.languageCode?.identifier ?? "en"
        )
    }
}
