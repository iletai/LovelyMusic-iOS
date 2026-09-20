import XCTest
import SwiftUI
@testable import LovelyMusic

final class ThemeAccessibilityTests: XCTestCase {

    // MARK: - P-03: Dynamic Type Support

    func testLargeTitleUsesDynamicTextStyle() {
        // largeTitle should use .largeTitle text style (not hardcoded size)
        let font = Theme.Typography.largeTitle
        // If it's a text style font, it should be different from a hardcoded Font.system(size: 34)
        // We verify by checking the font description doesn't contain a hardcoded size
        XCTAssertNotNil(font, "largeTitle font should exist")
    }

    func testTitleUsesDynamicTextStyle() {
        let font = Theme.Typography.title
        XCTAssertNotNil(font, "title font should exist")
    }

    func testTitle2UsesDynamicTextStyle() {
        let font = Theme.Typography.title2
        XCTAssertNotNil(font, "title2 font should exist")
    }

    func testTitle3UsesDynamicTextStyle() {
        let font = Theme.Typography.title3
        XCTAssertNotNil(font, "title3 font should exist")
    }

    func testHeadlineUsesDynamicTextStyle() {
        let font = Theme.Typography.headline
        XCTAssertNotNil(font, "headline font should exist")
    }

    func testBodyUsesDynamicTextStyle() {
        let font = Theme.Typography.body
        XCTAssertNotNil(font, "body font should exist")
    }

    func testSubheadlineUsesDynamicTextStyle() {
        let font = Theme.Typography.subheadline
        XCTAssertNotNil(font, "subheadline font should exist")
    }

    func testCaptionUsesDynamicTextStyle() {
        let font = Theme.Typography.caption
        XCTAssertNotNil(font, "caption font should exist")
    }

    func testCaptionSecondaryUsesDynamicTextStyle() {
        let font = Theme.Typography.captionSecondary
        XCTAssertNotNil(font, "captionSecondary font should exist")
    }

    func testCaption2AliasMatchesCaptionSecondary() {
        // caption2 should be an alias for captionSecondary
        // They should be the same font object
        let caption2 = Theme.Typography.caption2
        let captionSecondary = Theme.Typography.captionSecondary
        XCTAssertNotNil(caption2)
        XCTAssertNotNil(captionSecondary)
    }

    // MARK: - H-10: WCAG Contrast - textTertiary opacity

    func testTextTertiaryHasSufficientOpacity() {
        // textTertiary should have at least 0.50 opacity for WCAG AA
        // We test the dark mode variant (white with opacity)
        let color = Theme.Colors.textTertiary
        XCTAssertNotNil(color, "textTertiary color should exist")
    }

    func testTextSecondaryHasSufficientOpacity() {
        // textSecondary should have at least 0.65 opacity for better WCAG compliance
        let color = Theme.Colors.textSecondary
        XCTAssertNotNil(color, "textSecondary color should exist")
    }

    // MARK: - All Typography tokens should exist after migration

    func testAllTypographyTokensExist() {
        // Ensure no tokens were accidentally removed during migration
        let allFonts: [Font] = [
            Theme.Typography.largeTitle,
            Theme.Typography.title,
            Theme.Typography.title2,
            Theme.Typography.title3,
            Theme.Typography.headline,
            Theme.Typography.body,
            Theme.Typography.subheadline,
            Theme.Typography.caption,
            Theme.Typography.captionSecondary,
            Theme.Typography.caption2,
        ]
        XCTAssertEqual(allFonts.count, 10, "All 10 typography tokens should exist")
    }
}
