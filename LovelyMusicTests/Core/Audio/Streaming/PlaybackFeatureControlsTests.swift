import Foundation
import os
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackFeatureControlsTests: XCTestCase {
    func testMissingRangeFieldsFailClosed() throws {
        let manager = try makeFlags(jsonObject: [:])

        XCTAssertFalse(manager.playbackControls.rangeStreamingV1)
        XCTAssertEqual(manager.playbackControls.cohortPercent, 0)
        XCTAssertFalse(manager.playbackControls.boundedPreloadV1)
        XCTAssertTrue(manager.playbackControls.killSwitch)
        XCTAssertEqual(manager.playbackControls.killSwitchEpoch, 0)
        XCTAssertEqual(manager.playbackControls.loaderVersion, 0)
        XCTAssertEqual(manager.playbackControls.headerSchemaVersion, 0)
    }

    func testEveryMissingRangeFieldFailsWholeControlGroupClosed() throws {
        for key in validRangeFields.keys {
            var fields = validRangeFields
            fields.removeValue(forKey: key)

            let controls = try makeFlags(jsonObject: fields).playbackControls

            XCTAssertEqual(
                controls,
                .failClosed,
                "Missing remote control field must reject the complete range configuration"
            )
        }
    }

    func testEveryMalformedRangeFieldFailsWholeControlGroupClosed() throws {
        for key in validRangeFields.keys {
            var fields = validRangeFields
            fields[key] = "malformed"

            let controls = try makeFlags(jsonObject: fields).playbackControls

            XCTAssertEqual(
                controls,
                .failClosed,
                "Malformed remote control field must reject the complete range configuration"
            )
        }
    }

    func testValidRangeFieldsProduceOneCompleteSnapshot() throws {
        let manager = try makeFlags(jsonObject: validRangeFields)
        let controls = manager.playbackControls

        XCTAssertEqual(
            controls,
            PlaybackFeatureSnapshot(
                rangeStreamingV1: true,
                cohortPercent: 37,
                boundedPreloadV1: true,
                killSwitch: false,
                killSwitchEpoch: 9,
                loaderVersion: 1,
                headerSchemaVersion: 1
            )
        )
        XCTAssertEqual(manager.playbackSnapshotStore.snapshot(), controls)
    }

    func testCohortPercentIsClampedToClosedRange() throws {
        var below = validRangeFields
        below["range_streaming_cohort_percent"] = -10
        var above = validRangeFields
        above["range_streaming_cohort_percent"] = 140

        XCTAssertEqual(try makeFlags(jsonObject: below).playbackControls.cohortPercent, 0)
        XCTAssertEqual(try makeFlags(jsonObject: above).playbackControls.cohortPercent, 100)
    }

    func testInvalidLoaderOrHeaderVersionFailsClosed() throws {
        for key in ["range_loader_policy_version", "range_header_schema_version"] {
            var fields = validRangeFields
            fields[key] = 0

            XCTAssertEqual(try makeFlags(jsonObject: fields).playbackControls, .failClosed)
        }
    }

    func testUnsupportedPositiveLoaderAndHeaderVersionsAreIneligible() throws {
        for key in ["range_loader_policy_version", "range_header_schema_version"] {
            var fields = validRangeFields
            fields[key] = 2
            let controls = try makeFlags(jsonObject: fields).playbackControls

            XCTAssertFalse(controls.hasSupportedSchema)
            XCTAssertFalse(
                PlaybackCohortAssigner(
                    idStore: PlaybackInstallIDStoreStub(
                        readResult: .success(Data(repeating: 0x71, count: 32))
                    )
                ).isEligible(for: controls)
            )
        }
    }

    func testManagerPublishesFailClosedDefaultAndMalformedSnapshotsToAtomicStore() throws {
        let defaultManager = try makeFlagsWithoutCachedConfig()
        var malformed = validRangeFields
        malformed["range_streaming_v1"] = "true"
        let malformedManager = try makeFlags(jsonObject: malformed)

        XCTAssertEqual(defaultManager.playbackControls, .failClosed)
        XCTAssertEqual(defaultManager.playbackSnapshotStore.snapshot(), .failClosed)
        XCTAssertEqual(malformedManager.playbackControls, .failClosed)
        XCTAssertEqual(malformedManager.playbackSnapshotStore.snapshot(), .failClosed)
    }

    func testEnabledCachedSnapshotTransitionsFailClosedForEveryMissingOrMalformedRemoteField()
        throws
    {
        for key in validRangeFields.keys {
            for replacement in [RemoteFieldMutation.missing, .malformed] {
                let manager = try makeFlags(jsonObject: validRangeFields)
                XCTAssertTrue(manager.playbackControls.rangeStreamingV1)

                var remote = validRangeFields
                switch replacement {
                case .missing:
                    remote.removeValue(forKey: key)
                case .malformed:
                    remote[key] = "malformed"
                }
                let data = try JSONSerialization.data(withJSONObject: remote)

                manager.applyRemoteConfigData(data)

                XCTAssertEqual(manager.playbackControls, .failClosed)
                XCTAssertEqual(manager.playbackSnapshotStore.snapshot(), .failClosed)
            }
        }
    }

    func testMalformedRemoteInvalidatesEnabledCacheAcrossRelaunch() throws {
        let suiteName = "PlaybackFeatureControlsTests.Relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            try JSONSerialization.data(withJSONObject: validRangeFields),
            forKey: "feature_flags_cache"
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let enabled = FeatureFlagManager(
            configURLString: "https://invalid.example.test/config",
            apiKey: nil,
            defaults: defaults
        )
        XCTAssertTrue(enabled.playbackControls.rangeStreamingV1)
        var malformed = validRangeFields
        malformed["range_header_schema_version"] = "malformed"

        enabled.applyRemoteConfigData(
            try JSONSerialization.data(withJSONObject: malformed)
        )
        let relaunched = FeatureFlagManager(
            configURLString: "https://invalid.example.test/config",
            apiKey: nil,
            defaults: defaults
        )

        XCTAssertEqual(enabled.playbackControls, .failClosed)
        XCTAssertEqual(relaunched.playbackControls, .failClosed)
    }

    nonisolated func testSnapshotStoreNeverExposesTornControlsDuringConcurrentUpdates() {
        let first = PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 25,
            boundedPreloadV1: false,
            killSwitch: false,
            killSwitchEpoch: 10,
            loaderVersion: 1,
            headerSchemaVersion: 1
        )
        let second = PlaybackFeatureSnapshot(
            rangeStreamingV1: false,
            cohortPercent: 75,
            boundedPreloadV1: true,
            killSwitch: true,
            killSwitchEpoch: 20,
            loaderVersion: 2,
            headerSchemaVersion: 2
        )
        let store = PlaybackFeatureSnapshotStore(initial: first)
        let violation = OSAllocatedUnfairLock(initialState: false)

        DispatchQueue.concurrentPerform(iterations: 4_000) { index in
            if index.isMultiple(of: 3) {
                store.update(index.isMultiple(of: 2) ? first : second)
            } else {
                let snapshot = store.snapshot()
                if snapshot != first && snapshot != second {
                    violation.withLock { $0 = true }
                }
            }
        }

        XCTAssertFalse(violation.withLock { $0 })
    }

    nonisolated func testZeroPercentSelectsNobodyWithoutReadingInstallID() {
        let store = PlaybackInstallIDStoreStub(readResult: .failure(.readFailed))
        let assigner = PlaybackCohortAssigner(idStore: store)

        XCTAssertFalse(assigner.isEligible(for: enabledControls(percent: 0)))
        XCTAssertEqual(store.readCount, 0)
    }

    nonisolated func testHundredPercentSelectsEveryValidInstallID() {
        let store = PlaybackInstallIDStoreStub(
            readResult: .success(Data(repeating: 0xA5, count: 32))
        )
        let assigner = PlaybackCohortAssigner(idStore: store)

        XCTAssertTrue(assigner.isEligible(for: enabledControls(percent: 100)))
        XCTAssertEqual(store.readCount, 1)
    }

    nonisolated func testHundredPercentStillRejectsMissingMalformedAndUnreadableInstallIDs() {
        let readFailure = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(readResult: .failure(.readFailed))
        )
        let malformed = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(readResult: .success(Data([0x01])))
        )
        let missingAndCannotGenerate = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(readResult: .success(nil)),
            generateID: { throw PlaybackInstallIDStoreStub.Failure.generationFailed }
        )

        XCTAssertFalse(readFailure.isEligible(for: enabledControls(percent: 100)))
        XCTAssertFalse(malformed.isEligible(for: enabledControls(percent: 100)))
        XCTAssertFalse(missingAndCannotGenerate.isEligible(for: enabledControls(percent: 100)))
    }

    nonisolated func testCohortUsesExactTenThousandBucketBoundary() {
        let store = PlaybackInstallIDStoreStub(
            readResult: .success(Data(repeating: 0xBC, count: 32))
        )
        let included = PlaybackCohortAssigner(idStore: store) { _, _ in 4_999 }
        let excluded = PlaybackCohortAssigner(idStore: store) { _, _ in 5_000 }

        XCTAssertTrue(included.isEligible(for: enabledControls(percent: 50)))
        XCTAssertFalse(excluded.isEligible(for: enabledControls(percent: 50)))
    }

    nonisolated func testCohortAssignmentIsStableAcrossRelaunches() {
        let persisted = PlaybackInstallIDStoreStub(readResult: .success(nil))
        let first = PlaybackCohortAssigner(
            idStore: persisted,
            generateID: { Data(repeating: 0x11, count: 32) }
        )
        let firstBucket = first.bucket(policyVersion: 1)
        let second = PlaybackCohortAssigner(
            idStore: persisted,
            generateID: { Data(repeating: 0x22, count: 32) }
        )

        XCTAssertNotNil(firstBucket)
        XCTAssertEqual(second.bucket(policyVersion: 1), firstBucket)
        XCTAssertEqual(persisted.writeCount, 1)
    }

    nonisolated func testCohortWideningCannotEjectPreviouslyEligibleBucket() {
        let store = PlaybackInstallIDStoreStub(
            readResult: .success(Data(repeating: 0x37, count: 32))
        )
        let assigner = PlaybackCohortAssigner(idStore: store) { _, _ in 2_499 }

        XCTAssertTrue(assigner.isEligible(for: enabledControls(percent: 25)))
        XCTAssertTrue(assigner.isEligible(for: enabledControls(percent: 75)))
    }

    nonisolated func testCohortFailsClosedForReadWriteGenerationAndPolicyFailures() {
        let readFailure = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(readResult: .failure(.readFailed))
        )
        let writeFailure = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(
                readResult: .success(nil),
                writeResult: .failure(.writeFailed)
            ),
            generateID: { Data(repeating: 0x41, count: 32) }
        )
        let generationFailure = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(readResult: .success(nil)),
            generateID: { throw PlaybackInstallIDStoreStub.Failure.generationFailed }
        )
        let policyMismatch = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(
                readResult: .success(Data(repeating: 0x51, count: 32))
            )
        )
        let headerMismatch = PlaybackCohortAssigner(
            idStore: PlaybackInstallIDStoreStub(
                readResult: .success(Data(repeating: 0x61, count: 32))
            )
        )

        XCTAssertFalse(readFailure.isEligible(for: enabledControls(percent: 50)))
        XCTAssertFalse(writeFailure.isEligible(for: enabledControls(percent: 50)))
        XCTAssertFalse(generationFailure.isEligible(for: enabledControls(percent: 50)))
        XCTAssertFalse(
            policyMismatch.isEligible(
                for: PlaybackFeatureSnapshot(
                    rangeStreamingV1: true,
                    cohortPercent: 50,
                    boundedPreloadV1: false,
                    killSwitch: false,
                    killSwitchEpoch: 1,
                    loaderVersion: 2,
                    headerSchemaVersion: 1
                )
            )
        )
        XCTAssertFalse(
            headerMismatch.isEligible(
                for: PlaybackFeatureSnapshot(
                    rangeStreamingV1: true,
                    cohortPercent: 50,
                    boundedPreloadV1: false,
                    killSwitch: false,
                    killSwitchEpoch: 1,
                    loaderVersion: 1,
                    headerSchemaVersion: 2
                )
            )
        )
    }

    nonisolated func testHashIsDomainSeparatedByPolicyVersion() {
        let store = PlaybackInstallIDStoreStub(
            readResult: .success(Data(repeating: 0x7A, count: 32))
        )
        let assigner = PlaybackCohortAssigner(idStore: store)

        XCTAssertNotEqual(assigner.bucket(policyVersion: 1), assigner.bucket(policyVersion: 2))
    }

    nonisolated func testInstallIDNeverAppearsInSnapshotOrDescriptions() {
        let sensitiveID = Data("raw-install-id-must-stay-private".utf8)
        let paddedID = sensitiveID + Data(repeating: 0, count: 32 - sensitiveID.count)
        let store = PlaybackInstallIDStoreStub(readResult: .success(paddedID))
        let assigner = PlaybackCohortAssigner(idStore: store)
        _ = assigner.bucket(policyVersion: 1)

        let exportedText = String(describing: enabledControls(percent: 50))
            + String(describing: assigner)
        XCTAssertFalse(exportedText.contains("raw-install-id-must-stay-private"))
    }

    func testInstallIDPathHasNoLoggingOrRawIdentifierErrorExport() throws {
        let source = try sourceText(
            relativePath: "LovelyMusic/Core/Audio/Streaming/PlaybackFeatureControls.swift"
        )

        XCTAssertFalse(source.contains("Log."))
        XCTAssertFalse(source.contains("Logger("))
        XCTAssertFalse(source.contains("print("))
        XCTAssertFalse(source.contains("localizedDescription"))
    }

    nonisolated func testCapabilityKeyExcludesPerResourceIdentity() throws {
        let environment = PlaybackCapabilityEnvironment(
            appBuild: "42",
            iOSBuild: "23A123",
            deviceFamily: "iPhone"
        )
        let controls = enabledControls(percent: 100)
        let first = makeDescriptor(
            videoID: "private-video-a",
            url: "https://r1.example.test/a?expire=1",
            contentLength: 2_000
        )
        let second = makeDescriptor(
            videoID: "private-video-b",
            url: "https://r2.example.test/b?expire=2",
            contentLength: 9_000
        )

        let firstKey = StreamDescriptorResolver.capabilityKey(
            for: first,
            environment: environment,
            containerLayoutProfile: "fmp4-indexed-v1",
            qualityTier: .medium,
            controls: controls
        )
        let secondKey = StreamDescriptorResolver.capabilityKey(
            for: second,
            environment: environment,
            containerLayoutProfile: "fmp4-indexed-v1",
            qualityTier: .medium,
            controls: controls
        )

        XCTAssertEqual(firstKey, secondKey)
        let encoded = String(decoding: try JSONEncoder().encode(firstKey), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-video"))
        XCTAssertFalse(encoded.contains("example.test"))
        XCTAssertFalse(encoded.contains("9000"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("etag"))
    }

    nonisolated func testCapabilityStartsUnknownAndSuccessCannotCreateSupport() {
        let key = makeCapabilityKey()
        let registry = PlaybackCapabilityRegistry(profile: nil)

        XCTAssertEqual(registry.status(for: key, controls: enabledControls(percent: 100)), .unknown)
        registry.record(.success, for: key)
        XCTAssertEqual(registry.status(for: key, controls: enabledControls(percent: 100)), .unknown)
    }

    nonisolated func testOnlyValidatedStructuralFailureCanBlacklistCapability() throws {
        let key = makeCapabilityKey()
        let now = Date(timeIntervalSince1970: 1_000)
        let controls = enabledControls(percent: 100)
        let structuralRows: [(
            failure: PlaybackCapabilityFailure,
            expected: PlaybackCapabilityFailureDisposition
        )] = [
            (
                .validatedStructural(.nonzeroRangeReturnedFullResponse),
                .structuralIncompatibility
            ),
            (.validatedStructural(.inconsistentContentRange), .structuralIncompatibility),
            (.validatedStructural(.changedStrongValidator), .structuralIncompatibility),
            (.validatedStructural(.malformedContainerLayout), .structuralIncompatibility),
            (.validatedStructural(.decoderRejectedContainer), .structuralIncompatibility),
            (.validatedStructural(.seekRestartedFromZero), .structuralIncompatibility),
            (
                .validatedStructural(.avFoundationPlayerErrorMinus12371),
                .structuralIncompatibility
            ),
            (
                .validatedStructural(.avFoundationPlayerErrorMinus12864),
                .structuralIncompatibility
            ),
            (
                .validatedStructural(.seekCompletedWithoutResumedDecodedPCM),
                .structuralIncompatibility
            ),
        ]
        let transientRows: [(
            failure: PlaybackCapabilityFailure,
            expected: PlaybackCapabilityFailureDisposition
        )] = [
            (.timeout, .transient),
            (
                .validatedHTTP5xx(
                    try XCTUnwrap(ValidatedTransientHTTP5xx(statusCode: 500))
                ),
                .transient
            ),
            (
                .validatedHTTP5xx(
                    try XCTUnwrap(ValidatedTransientHTTP5xx(statusCode: 503))
                ),
                .transient
            ),
            (.temporaryConnectivityLoss, .transient),
            (.cancelled, .transient),
            (.backgroundSuspension, .transient),
        ]
        let policyRows: [(
            failure: PlaybackCapabilityFailure,
            expected: PlaybackCapabilityFailureDisposition
        )] = [
            (.networkPolicyDenied, .policy),
            (.userDeclined, .policy),
        ]

        for row in structuralRows {
            let registry = PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: key, now: now),
                now: { now }
            )
            XCTAssertEqual(registry.status(for: key, controls: controls), .supported)
            XCTAssertEqual(row.failure.compatibilityDisposition, row.expected)
            registry.record(.failure(row.failure), for: key)
            XCTAssertEqual(
                registry.status(for: key, controls: controls),
                .incompatible,
                "Every normative structural failure must blacklist the capability"
            )
        }

        for row in transientRows + policyRows {
            let registry = PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: key, now: now),
                now: { now }
            )
            XCTAssertEqual(registry.status(for: key, controls: controls), .supported)
            XCTAssertEqual(row.failure.compatibilityDisposition, row.expected)
            registry.record(.failure(row.failure), for: key)
            XCTAssertEqual(
                registry.status(for: key, controls: controls),
                .supported,
                "Transient and policy outcomes must not mutate compatibility"
            )
        }
    }

    nonisolated func testOnlyValidatedFiveHundredRangeCanBecomeTransientHTTPFailure() throws {
        for statusCode in [500, 503, 599] {
            let serverFailure = try XCTUnwrap(
                ValidatedTransientHTTP5xx(statusCode: statusCode)
            )
            XCTAssertEqual(serverFailure.statusCode, statusCode)
            XCTAssertEqual(
                PlaybackCapabilityFailure.validatedHTTP5xx(serverFailure)
                    .compatibilityDisposition,
                .transient
            )
        }

        for statusCode in [0, 200, 416, 499, 600] {
            XCTAssertNil(
                ValidatedTransientHTTP5xx(statusCode: statusCode),
                "HTTP \(statusCode) must not be forgeable as a transient 5xx failure"
            )
        }
    }

    nonisolated func testSupportRequiresCurrentSchemaValidProfileWithExactEntry() {
        let key = makeCapabilityKey()
        let other = CapabilityKey(
            appBuild: key.appBuild,
            iOSBuild: key.iOSBuild,
            deviceFamily: key.deviceFamily,
            itag: 256,
            mimeType: key.mimeType,
            codec: key.codec,
            containerLayoutProfile: key.containerLayoutProfile,
            qualityTier: key.qualityTier,
            headerSchemaVersion: key.headerSchemaVersion,
            loaderVersion: key.loaderVersion
        )
        let now = Date(timeIntervalSince1970: 5_000)
        let controls = enabledControls(percent: 100)

        XCTAssertEqual(
            PlaybackCapabilityRegistry(profile: nil, now: { now }).status(
                for: key,
                controls: controls
            ),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: other, now: now),
                now: { now }
            ).status(for: key, controls: controls),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: PlaybackCompatibilityProfile(
                    schemaVersion: 1,
                    loaderVersion: 2,
                    headerSchemaVersion: 1,
                    validUntil: now.addingTimeInterval(100),
                    supportedCapabilities: [key]
                ),
                now: { now }
            ).status(for: key, controls: controls),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: PlaybackCompatibilityProfile(
                    schemaVersion: 1,
                    loaderVersion: 1,
                    headerSchemaVersion: 2,
                    validUntil: now.addingTimeInterval(100),
                    supportedCapabilities: [key]
                ),
                now: { now }
            ).status(for: key, controls: controls),
            .unknown
        )
        let mismatchedControls = PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: true,
            killSwitch: false,
            killSwitchEpoch: 1,
            loaderVersion: 2,
            headerSchemaVersion: 1
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: key, now: now),
                now: { now }
            ).status(for: key, controls: mismatchedControls),
            .unknown
        )
        let mismatchedHeaderControls = PlaybackFeatureSnapshot(
            rangeStreamingV1: true,
            cohortPercent: 100,
            boundedPreloadV1: true,
            killSwitch: false,
            killSwitchEpoch: 1,
            loaderVersion: 1,
            headerSchemaVersion: 2
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: key, now: now),
                now: { now }
            ).status(for: key, controls: mismatchedHeaderControls),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: PlaybackCompatibilityProfile(
                    schemaVersion: 2,
                    loaderVersion: 1,
                    headerSchemaVersion: 1,
                    validUntil: now.addingTimeInterval(100),
                    supportedCapabilities: [key]
                ),
                now: { now }
            ).status(for: key, controls: controls),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: PlaybackCompatibilityProfile(
                    schemaVersion: 1,
                    loaderVersion: 1,
                    headerSchemaVersion: 1,
                    validUntil: now,
                    supportedCapabilities: [key]
                ),
                now: { now }
            ).status(for: key, controls: controls),
            .unknown
        )
        XCTAssertEqual(
            PlaybackCapabilityRegistry(
                profile: currentProfile(supporting: key, now: now),
                now: { now }
            ).status(for: key, controls: controls),
            .supported
        )
    }

    // MARK: - Helpers

    private var validRangeFields: [String: Any] {
        [
            "range_streaming_v1": true,
            "range_streaming_cohort_percent": 37,
            "bounded_preload_v1": true,
            "range_streaming_kill_switch": false,
            "range_streaming_kill_switch_epoch": 9,
            "range_loader_policy_version": 1,
            "range_header_schema_version": 1,
        ]
    }

    private enum RemoteFieldMutation {
        case missing
        case malformed
    }

    private func makeFlags(jsonObject: [String: Any]) throws -> FeatureFlagManager {
        let suiteName = "PlaybackFeatureControlsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(
            try JSONSerialization.data(withJSONObject: jsonObject),
            forKey: "feature_flags_cache"
        )
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return FeatureFlagManager(
            configURLString: "https://invalid.example.test/config",
            apiKey: nil,
            defaults: defaults
        )
    }

    private func makeFlagsWithoutCachedConfig() throws -> FeatureFlagManager {
        let suiteName = "PlaybackFeatureControlsTests.Empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return FeatureFlagManager(
            configURLString: "https://invalid.example.test/config",
            apiKey: nil,
            defaults: defaults
        )
    }

    private func sourceText(relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private func enabledControls(percent: Int) -> PlaybackFeatureSnapshot {
    PlaybackFeatureSnapshot(
        rangeStreamingV1: true,
        cohortPercent: percent,
        boundedPreloadV1: true,
        killSwitch: false,
        killSwitchEpoch: 1,
        loaderVersion: 1,
        headerSchemaVersion: 1
    )
}

private func makeCapabilityKey() -> CapabilityKey {
    CapabilityKey(
        appBuild: "42",
        iOSBuild: "23A123",
        deviceFamily: "iPhone",
        itag: 140,
        mimeType: "audio/mp4",
        codec: "mp4a.40.2",
        containerLayoutProfile: "fmp4-indexed-v1",
        qualityTier: .medium,
        headerSchemaVersion: 1,
        loaderVersion: 1
    )
}

private func currentProfile(
    supporting key: CapabilityKey,
    now: Date
) -> PlaybackCompatibilityProfile {
    PlaybackCompatibilityProfile(
        schemaVersion: 1,
        loaderVersion: 1,
        headerSchemaVersion: 1,
        validUntil: now.addingTimeInterval(3_600),
        supportedCapabilities: [key]
    )
}

private func makeDescriptor(
    videoID: String,
    url: String,
    contentLength: Int64
) -> StreamDescriptor {
    StreamDescriptor(
        videoID: videoID,
        remoteURL: URL(string: url)!,
        itag: 140,
        mimeType: "audio/mp4",
        codec: "mp4a.40.2",
        bitrate: 128_000,
        contentLength: contentLength,
        duration: .seconds(180),
        initializationRange: 0..<700,
        indexRange: 700..<1_000,
        expiresAt: Date(timeIntervalSince1970: 10_000),
        requestHeaders: ["User-Agent": "test"],
        provisionalResourceKey: ProvisionalResourceKey(
            videoID: videoID,
            itag: 140,
            codec: "mp4a.40.2",
            declaredTotalLength: contentLength
        )
    )
}

private final class PlaybackInstallIDStoreStub: PlaybackInstallIDStoring, @unchecked Sendable {
    enum Failure: Error {
        case readFailed
        case writeFailed
        case generationFailed
    }

    private struct State {
        var value: Data?
        var readCount = 0
        var writeCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let readResult: Result<Data?, Failure>
    private let writeResult: Result<Void, Failure>

    init(
        readResult: Result<Data?, Failure>,
        writeResult: Result<Void, Failure> = .success(())
    ) {
        self.readResult = readResult
        self.writeResult = writeResult
        self.state = OSAllocatedUnfairLock(
            initialState: State(value: try? readResult.get())
        )
    }

    var readCount: Int { state.withLock { $0.readCount } }
    var writeCount: Int { state.withLock { $0.writeCount } }

    func readInstallID() throws -> Data? {
        try state.withLock { state in
            state.readCount += 1
            if let value = state.value { return value }
            return try readResult.get()
        }
    }

    func writeInstallID(_ value: Data) throws {
        try writeResult.get()
        state.withLock { state in
            state.writeCount += 1
            state.value = value
        }
    }
}
