import XCTest
@testable import LovelyMusic

@MainActor
final class ManagePremiumUseCaseTests: XCTestCase {
    private var sut: ManagePremiumUseCase!
    private var mockRepo: MockPremiumRepository!

    override func setUp() {
        super.setUp()
        mockRepo = MockPremiumRepository()
        sut = ManagePremiumUseCase(repository: mockRepo)
    }

    override func tearDown() {
        sut = nil
        mockRepo = nil
        super.tearDown()
    }

    // MARK: - checkPremiumStatus

    func testCheckPremiumStatus_whenNotPremium_returnsFalse() async {
        mockRepo.premiumStatus = false
        let result = await sut.checkPremiumStatus()
        XCTAssertFalse(result)
    }

    func testCheckPremiumStatus_whenPremium_returnsTrue() async {
        mockRepo.premiumStatus = true
        let result = await sut.checkPremiumStatus()
        XCTAssertTrue(result)
    }

    // MARK: - getAvailableProducts

    func testGetAvailableProducts_returnsProducts() async throws {
        let products = [
            PremiumProduct(id: "monthly", displayName: "Monthly", description: "Monthly plan", displayPrice: "$4.99", type: .monthly),
            PremiumProduct(id: "yearly", displayName: "Yearly", description: "Yearly plan", displayPrice: "$29.99", type: .yearly)
        ]
        mockRepo.mockProducts = products

        let result = try await sut.getAvailableProducts()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "monthly")
        XCTAssertEqual(result[1].id, "yearly")
    }

    func testGetAvailableProducts_whenEmpty_returnsEmpty() async throws {
        mockRepo.mockProducts = []
        let result = try await sut.getAvailableProducts()
        XCTAssertTrue(result.isEmpty)
    }

    func testGetAvailableProducts_whenError_throws() async {
        mockRepo.shouldThrow = true
        do {
            _ = try await sut.getAvailableProducts()
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - purchase

    func testPurchase_success_returnsTrue() async throws {
        let product = PremiumProduct(id: "monthly", displayName: "Monthly", description: "desc", displayPrice: "$4.99", type: .monthly)
        mockRepo.purchaseResult = true

        let result = try await sut.purchase(product)
        XCTAssertTrue(result)
        let isPremium = await mockRepo.isPremium
        XCTAssertTrue(isPremium)
    }

    func testPurchase_whenError_throws() async {
        let product = PremiumProduct(id: "monthly", displayName: "Monthly", description: "desc", displayPrice: "$4.99", type: .monthly)
        mockRepo.shouldThrow = true

        do {
            _ = try await sut.purchase(product)
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    // MARK: - restorePurchases

    func testRestorePurchases_whenHasSubscription_returnsTrue() async throws {
        mockRepo.restoreResult = true
        let result = try await sut.restorePurchases()
        XCTAssertTrue(result)
    }

    func testRestorePurchases_whenNoSubscription_returnsFalse() async throws {
        mockRepo.restoreResult = false
        let result = try await sut.restorePurchases()
        XCTAssertFalse(result)
    }

    func testRestorePurchases_whenError_throws() async {
        mockRepo.shouldThrow = true
        do {
            _ = try await sut.restorePurchases()
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }
}
