import Foundation

struct PremiumProduct: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    let type: ProductType

    enum ProductType {
        case monthly, yearly, lifetime
    }
}
