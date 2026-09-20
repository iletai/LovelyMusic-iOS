import Foundation

public protocol PushTokenRepositoryProtocol: Sendable {
    func getPersistedToken() async -> String?
    func saveTokenLocally(_ token: String) async throws
    func registerTokenWithBackend(
        token: String,
        locale: String,
        appVersion: String,
        osVersion: String
    ) async throws
    func unregisterToken() async throws
}
