import Foundation

enum CookieUtils {
    static func parseCookieString(_ cookie: String) -> [String: String] {
        cookie.split(separator: ";")
            .reduce(into: [String: String]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    result[pair[0].trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces)
                }
            }
    }
}
