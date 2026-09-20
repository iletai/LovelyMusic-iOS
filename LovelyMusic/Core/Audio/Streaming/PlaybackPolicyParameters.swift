import Foundation

enum PlaybackPolicyParameters {
    static let sharedTransientBytes: Int64 = 200 * 1024 * 1024
    static let speculativePreloadCeilingBytes: Int64 = 512 * 1024
    static let byteBudgetOverhead = 0.10
    static let coreSeekToleranceSeconds: TimeInterval = 0.750
    static let decodedEvidenceSeconds: TimeInterval = 0.500
    static let decodedEvidenceMinimumBuffers = 3
    static let legacyRemuxNoProgressDeadlineSeconds: TimeInterval = 15

    static func forwardBufferSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained:
            return 15
        case .cellular:
            return 8
        case .constrained:
            return 5
        case .offline:
            return 0
        }
    }

    static func resolverNoProgressDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval? {
        switch networkClass {
        case .wifiUnconstrained, .cellular, .constrained, .offline:
            return nil
        }
    }

    static func resolverAbsoluteDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained, .cellular, .constrained:
            return 30
        case .offline:
            return 0
        }
    }

    static func rangePrepareSeekNoProgressDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        rangeNoProgressDeadlineSeconds(for: networkClass)
    }

    static func rangePrepareSeekAbsoluteDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained, .cellular, .constrained:
            return 30
        case .offline:
            return 0
        }
    }

    static func activeRangeNoProgressDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        rangeNoProgressDeadlineSeconds(for: networkClass)
    }

    static func activeRangeAbsoluteDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval? {
        switch networkClass {
        case .wifiUnconstrained, .cellular, .constrained, .offline:
            return nil
        }
    }

    static func seekVerificationAbsoluteDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained:
            return 5
        case .cellular, .constrained:
            return 8
        case .offline:
            return 0
        }
    }

    static func legacyFullDownloadNoProgressDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained, .cellular, .constrained:
            return 15
        case .offline:
            return 0
        }
    }

    static func legacyFullDownloadAbsoluteDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained:
            return 300
        case .cellular, .constrained:
            return 600
        case .offline:
            return 0
        }
    }

    static func legacyRemuxAbsoluteDeadlineSeconds(
        trackDurationSeconds: TimeInterval
    ) -> TimeInterval {
        guard trackDurationSeconds.isFinite, trackDurationSeconds >= 0 else {
            return 30
        }
        return min(max(30, trackDurationSeconds / 2), 300)
    }

    private static func rangeNoProgressDeadlineSeconds(
        for networkClass: PlaybackNetworkClass
    ) -> TimeInterval {
        switch networkClass {
        case .wifiUnconstrained:
            return 10
        case .cellular, .constrained:
            return 15
        case .offline:
            return 0
        }
    }
}
