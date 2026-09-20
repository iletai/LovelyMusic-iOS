import Foundation
import Security
import CryptoKit
import os

@MainActor @Observable
final class YouTubeAuthManager {
    private static let logger = Logger(subsystem: "com.lovelymusic.app", category: "YouTubeAuth")

    private(set) var isLoggedIn: Bool = false
    private(set) var accountName: String?
    private(set) var accountPhotoURL: String?

    private let keychainService = "com.lovelymusic.youtube-auth"

    init() {
        loadFromKeychain()
    }

    // MARK: - Cookie Management

    func storeAuthCookies(_ cookies: [HTTPCookie]) {
        let authCookieNames: Set<String> = [
            "SAPISID", "SID", "HSID", "SSID", "APISID",
            "LOGIN_INFO", "__Secure-1PSID", "__Secure-3PSID",
            "VISITOR_INFO1_LIVE"
        ]
        let authCookies = cookies.filter { authCookieNames.contains($0.name) }
        guard !authCookies.isEmpty else { return }

        let cookieProperties = authCookies.map { $0.properties ?? [:] }
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: cookieProperties,
            requiringSecureCoding: true
        ) else {
            Self.logger.error("Failed to archive auth cookies")
            return
        }

        guard saveToKeychain(data: data, key: "cookies") else {
            Self.logger.error("Failed to persist auth cookies to Keychain — user will appear signed in only for this session")
            return
        }

        if authCookies.contains(where: { $0.name == "LOGIN_INFO" }) {
            accountName = "YouTube User"
        }

        isLoggedIn = true
        // Notify DIContainer to update InnerTubeAPI with the new auth cookies.
        // DIContainer observes .settingsChanged and calls innerTubeAPI.setCookie().
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    func getAuthCookies() -> [HTTPCookie] {
        guard let data = loadFromKeychain(key: "cookies"),
              let properties = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSArray.self, NSDictionary.self, NSString.self,
                              NSNumber.self, NSDate.self, NSURL.self],
                  from: data
              ) as? [[HTTPCookiePropertyKey: Any]] else {
            return []
        }
        return properties.compactMap { HTTPCookie(properties: $0) }
    }

    func cookieHeaderString() -> String? {
        let cookies = getAuthCookies()
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func authorizationHeader() -> String? {
        let cookies = getAuthCookies()
        guard let sapisid = cookies.first(where: { $0.name == "SAPISID" })?.value else {
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let origin = "https://music.youtube.com"
        let input = "\(timestamp) \(sapisid) \(origin)"

        guard let hash = sha1(input) else { return nil }
        return "SAPISIDHASH \(timestamp)_\(hash)"
    }

    func logout() {
        deleteFromKeychain(key: "cookies")
        deleteFromKeychain(key: "accountName")
        isLoggedIn = false
        accountName = nil
        accountPhotoURL = nil
    }

    // MARK: - Keychain Helpers

    @discardableResult
    private func saveToKeychain(data: Data, key: String) -> Bool {
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Self.logger.error("Keychain add failed for key '\(key, privacy: .public)': OSStatus \(addStatus)")
                return false
            }
            return true
        default:
            Self.logger.error("Keychain update failed for key '\(key, privacy: .public)': OSStatus \(updateStatus)")
            return false
        }
    }

    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func loadFromKeychain() {
        if let data = loadFromKeychain(key: "cookies"),
           let properties = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSArray.self, NSDictionary.self, NSString.self,
                           NSNumber.self, NSDate.self, NSURL.self],
               from: data
           ) as? [[HTTPCookiePropertyKey: Any]] {
            let cookies = properties.compactMap { HTTPCookie(properties: $0) }
            isLoggedIn = !cookies.isEmpty
            Self.logger.info("Keychain auth cookies loaded: \(cookies.count, privacy: .public) cookies")
            if cookies.contains(where: { $0.name == "LOGIN_INFO" }) {
                accountName = "YouTube User"
            }
        } else {
            Self.logger.info("No auth cookies in Keychain")
        }
    }

    // MARK: - SHA1 Hash

    private func sha1(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        let hash = Insecure.SHA1.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
