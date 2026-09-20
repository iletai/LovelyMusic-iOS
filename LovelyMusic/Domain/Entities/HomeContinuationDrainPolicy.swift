import Foundation

/// Controls how aggressively the Home screen pre-fetches continuation pages
/// after the initial browse response. When `isEnabled` is `false`, the
/// existing mini-drain (`minInitialSections` / `maxInitialPages`) takes over.
struct HomeContinuationDrainPolicy {
    /// Maximum number of continuation pages to fetch.
    let maxPages: Int
    /// Wall-clock budget; drain stops when elapsed time exceeds this.
    let maxDuration: TimeInterval
    /// Master switch — gated by the `homeContinuationDrainEnabled` feature flag.
    let isEnabled: Bool

    static let `default` = HomeContinuationDrainPolicy(
        maxPages: 10,
        maxDuration: 4.0,
        isEnabled: false
    )
}
