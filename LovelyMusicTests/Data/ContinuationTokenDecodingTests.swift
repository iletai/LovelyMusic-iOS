import XCTest

@testable import LovelyMusic

/// TDD red-phase suite for S4 — continuation-token shape migration.
///
/// Round-1 audit: `doc/analysis/2026-05-03-home-content-audit/architecture-mapping-audit.md`
/// §gap-5 flagged that only the legacy `nextContinuationData.continuation`
/// path is decoded today (`SharedRenderers.swift#L94-L107`). YouTube has
/// migrated several endpoints (Search done, Home pending) to a new
/// `continuationItemRenderer.continuationEndpoint.continuationCommand.token`
/// shape. ExecPlan §Phase 1 task 1.1 (Q5 = additive Codable, legacy
/// fallback) pins the contract these tests enforce.
///
/// Precedence rule (pinned by `testContinuation_bothEnvelopesPresent_prefersModern`):
/// when both shapes are present in the same response, the MODERN shape
/// MUST win, because it represents the migration direction. The legacy
/// shape is the *fallback* for endpoints that have not yet migrated.
///
/// Expected red/green at TDD red-phase commit:
/// - Test 1 (legacy)        → GREEN  (existing baseline)
/// - Test 2 (modern)        → RED    (no `continuationCommand` Codable yet)
/// - Test 3 (both → modern) → RED    (precedence not yet enforced)
/// - Test 4 (neither → nil) → GREEN  (existing optional decode)
/// - Test 5 (e2e modern)    → RED    (mapHomeContinuation reads only
///                                    legacy via `Continuation.token`)
///
/// API surface used end-to-end: `BrowseResponseMapper.mapHomeContinuation`
/// already returns `HomeResult(sections, continuation:)`, so test 5 does
/// NOT pin a new public method — it only widens the existing
/// `continuation` field's source-of-truth. See test 5 docstring for the
/// full justification.
final class ContinuationTokenDecodingTests: XCTestCase {

    // MARK: - Helpers

    private func decodeContinuation(_ fixtureName: String) throws -> Continuation {
        let data = try FixtureLoader.loadJSON(
            fixtureName,
            subdirectory: "Fixtures/Continuations"
        )
        return try JSONDecoder().decode(Continuation.self, from: data)
    }

    // MARK: - Test 1 — legacy envelope (GREEN baseline)

    func testContinuation_legacyEnvelope_extractsToken() throws {
        let continuation = try decodeContinuation("continuation_legacy")

        XCTAssertEqual(
            continuation.token, "TOKEN_LEGACY",
            "Legacy `nextContinuationData.continuation` must remain decodable as the existing fallback path; round-1 audit confirms current production reads this shape."
        )
    }

    // MARK: - Test 2 — modern envelope (RED)

    func testContinuation_modernEnvelope_extractsToken() throws {
        let continuation = try decodeContinuation("continuation_modern")

        XCTAssertEqual(
            continuation.token, "TOKEN_MODERN",
            "Modern `continuationCommand.token` must decode and surface via `Continuation.token`. ExecPlan §Phase 1 task 1.2 will land additive Codable + accessor preferring the new shape."
        )
    }

    // MARK: - Test 3 — both shapes present, modern wins (RED)

    /// Pins the precedence rule so the implementer doesn't get to pick.
    /// When YouTube serves both shapes during migration, the modern
    /// `continuationCommand.token` MUST win. Legacy is fallback only —
    /// applied when modern is absent. ExecPlan Q5 confirms this direction.
    func testContinuation_bothEnvelopesPresent_prefersModern() throws {
        let continuation = try decodeContinuation("continuation_both")

        XCTAssertEqual(
            continuation.token, "NEW",
            "Precedence: modern `continuationCommand.token` MUST take precedence over legacy `nextContinuationData.continuation` when both are present. This represents the YouTube migration direction; legacy is a fallback, not an override."
        )
    }

    // MARK: - Test 4 — neither shape present (GREEN sanity)

    func testContinuation_neitherEnvelope_returnsNil() throws {
        let json = Data("{}".utf8)

        let continuation = try JSONDecoder().decode(Continuation.self, from: json)

        XCTAssertNil(
            continuation.token,
            "An empty continuation object signals 'no more pages'; `Continuation.token` must be nil rather than throwing or returning an empty string."
        )
    }

    // MARK: - Test 5 — modern envelope end-to-end via mapHomeContinuation (RED)

    /// Closes the loop end-to-end. Loads a full `BrowseResponse`-shaped
    /// fixture (modeled after `chip_filter_continuation_envelope.json`)
    /// where the next-page token lives in `sectionListContinuation.continuations[0].continuationCommand.token`
    /// instead of legacy `nextContinuationData.continuation`.
    ///
    /// API contract used (PRE-EXISTING — no new public method pinned):
    /// `BrowseResponseMapper.mapHomeContinuation(_ data:) -> HomeResult`,
    /// where `HomeResult.continuation: String?` is the next-page token.
    /// See `LovelyMusic/Domain/Entities/HomeResult.swift` and
    /// `BrowseResponseMapper.swift` L833-L843.
    ///
    /// What this test pins: `mapHomeContinuation` must return BOTH the
    /// 2 carousel sections AND surface `"TOKEN_MODERN"` from the modern
    /// envelope. Today it returns sections fine but `continuation = nil`
    /// because `Continuation.token` only reads legacy.
    func testContinuation_modernEnvelope_inHomeBrowseResponse_endToEnd() throws {
        let data = try FixtureLoader.loadJSON(
            "home_modern_continuation_envelope",
            subdirectory: "Fixtures/Continuations"
        )

        let result = try BrowseResponseMapper.mapHomeContinuation(data)

        XCTAssertEqual(
            result.sections.count, 2,
            "Section decode must remain working — two carousel shelves under continuationContents.sectionListContinuation.contents[]."
        )
        XCTAssertEqual(
            result.sections.first?.title, "Modern continuation A",
            "Sanity: first carousel title preserved after additive continuation Codable lands."
        )
        XCTAssertEqual(
            result.continuation, "TOKEN_MODERN",
            "End-to-end: HomeResult.continuation MUST surface the modern `continuationCommand.token`. Today this is nil because Continuation.token only reads legacy nextContinuationData. ExecPlan §Phase 1 task 1.2 lands the fix."
        )
    }
}
