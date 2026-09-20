import Foundation

public struct RegisterDeviceTokenUseCase: Sendable {
    private let repository: PushTokenRepositoryProtocol

    public init(repository: PushTokenRepositoryProtocol) {
        self.repository = repository
    }

    public func execute(
        token: String,
        locale: String = Locale.current.identifier,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        osVersion: String = "18.0"
    ) async throws {
        try await repository.saveTokenLocally(token)
        do {
            try await registerWithBackend(
                token: token, locale: locale, appVersion: appVersion, osVersion: osVersion)
        } catch {
            // One retry after 2s — backend registrations can fail on transient
            // network errors; a saved local token would otherwise never be retried.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await registerWithBackend(
                token: token, locale: locale, appVersion: appVersion, osVersion: osVersion)
        }
    }

    private func registerWithBackend(
        token: String,
        locale: String,
        appVersion: String,
        osVersion: String
    ) async throws {
        try await repository.registerTokenWithBackend(
            token: token,
            locale: locale,
            appVersion: appVersion,
            osVersion: osVersion
        )
    }
}
