import Foundation

protocol PremiumRepositoryProtocol {
    var isPremium: Bool { get async }
    func availableProducts() async throws -> [PremiumProduct]
    func purchase(_ product: PremiumProduct) async throws -> Bool
    func restorePurchases() async throws -> Bool
}
