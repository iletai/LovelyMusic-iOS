import XCTest
@testable import LovelyMusic

final class RegisterDeviceTokenUseCaseTests: XCTestCase {
    actor MockPushTokenRepository: PushTokenRepositoryProtocol {
        var savedToken: String?
        var registeredToken: String?
        var registeredLocale: String?
        var failFirstCall = false
        var callCount = 0

        func getPersistedToken() async -> String? { savedToken }
        func saveTokenLocally(_ token: String) async throws { savedToken = token }
        func registerTokenWithBackend(
            token: String,
            locale: String,
            appVersion: String,
            osVersion: String
        ) async throws {
            callCount += 1
            if failFirstCall && callCount == 1 {
                throw NSError(domain: "test", code: -1)
            }
            registeredToken = token
            registeredLocale = locale
        }
        func unregisterToken() async throws { savedToken = nil }
        func setFailFirstCall(_ fail: Bool) { failFirstCall = fail }
    }

    func testExecuteSavesAndRegistersToken() async throws {
        let mockRepo = MockPushTokenRepository()
        let useCase = RegisterDeviceTokenUseCase(repository: mockRepo)
        let sampleToken = "a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0"

        try await useCase.execute(token: sampleToken, locale: "vi_VN")

        let saved = await mockRepo.savedToken
        let registered = await mockRepo.registeredToken
        let locale = await mockRepo.registeredLocale

        XCTAssertEqual(saved, sampleToken)
        XCTAssertEqual(registered, sampleToken)
        XCTAssertEqual(locale, "vi_VN")
    }

    func testExecuteRetriesAfterFirstFailure() async throws {
        let mockRepo = MockPushTokenRepository()
        await mockRepo.setFailFirstCall(true)
        let useCase = RegisterDeviceTokenUseCase(repository: mockRepo)
        let sampleToken = "a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0"

        try await useCase.execute(token: sampleToken, locale: "vi_VN")

        let registered = await mockRepo.registeredToken
        let count = await mockRepo.callCount
        XCTAssertEqual(registered, sampleToken)
        XCTAssertEqual(count, 2)
    }
}
