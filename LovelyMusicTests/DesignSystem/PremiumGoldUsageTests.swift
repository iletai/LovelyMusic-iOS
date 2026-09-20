import XCTest

/// Q2 regression guard — ensures premium gold tokens stay scoped to the
/// Paywall surface. See `doc/design/2026-05-01-light-mode-redesign-round-2/DESIGN.md` §6.8
/// and `doc/review/2026-05-01-light-mode-redesign-round-2/review-merged.md` §8.
///
/// Allowed call-sites for `premiumGold`, `premiumOrange`, `premiumGradient` outside
/// `LovelyMusic/DesignSystem/`:
///   - `LovelyMusic/Presentation/Premium/**` (paywall surface itself).
///
/// All other Presentation files MUST consume the gated `PremiumBadgeView` API
/// (`.brand` default, `.paywall` opt-in) instead of referencing the raw tokens.
final class PremiumGoldUsageTests: XCTestCase {

    private static let bannedTokens = ["premiumGold", "premiumOrange", "premiumGradient"]
    private static let allowedSubpath = "/LovelyMusic/Presentation/Premium/"

    func testNoPremiumTokenLeaksOutsidePremiumSurface() throws {
        let presentationDir = try presentationDirectoryURL()

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: presentationDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            XCTFail("Could not enumerate \(presentationDir.path)")
            return
        }

        var leaks: [String] = []
        var scannedFileCount = 0

        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            // Allow files inside the paywall surface.
            if url.path.contains(Self.allowedSubpath) { continue }

            scannedFileCount += 1
            let contents: String
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch {
                XCTFail("Failed to read \(url.path): \(error)")
                continue
            }

            let lines = contents.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                for token in Self.bannedTokens where line.contains(token) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    leaks.append("\(url.lastPathComponent):\(idx + 1): \(token) — \(trimmed)")
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFileCount, 0,
            "Guard scanned 0 files; path resolution likely broken at \(presentationDir.path)")

        XCTAssertTrue(
            leaks.isEmpty,
            """
            Premium gold tokens leaked outside `LovelyMusic/Presentation/Premium/`.
            Use `PremiumBadgeView()` (default `.brand` style) instead, or the gated
            `.paywall` style only for paywall hero/CTA surfaces.

            Offending references:
            \(leaks.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Path resolution

    /// Resolves `<repo>/LovelyMusic/Presentation/` from this test file's
    /// build-time path (`#filePath`).
    ///
    /// File layout:
    /// `<repo>/LovelyMusicTests/DesignSystem/PremiumGoldUsageTests.swift`
    /// → repo root = parent⁴
    private func presentationDirectoryURL(file: StaticString = #filePath) throws -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let repoRoot =
            thisFile
            .deletingLastPathComponent()  // DesignSystem
            .deletingLastPathComponent()  // LovelyMusicTests
            .deletingLastPathComponent()  // <repo>

        let presentationDir =
            repoRoot
            .appendingPathComponent("LovelyMusic")
            .appendingPathComponent("Presentation")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: presentationDir.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            throw XCTSkip(
                """
                Presentation directory not reachable from test runtime — \
                expected at \(presentationDir.path). \
                This guard relies on `#filePath` resolving to the source tree; \
                if running from a relocated test bundle, run the equivalent grep \
                manually: \
                `grep -RIn 'premiumGold|premiumOrange|premiumGradient' LovelyMusic/Presentation/ \
                | grep -v '/Presentation/Premium/'`
                """
            )
        }
        return presentationDir
    }
}
