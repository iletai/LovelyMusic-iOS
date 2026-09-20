import Foundation
import os

public final class PushTokenRepository: PushTokenRepositoryProtocol, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let baseURL: URL?
    private let tokenKey = "com.lovelymusic.apns.deviceToken"
    private let logger = Logger(subsystem: "com.lovelymusic.app", category: "PushTokenRepository")

    public init(
        userDefaultsSuite: String? = nil,
        baseURL: URL? = nil
    ) {
        if let suite = userDefaultsSuite {
            self.userDefaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            self.userDefaults = .standard
        }
        self.baseURL = baseURL ?? SecretsProvider.pushNotificationBaseURL
    }

    public func getPersistedToken() async -> String? {
        userDefaults.string(forKey: tokenKey)
    }

    public func saveTokenLocally(_ token: String) async throws {
        userDefaults.set(token, forKey: tokenKey)
    }

    public func registerTokenWithBackend(
        token: String,
        locale: String,
        appVersion: String,
        osVersion: String
    ) async throws {
        guard let baseURL = baseURL else { return }
        let endpoint = baseURL.appendingPathComponent("api/v1/devices/register")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "deviceToken": token,
            "locale": locale,
            "appVersion": appVersion,
            "osVersion": osVersion
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            logger.error("Failed to register token status: \(httpResponse.statusCode)")
            throw NSError(
                domain: "com.lovelymusic.PushTokenRepository",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Backend registration failed with status \(httpResponse.statusCode)"]
            )
        }
    }

    public func unregisterToken() async throws {
        if let token = userDefaults.string(forKey: tokenKey), let baseURL = baseURL {
            let endpoint = baseURL.appendingPathComponent("api/v1/devices/unregister")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceToken": token])
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                logger.error("Failed to unregister token status: \(httpResponse.statusCode)")
                throw NSError(
                    domain: "com.lovelymusic.PushTokenRepository",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Backend unregistration failed with status \(httpResponse.statusCode)"]
                )
            }
        }
        userDefaults.removeObject(forKey: tokenKey)
    }
}
