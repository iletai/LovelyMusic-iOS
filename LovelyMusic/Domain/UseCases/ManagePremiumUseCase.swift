import Foundation

final class ManagePremiumUseCase {
    private let repository: PremiumRepositoryProtocol

    init(repository: PremiumRepositoryProtocol) {
        self.repository = repository
    }

    func checkPremiumStatus() async -> Bool {
        await repository.isPremium
    }

    func getAvailableProducts() async throws -> [PremiumProduct] {
        try await repository.availableProducts()
    }

    func purchase(_ product: PremiumProduct) async throws -> Bool {
        try await repository.purchase(product)
    }

    func restorePurchases() async throws -> Bool {
        try await repository.restorePurchases()
    }
}
