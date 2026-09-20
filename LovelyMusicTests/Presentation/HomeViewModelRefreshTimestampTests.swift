import XCTest

@testable import LovelyMusic

/// Tests for `HomeViewModel.lastSuccessfulRefreshAt` (polish-B5).
/// The timestamp drives the "Updated …" subtitle on Home and must be
/// updated only after a successful `loadHome()` / `refresh()`.
final class HomeViewModelRefreshTimestampTests: XCTestCase {

    /// Polls a `@MainActor` value up to `timeout` seconds and returns the
    /// first non-nil result. Avoids brittle fixed sleeps when waiting for an
    /// async `Task` to drain.
    @MainActor
    private func waitFor<T>(
        _ expression: @MainActor () -> T?,
        timeout: TimeInterval = 2.0
    ) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = expression() { return value }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return expression()
    }

    @MainActor
    func test_lastSuccessfulRefreshAt_isSet_afterSuccessfulLoad() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "T", items: [])],
            continuation: nil
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        XCTAssertNil(vm.lastSuccessfulRefreshAt)

        let before = Date()
        vm.loadHome()
        let stamp = await waitFor({ vm.lastSuccessfulRefreshAt })

        guard let stamp else {
            return XCTFail("lastSuccessfulRefreshAt should be set after a successful load")
        }
        XCTAssertGreaterThanOrEqual(stamp, before)
    }

    @MainActor
    func test_lastSuccessfulRefreshAt_isUpdated_onRefresh() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "T", items: [])],
            continuation: nil
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        vm.loadHome()
        let firstStamp = await waitFor({ vm.lastSuccessfulRefreshAt })
        guard let firstStamp else {
            return XCTFail("lastSuccessfulRefreshAt missing after initial load")
        }

        // Ensure the second timestamp lands at a strictly later instant.
        try? await Task.sleep(for: .milliseconds(50))
        vm.refresh()
        let secondStamp = await waitFor({
            let current = vm.lastSuccessfulRefreshAt
            return (current.map { $0 > firstStamp } ?? false) ? current : nil
        })

        guard let secondStamp else {
            return XCTFail("lastSuccessfulRefreshAt did not advance after refresh")
        }
        XCTAssertGreaterThan(secondStamp, firstStamp)
    }

    @MainActor
    func test_lastSuccessfulRefreshAt_isNotChanged_onFailedLoad() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: [MusicSection(title: "OK", items: [])],
            continuation: nil
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // Establish a baseline timestamp from a successful load.
        vm.loadHome()
        let baseline = await waitFor({ vm.lastSuccessfulRefreshAt })
        XCTAssertNotNil(baseline)

        // Trigger a refresh that fails on every attempt.
        mock.shouldThrow = true
        vm.refresh()
        // Wait long enough for refresh's failure path to surface an error.
        _ = await waitFor({ vm.error }, timeout: 2.0)

        XCTAssertEqual(
            vm.lastSuccessfulRefreshAt, baseline,
            "Failed refresh must not advance the freshness timestamp"
        )
    }
}
