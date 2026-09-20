import XCTest

@testable import LovelyMusic

/// RED-phase TDD tests for chip-filter pre-fetch loop (chip-prefetch-tester-1).
///
/// Pins two quick wins on `HomeViewModel.selectChip(_:)`:
///   - QW-1: select & deselect paths must mirror `loadHome`'s multi-page pre-fetch
///           loop (`while sections < minInitialSections && pages < maxInitialPages`).
///   - QW-2: response `chips` must be propagated to `vm.chips` so server-truth
///           `isSelected` is honored, but only when non-empty (preserves the user's
///           chip cloud if the server returns no chips).
///
/// Tests 1–4 are designed to FAIL on current code; Tests 5–6 are regression guards
/// that should remain GREEN through the implementer's fix.
@MainActor
final class HomeViewModelChipPrefetchTests: XCTestCase {

    /// Polls a `@MainActor` value until truthy or timeout. Mirrors
    /// `HomeViewModelRefreshTimestampTests.waitFor`.
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

    private func makeSections(_ count: Int, prefix: String = "S") -> [MusicSection] {
        (0..<count).map { MusicSection(title: "\(prefix)\($0)", items: []) }
    }

    // MARK: - Test 1 (RED) — selectChip pre-fetches multi-page until minInitialSections (QW-1)

    func test_selectChip_prefetchesMultiPage_untilMinInitialSections() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: makeSections(3, prefix: "P1_"),
            continuation: "token1"
        )
        mock.homeContinuationResults = [
            HomeResult(sections: makeSections(3, prefix: "P2_"), continuation: "token2"),
            HomeResult(sections: makeSections(3, prefix: "P3_"), continuation: nil),
        ]
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        let chip = HomeChip(
            id: "Workout",
            title: "Tập thể dục",
            params: "EghEbV9XbF...",
            isSelected: false
        )
        vm.selectChip(chip)

        // Expect loop fires until 9 sections (3 pages × 3 sections) accumulated.
        _ = await waitFor({ vm.sections.count >= 8 ? vm.sections.count : nil })

        XCTAssertEqual(
            vm.sections.count, 9,
            "Expected 3 pages × 3 sections = 9. RED: current selectChip is single-shot → 3."
        )
        XCTAssertEqual(mock.browseHomeCallCount, 1, "First page via browseHome(params:)")
        XCTAssertEqual(
            mock.browseHomeContinuationCallCount, 2,
            "Two continuation pages expected. RED: current code makes 0 continuation calls."
        )
        XCTAssertEqual(
            mock.lastBrowseHomeParams, "EghEbV9XbF...",
            "Chip params must be propagated to repository call."
        )
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Test 2 (RED) — selectChip stops at maxInitialPages (3) (QW-1 cap)

    func test_selectChip_stopsAtMaxInitialPages_evenIfMinNotReached() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: makeSections(1, prefix: "P1_"),
            continuation: "token1"
        )
        // 5 entries each with 1 section + non-nil token — loop could run forever
        // without the page cap.
        mock.homeContinuationResults = [
            HomeResult(sections: makeSections(1, prefix: "P2_"), continuation: "token2"),
            HomeResult(sections: makeSections(1, prefix: "P3_"), continuation: "token3"),
            HomeResult(sections: makeSections(1, prefix: "P4_"), continuation: "token4"),
            HomeResult(sections: makeSections(1, prefix: "P5_"), continuation: "token5"),
            HomeResult(sections: makeSections(1, prefix: "P6_"), continuation: "token6"),
        ]
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        let chip = HomeChip(id: "c", title: "C", params: "p", isSelected: false)
        vm.selectChip(chip)

        _ = await waitFor({ vm.isLoading == false ? () : nil })

        XCTAssertEqual(
            vm.sections.count, 3,
            "Capped at 3 pages × 1 section. RED: current selectChip → 1."
        )
        XCTAssertEqual(
            mock.browseHomeContinuationCallCount, 2,
            "Pages 2 and 3 only — page 4 must not fire. RED: current code → 0."
        )
    }

    // MARK: - Test 3 (RED) — deselect path also pre-fetches (QW-1, deselect branch)

    func test_selectChip_deselectPath_alsoPrefetches() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: makeSections(3, prefix: "Sel_"),
            continuation: "token1"
        )
        // Queue covers both the (post-fix) select-path loop AND the deselect-path
        // loop. Each entry has 3 sections, last one has nil continuation to stop
        // the loop cleanly.
        mock.homeContinuationResults = [
            HomeResult(sections: makeSections(3, prefix: "SelP2_"), continuation: nil),
            HomeResult(sections: makeSections(3, prefix: "DeselP2_"), continuation: nil),
        ]
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        let chip = HomeChip(id: "c1", title: "C1", params: "p1", isSelected: false)

        // First call — select.
        vm.selectChip(chip)
        _ = await waitFor({ vm.selectedChipId == chip.id ? () : nil })
        _ = await waitFor({ vm.isLoading == false ? () : nil })

        let countAfterSelect = vm.sections.count

        // Second call — deselect (same chip id).
        vm.selectChip(chip)
        _ = await waitFor({ vm.selectedChipId == nil ? () : nil })
        _ = await waitFor({ vm.isLoading == false ? () : nil })

        XCTAssertNil(vm.selectedChipId, "Deselect must clear selectedChipId.")
        XCTAssertGreaterThanOrEqual(
            vm.sections.count, 6,
            "Deselect loop must pre-fetch ≥ 2 pages. RED: current deselect → 3 sections."
        )
        XCTAssertNil(
            mock.lastBrowseHomeParams,
            "Deselect calls execute() without params (nil)."
        )
        // Sanity: pre-fetch on select was also expected to grow sections, but
        // we don't strictly assert that here — Test 1 covers it.
        _ = countAfterSelect
    }

    // MARK: - Test 4 (RED) — chips synced from response (QW-2)

    func test_selectChip_syncsChipsFromResponse() async {
        let mock = ControllableMockRepository()
        let initialChips = [
            HomeChip(id: "A", title: "A", params: "pA", isSelected: false),
            HomeChip(id: "B", title: "B", params: "pB", isSelected: false),
        ]
        mock.homeResult = HomeResult(
            sections: makeSections(1),
            continuation: nil,
            chips: initialChips
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // Seed chips via initial loadHome.
        vm.loadHome()
        _ = await waitFor({ vm.chips.count == 2 ? () : nil })

        // Now stage a chip-filter response with server-truth `isSelected` plus a new chip.
        mock.homeResult = HomeResult(
            sections: makeSections(1, prefix: "F_"),
            continuation: nil,
            chips: [
                HomeChip(id: "A", title: "A", params: "pA", isSelected: true),
                HomeChip(id: "B", title: "B", params: "pB", isSelected: false),
                HomeChip(id: "C", title: "C", params: "pC", isSelected: false),
            ]
        )

        vm.selectChip(HomeChip(id: "A", title: "A", params: "pA", isSelected: false))
        _ = await waitFor({ vm.isLoading == false ? () : nil })

        XCTAssertEqual(
            vm.chips.count, 3,
            "Chips must be replaced from non-empty response. RED: current code never assigns chips."
        )
        XCTAssertEqual(
            vm.chips.first(where: { $0.id == "A" })?.isSelected, true,
            "Server-truth isSelected must be honored. RED: current vm.chips still has stale [A,B]."
        )
    }

    // MARK: - Test 5 (GREEN regression) — empty response chips do not clobber existing

    func test_selectChip_doesNotClobberChipsOnEmptyResponse() async {
        let mock = ControllableMockRepository()
        let initialChips = [
            HomeChip(id: "A", title: "A", params: "pA", isSelected: false),
            HomeChip(id: "B", title: "B", params: "pB", isSelected: false),
        ]
        mock.homeResult = HomeResult(
            sections: makeSections(1),
            continuation: nil,
            chips: initialChips
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        vm.loadHome()
        _ = await waitFor({ vm.chips.count == 2 ? () : nil })

        // Filter response returns empty chips array (server omitted chips).
        mock.homeResult = HomeResult(
            sections: makeSections(1, prefix: "F_"),
            continuation: nil,
            chips: []
        )

        vm.selectChip(HomeChip(id: "A", title: "A", params: "pA", isSelected: false))
        _ = await waitFor({ vm.isLoading == false ? () : nil })

        XCTAssertEqual(
            vm.chips.count, 2,
            "Empty response chips must not clobber the existing chip cloud (QW-2 guard)."
        )
    }

    // MARK: - Test 6 (GREEN regression) — rapid selectChip calls do not crash / hang

    func test_selectChip_rapidCalls_doNotHang() async {
        let mock = ControllableMockRepository()
        mock.homeResult = HomeResult(
            sections: makeSections(2),
            continuation: "token1"
        )
        mock.homeContinuationResults = [
            HomeResult(sections: makeSections(2), continuation: nil),
            HomeResult(sections: makeSections(2), continuation: nil),
        ]
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        let chipA = HomeChip(id: "A", title: "A", params: "pA", isSelected: false)
        let chipB = HomeChip(id: "B", title: "B", params: "pB", isSelected: false)

        // Two rapid calls — first should be cancelled by the second.
        vm.selectChip(chipA)
        vm.selectChip(chipB)

        let settled = await waitFor({ vm.isLoading == false ? () : nil }, timeout: 3.0)
        XCTAssertNotNil(settled, "Rapid selectChip calls must settle (no hang).")
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Test 7 (remediation HIGH-1) — selectChip cancels in-flight loadMore

    /// Race scenario: user is paginating home (loadMore in flight) and taps a chip.
    /// The stale `loadMoreTask` must be cancelled so its continuation result
    /// cannot append unfiltered sections into the chip-filtered view.
    func test_selectChip_cancelsInFlightLoadMore_doesNotAppendStaleSections() async {
        let mock = ControllableMockRepository()
        // Initial home: 2 sections + a continuation token so loadMore is valid.
        mock.homeResult = HomeResult(
            sections: makeSections(2, prefix: "Home_"),
            continuation: "homeNextToken"
        )
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // Seed initial home content + continuation token.
        vm.loadHome()
        _ = await waitFor({ vm.hasMore ? () : nil })
        XCTAssertTrue(vm.hasMore, "Precondition: continuation token must be set.")

        // Arm the suspending continuation BEFORE triggering loadMore.
        mock.suspendOnContinuation = true
        vm.loadMore()
        // Wait until loadMore has actually entered browseHomeContinuation.
        _ = await waitFor({ mock.continuationContinuation != nil ? () : nil })
        XCTAssertNotNil(
            mock.continuationContinuation,
            "loadMore must be suspended inside browseHomeContinuation."
        )

        // Now stage the chip-filtered response. Disarm suspension so the new
        // chip's task does not also suspend on its own pre-fetch (use a single-
        // page result with nil continuation).
        mock.suspendOnContinuation = false
        mock.homeResult = HomeResult(
            sections: makeSections(3, prefix: "Chip_"),
            continuation: nil
        )

        // Trigger the chip selection. This must cancel the in-flight loadMoreTask.
        let chip = HomeChip(id: "Workout", title: "W", params: "pW", isSelected: false)
        vm.selectChip(chip)
        _ = await waitFor({ vm.selectedChipId == chip.id ? () : nil })
        _ = await waitFor({ vm.isLoading == false ? () : nil })

        // Sanity: chip-filter committed.
        XCTAssertEqual(vm.selectedChipId, chip.id)
        XCTAssertTrue(
            vm.sections.allSatisfy { $0.title.hasPrefix("Chip_") },
            "Sections must contain only chip-filtered content after select."
        )
        let chipSectionCount = vm.sections.count

        // Resume the stale loadMore continuation with an "unfiltered" page.
        // The task is cancelled, so the post-await guard inside `loadMore`
        // must short-circuit; sections must remain unchanged.
        mock.continuationContinuation?.resume(
            returning: HomeResult(
                sections: makeSections(4, prefix: "Stale_"),
                continuation: "staleNext"
            )
        )
        mock.continuationContinuation = nil

        // Give the resumed continuation time to attempt a state mutation.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            vm.sections.count, chipSectionCount,
            "Stale loadMore continuation must NOT append into chip view."
        )
        XCTAssertFalse(
            vm.sections.contains(where: { $0.title.hasPrefix("Stale_") }),
            "No stale sections may leak into the chip-filtered view."
        )
        XCTAssertFalse(vm.isLoadingMore, "isLoadingMore must be reset.")
    }

    // MARK: - Test 8 (MED-3 fix) — cancelled superseded task's defer must not clear isLoading

    /// Race scenario: rapid `selectChip(A)` → `selectChip(B)`. Task A's network
    /// response returns AFTER B has started loading. A's post-await
    /// `guard !Task.isCancelled` short-circuits, but the original
    /// `defer { isLoading = false }` would still fire — incorrectly clearing
    /// the spinner while Task B is still loading. The fix gates the defer on
    /// `!Task.isCancelled`. This pins that behavior.
    func test_selectChip_cancelledTaskDefer_doesNotClearIsLoading_whileSupersedingTaskInFlight()
        async
    {
        let mock = ControllableMockRepository()
        // Arm `browseHome(params:)` to suspend so Task A can be pinned mid-flight.
        mock.suspendOnHome = true
        let vm = HomeViewModel(browseHomeUseCase: BrowseHomeUseCase(repository: mock))

        // Trigger Task A — it will enter browseHome and suspend on the
        // CheckedContinuation. Capture A's continuation, then clear the slot
        // so B's later call can install its own without stomping ours.
        let chipA = HomeChip(id: "A", title: "A", params: "pA", isSelected: false)
        vm.selectChip(chipA)
        _ = await waitFor({ mock.homeContinuation != nil ? () : nil })
        let aContinuation = mock.homeContinuation
        XCTAssertNotNil(aContinuation, "Precondition: Task A must be suspended in browseHome.")
        mock.homeContinuation = nil

        // Trigger Task B — cancels A's task. B enters browseHome and suspends
        // on a fresh continuation (kept suspended for the duration of the test
        // so isLoading is still expected to be true on B's behalf).
        let chipB = HomeChip(id: "B", title: "B", params: "pB", isSelected: false)
        vm.selectChip(chipB)
        _ = await waitFor({ mock.homeContinuation != nil ? () : nil })
        XCTAssertNotNil(mock.homeContinuation, "Task B must be suspended in browseHome.")
        XCTAssertTrue(vm.isLoading, "Precondition: B is in flight, spinner should be on.")

        // Resume A's continuation. A wakes up, hits `guard !Task.isCancelled`,
        // returns. The defer fires. With the MED-3 fix, the defer must NOT
        // clear `isLoading` because A is cancelled and B is still loading.
        aContinuation?.resume(
            returning: HomeResult(sections: makeSections(1, prefix: "A_"), continuation: nil)
        )

        // Give A's defer time to run on the MainActor.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(
            vm.isLoading,
            "Cancelled Task A's defer must not clear isLoading while B is in flight."
        )

        // Cleanup: resume B so the test exits cleanly.
        let bContinuation = mock.homeContinuation
        mock.homeContinuation = nil
        // Disarm suspension before resume so any internal pre-fetch loop in B
        // does not re-suspend on subsequent calls.
        mock.suspendOnHome = false
        bContinuation?.resume(
            returning: HomeResult(sections: makeSections(1, prefix: "B_"), continuation: nil)
        )
        _ = await waitFor({ vm.isLoading == false ? () : nil })
        XCTAssertFalse(vm.isLoading, "After B settles, spinner clears normally.")
    }
}
