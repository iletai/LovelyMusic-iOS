import Foundation
@testable import LovelyMusic

@MainActor
final class MockPremiumRepository: PremiumRepositoryProtocol {
    var premiumStatus = false
    var mockProducts: [PremiumProduct] = []
    var purchaseResult = true
    var restoreResult = false
    var shouldThrow = false

    var isPremium: Bool {
        get async { premiumStatus }
    }

    func availableProducts() async throws -> [PremiumProduct] {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        return mockProducts
    }

    func purchase(_ product: PremiumProduct) async throws -> Bool {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        premiumStatus = purchaseResult
        return purchaseResult
    }

    func restorePurchases() async throws -> Bool {
        if shouldThrow { throw NSError(domain: "test", code: -1) }
        premiumStatus = restoreResult
        return restoreResult
    }
}
