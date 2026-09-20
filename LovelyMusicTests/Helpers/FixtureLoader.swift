import Foundation
import XCTest

/// Lightweight loader for JSON fixtures bundled with the test target.
///
/// Fixtures live under `LovelyMusicTests/Resources/Fixtures/` and are
/// copied into the unit-test bundle by XcodeGen. Resolution falls back
/// to the on-disk repo path so tests work even before the bundle copy
/// phase is regenerated (e.g., immediately after adding a new file).
enum FixtureLoader {
    /// Loads a JSON fixture as raw `Data`.
    /// - Parameters:
    ///   - name: file name without extension (e.g. `"quick_picks_multirow"`)
    ///   - subdirectory: subdirectory under `Resources/Fixtures/`
    ///   - file: caller's `#filePath` — used for the disk fallback.
    static func loadJSON(
        _ name: String,
        subdirectory: String = "Fixtures/HomeRenderers",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: BundleTokenClass.self)

        // 1) Bundle resource path (post xcodegen + build)
        if let url = bundle.url(
            forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
        {
            return try Data(contentsOf: url)
        }

        // 2) Disk fallback: derive the repo path from this file's location so
        //    tests don't depend on the resource copy phase succeeding before
        //    the fixture is checked in. Walks up to the repo root.
        let thisFile = URL(fileURLWithPath: String(describing: file))
        // .../LovelyMusicTests/Helpers/FixtureLoader.swift -> .../LovelyMusicTests
        let testsRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let diskURL =
            testsRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent(subdirectory)
            .appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: diskURL.path) {
            return try Data(contentsOf: diskURL)
        }

        XCTFail(
            "Fixture not found: \(subdirectory)/\(name).json (looked in bundle and at \(diskURL.path))",
            file: file,
            line: line
        )
        throw CocoaError(.fileReadNoSuchFile)
    }
}

private final class BundleTokenClass {}
