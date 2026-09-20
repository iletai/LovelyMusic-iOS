import XCTest

@testable import LovelyMusic

@MainActor
final class PremiumManagerRedemptionFeedbackTests: XCTestCase {

    // MARK: - Helpers

    /// Build a manager with a short auto-clear interval so timing tests stay fast.
    private func makeManager(autoClearInterval: TimeInterval = 0.3) -> PremiumManager {
        PremiumManager(
            featureFlagManager: nil, redemptionFeedbackAutoClearInterval: autoClearInterval)
    }

    // MARK: - 1. Success path sets success feedback

    func test_setRedemptionSuccess_setsSuccessFeedback() {
        let manager = makeManager(autoClearInterval: 60)  // long interval — assert on initial state
        manager.setRedemptionSuccess()

        guard case .success(let message) = manager.redemptionFeedback else {
            return XCTFail(
                "Expected .success feedback, got \(String(describing: manager.redemptionFeedback))")
        }
        XCTAssertFalse(message.isEmpty, "Success message must not be empty")
    }

    // MARK: - 2. Failure path sets failure feedback with the supplied message

    func test_setRedemptionFailure_setsFailureFeedbackWithMessage() {
        let manager = makeManager(autoClearInterval: 60)
        let expected = "Code is invalid or already used"
        manager.setRedemptionFailure(expected)

        guard case .failure(let message) = manager.redemptionFeedback else {
            return XCTFail(
                "Expected .failure feedback, got \(String(describing: manager.redemptionFeedback))")
        }
        XCTAssertEqual(message, expected)
    }

    // MARK: - 3. Auto-clears after the configured interval

    func test_redemptionFeedback_clearsAutomatically_afterInterval() async throws {
        let manager = makeManager(autoClearInterval: 0.3)
        manager.setRedemptionSuccess()
        XCTAssertNotNil(manager.redemptionFeedback, "Feedback must be set immediately after call")

        // Wait > interval, then assert it cleared.
        try await Task.sleep(nanoseconds: 600_000_000)  // 0.6 s
        XCTAssertNil(
            manager.redemptionFeedback, "Feedback must auto-clear after the configured interval")
    }

    // MARK: - 4. New feedback cancels the prior pending clear task

    func test_setRedemptionSuccess_cancelsPriorFailureClearTask() async throws {
        let manager = makeManager(autoClearInterval: 0.3)

        manager.setRedemptionFailure("first error")
        // Replace before the failure's clear fires.
        try await Task.sleep(nanoseconds: 50_000_000)  // 0.05 s
        manager.setRedemptionSuccess()

        // At a point AFTER the original 0.3 s window but BEFORE the new
        // 0.3 s window expires, the success must still be present — proving
        // the prior clear task was cancelled and did not wipe the new value.
        try await Task.sleep(nanoseconds: 200_000_000)  // total ~0.25 s
        guard case .success = manager.redemptionFeedback else {
            return XCTFail("Expected .success to still be present after prior failure was replaced")
        }

        // And after the new window, it should also clear.
        try await Task.sleep(nanoseconds: 250_000_000)  // total ~0.5 s
        XCTAssertNil(
            manager.redemptionFeedback,
            "Replacement feedback must also auto-clear after its own interval")
    }
}
