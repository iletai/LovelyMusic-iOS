import Foundation
import StoreKit

@MainActor
final class PremiumRepository: PremiumRepositoryProtocol {
    private let premiumManager: PremiumManager

    init(premiumManager: PremiumManager) {
        self.premiumManager = premiumManager
    }

    var isPremium: Bool {
        get async { premiumManager.isPremium }
    }

    func availableProducts() async throws -> [PremiumProduct] {
        await premiumManager.loadProducts()
        return premiumManager.products.map { storeProduct in
            let type: PremiumProduct.ProductType
            switch storeProduct.id {
            case PremiumManager.monthlyProductID: type = .monthly
            case PremiumManager.yearlyProductID: type = .yearly
            case PremiumManager.lifetimeProductID: type = .lifetime
            default: type = .monthly
            }
            return PremiumProduct(
                id: storeProduct.id,
                displayName: storeProduct.displayName,
                description: storeProduct.description,
                displayPrice: storeProduct.displayPrice,
                type: type
            )
        }
    }

    func purchase(_ product: PremiumProduct) async throws -> Bool {
        guard let storeProduct = premiumManager.products.first(where: { $0.id == product.id }) else {
            throw PremiumError.productNotFound
        }
        try await premiumManager.purchase(storeProduct)
        return premiumManager.isPremium
    }

    func restorePurchases() async throws -> Bool {
        try await premiumManager.restorePurchases()
        return premiumManager.isPremium
    }
}

enum PremiumError: LocalizedError {
    case productNotFound

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return String(localized: "The selected product could not be found.")
        }
    }
}
