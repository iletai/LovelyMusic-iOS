import Foundation
import XCTest

@testable import LovelyMusic

@MainActor
final class PlaybackPolicyTests: XCTestCase {
    func testImplicitFullTransferDecisionMatrix() async {
        let cases: [(NetworkSnapshot, FullResourceTransferDecisionCategory)] = [
            (.wifi(expensive: false, constrained: false), .allow),
            (.wifi(expensive: true, constrained: false), .requireConsent),
            (.wifi(expensive: false, constrained: true), .requireConsent),
            (.cellular(constrained: false), .requireConsent),
            (.cellular(constrained: true), .requireConsent),
            (.offline, .deny),
        ]
        let intents: [FullTransferIntent] = [
            .initialPlayback,
            .sourceFallback,
            .transportRetry,
        ]

        for intent in intents {
            for (network, expected) in cases {
                let harness = makeGate(network: network)
                let request = FullResourceTransferRequest.fixture(intent: intent)

                let decision = await harness.gate.evaluate(request)

                XCTAssertEqual(
                    decision.category,
                    expected,
                    "network=\(network), intent=\(intent)"
                )
                switch decision {
                case .allow(let reservationID):
                    await harness.gate.release(reservationID)
                    let reservedBytes = await harness.ledger.reservedBytes
                    XCTAssertEqual(reservedBytes, 0)
                case .requireTransferConsent(_, let token, let challenge):
                    XCTAssertEqual(token, request.failedActionToken)
                    XCTAssertEqual(token.actionID, request.actionID)
                    XCTAssertEqual(token.intent, intent)
                    XCTAssertEqual(challenge.token, token)
                    XCTAssertEqual(challenge.networkPolicyRevision, network)
                case .deny(let denial):
                    XCTAssertEqual(denial, .offline)
                }
            }
        }
    }

    func testOfflineReturnsTypedNetworkDenialAfterStoragePasses() async {
        let harness = makeGate(network: .offline)

        let decision = await harness.gate.evaluate(.fixture())

        XCTAssertEqual(decision, .deny(.offline))
    }

    func testMeteredConsentCarriesExactConservativeEstimateAndToken() async {
        let harness = makeGate(
            network: .cellular(constrained: false),
            compatibilityProfile: .fixture(
                legacyPeakMultiplier: StoragePeakMultiplier(
                    numerator: 3,
                    denominator: 2
                ),
                legacySafetyMarginBytes: 7
            )
        )
        let request = FullResourceTransferRequest.fixture(
            validatedContentLength: 101
        )

        let decision = await harness.gate.evaluate(request)

        guard case .requireTransferConsent(
            let estimate,
            let token,
            let challenge
        ) = decision else {
            return XCTFail("Expected a consent challenge")
        }
        XCTAssertEqual(
            estimate,
            FullTransferEstimate(
                networkUpperBoundBytes: 101,
                temporaryStorageUpperBoundBytes: 159
            )
        )
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(challenge.token, token)
        XCTAssertEqual(
            challenge.networkPolicyRevision,
            .cellular(constrained: false)
        )
    }

    func testStorageDenialWinsOverMeteredConsentWithFreshCalibration() async {
        let harness = makeGate(
            network: .cellular(constrained: false),
            availableCapacityBytes: 309
        )

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: 100)
        )

        XCTAssertEqual(decision, .deny(.insufficientStorage))
    }

    func testAcceptedConsentCannotOverrideStorageDenial() async throws {
        let grantingHarness = makeGate(
            network: .cellular(constrained: false)
        )
        let harness = makeGate(
            network: .cellular(constrained: false),
            availableCapacityBytes: 309
        )
        let request = FullResourceTransferRequest.fixture(validatedContentLength: 100)
        let challengeDecision = await grantingHarness.gate.evaluate(request)
        guard case .requireTransferConsent(_, _, let challenge) = challengeDecision else {
            return XCTFail("Expected a consent challenge")
        }
        let issuedGrant = await grantingHarness.gate.acceptConsent(challenge)
        let grant = try XCTUnwrap(issuedGrant)

        let decision = await harness.gate.evaluate(
            request,
            consentGrant: grant
        )

        XCTAssertEqual(decision, .deny(.insufficientStorage))
    }

    func testUnknownContentLengthCannotDisplayFalseSafeUpperBound() async {
        let harness = makeGate(network: .cellular(constrained: false))

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: nil)
        )

        XCTAssertEqual(
            decision,
            .deny(.cannotEstablishConservativeUpperBound)
        )
    }

    func testProductionStorageProfileFailsClosedUntilCalibrated() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .unavailable
        )

        let decision = await harness.gate.evaluate(.fixture())

        XCTAssertEqual(
            decision,
            .deny(.cannotEstablishConservativeUpperBound)
        )
    }

    func testEachMissingCalibrationFieldFailsClosedIndependently() async {
        let multiplier = StoragePeakMultiplier(numerator: 2, denominator: 1)
        let profiles: [(String, PlaybackStorageCompatibilityProfile)] = [
            (
                "multiplier",
                PlaybackStorageCompatibilityProfile(
                    legacyPeakMultiplier: nil,
                    legacySafetyMarginBytes: 10,
                    minimumFreeSpaceReserveBytes: 100,
                    storageCalibrationID: "calibration-current",
                    calibratedContentLengthEnvelope: 1...1_000
                )
            ),
            (
                "margin",
                PlaybackStorageCompatibilityProfile(
                    legacyPeakMultiplier: multiplier,
                    legacySafetyMarginBytes: nil,
                    minimumFreeSpaceReserveBytes: 100,
                    storageCalibrationID: "calibration-current",
                    calibratedContentLengthEnvelope: 1...1_000
                )
            ),
            (
                "reserve",
                PlaybackStorageCompatibilityProfile(
                    legacyPeakMultiplier: multiplier,
                    legacySafetyMarginBytes: 10,
                    minimumFreeSpaceReserveBytes: nil,
                    storageCalibrationID: "calibration-current",
                    calibratedContentLengthEnvelope: 1...1_000
                )
            ),
            (
                "calibration ID",
                PlaybackStorageCompatibilityProfile(
                    legacyPeakMultiplier: multiplier,
                    legacySafetyMarginBytes: 10,
                    minimumFreeSpaceReserveBytes: 100,
                    storageCalibrationID: nil,
                    calibratedContentLengthEnvelope: 1...1_000
                )
            ),
            (
                "envelope",
                PlaybackStorageCompatibilityProfile(
                    legacyPeakMultiplier: multiplier,
                    legacySafetyMarginBytes: 10,
                    minimumFreeSpaceReserveBytes: 100,
                    storageCalibrationID: "calibration-current",
                    calibratedContentLengthEnvelope: nil
                )
            ),
        ]

        for (missingField, profile) in profiles {
            let harness = makeGate(
                network: .wifi(expensive: false, constrained: false),
                compatibilityProfile: profile
            )

            let decision = await harness.gate.evaluate(.fixture())

            XCTAssertEqual(
                decision,
                .deny(.cannotEstablishConservativeUpperBound),
                "missing \(missingField)"
            )
        }
    }

    func testMissingRequiredCalibrationIdentityFailsClosed() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            requiredCalibrationID: nil
        )

        let decision = await harness.gate.evaluate(.fixture())

        XCTAssertEqual(
            decision,
            .deny(.cannotEstablishConservativeUpperBound)
        )
    }

    func testStaleCalibrationIDIsDeniedWithOtherwiseValidProfile() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .fixture(storageCalibrationID: "stale")
        )

        let decision = await harness.gate.evaluate(.fixture())

        XCTAssertEqual(decision, .deny(.staleStorageCalibration))
    }

    func testContentLengthOutsideMeasuredEnvelopeIsDenied() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .fixture(
                calibratedContentLengthEnvelope: 50...99
            )
        )

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: 100)
        )

        XCTAssertEqual(decision, .deny(.outsideMeasuredStorageEnvelope))
    }

    func testEstimateOverflowReachesCheckedArithmeticAndIsDenied() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .fixture(
                legacyPeakMultiplier: StoragePeakMultiplier(
                    numerator: 2,
                    denominator: 1
                ),
                legacySafetyMarginBytes: 0,
                minimumFreeSpaceReserveBytes: 0,
                calibratedContentLengthEnvelope: 1...Int64.max
            ),
            availableCapacityBytes: Int64.max
        )

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: Int64.max)
        )

        XCTAssertEqual(decision, .deny(.storageEstimateArithmeticOverflow))
    }

    func testSafetyMarginAdditionOverflowIsDenied() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .fixture(
                legacyPeakMultiplier: StoragePeakMultiplier(
                    numerator: 1,
                    denominator: 1
                ),
                legacySafetyMarginBytes: 2,
                minimumFreeSpaceReserveBytes: 0,
                calibratedContentLengthEnvelope: 1...Int64.max
            ),
            availableCapacityBytes: Int64.max
        )

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: Int64.max - 1)
        )

        XCTAssertEqual(decision, .deny(.storageEstimateArithmeticOverflow))
    }

    func testMinimumReserveAdditionOverflowIsDenied() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false),
            compatibilityProfile: .fixture(
                legacyPeakMultiplier: StoragePeakMultiplier(
                    numerator: 1,
                    denominator: 1
                ),
                legacySafetyMarginBytes: 0,
                minimumFreeSpaceReserveBytes: 1,
                calibratedContentLengthEnvelope: 1...Int64.max
            ),
            availableCapacityBytes: Int64.max
        )

        let decision = await harness.gate.evaluate(
            .fixture(validatedContentLength: Int64.max)
        )

        XCTAssertEqual(decision, .deny(.insufficientStorage))
    }

    func testCapacityProviderFailureAndNegativeCapacityFailClosed() async {
        let cases: [(String, any PlaybackCapacityProviding)] = [
            ("provider error", ThrowingCapacityProvider()),
            ("negative capacity", FixedCapacityProvider(bytes: -1)),
        ]

        for (name, capacityProvider) in cases {
            let harness = makeGate(
                network: .wifi(expensive: false, constrained: false),
                capacityProvider: capacityProvider
            )

            let decision = await harness.gate.evaluate(.fixture())

            XCTAssertEqual(decision, .deny(.capacityUnavailable), name)
        }
    }

    func testSecondCapacityReadFailureStaysTypedAndMintsNoReservation() async {
        let cases: [
            (
                name: String,
                secondOutcome: SequencedCapacityProvider.Outcome,
                expected: PlaybackPolicyDenial
            )
        ] = [
            ("provider error", .failure, .capacityUnavailable),
            ("negative capacity", .bytes(-1), .capacityUnavailable),
            ("insufficient capacity", .bytes(309), .insufficientStorage),
        ]

        for testCase in cases {
            let provider = SequencedCapacityProvider(
                outcomes: [.bytes(10_000), testCase.secondOutcome]
            )
            let harness = makeGate(
                network: .wifi(expensive: false, constrained: false),
                capacityProvider: provider
            )

            let decision = await harness.gate.evaluate(.fixture())

            XCTAssertEqual(
                decision,
                .deny(testCase.expected),
                testCase.name
            )
            let reservationCount = await harness.ledger.reservationCount
            let reservedBytes = await harness.ledger.reservedBytes
            XCTAssertEqual(reservationCount, 0, testCase.name)
            XCTAssertEqual(reservedBytes, 0, testCase.name)
        }
    }

    func testTwoConcurrentReservationsCannotSpendSameCapacity() async {
        let ledger = PlaybackStorageReservationLedger(
            capacityProvider: FixedCapacityProvider(bytes: 100)
        )
        let barrier = TaskStartBarrier(participants: 2)

        let reservations = await withTaskGroup(
            of: PlaybackStorageReservationResult.self,
            returning: [PlaybackStorageReservationResult].self
        ) { group in
            for _ in 0..<2 {
                group.addTask {
                    await barrier.wait()
                    return await ledger.reserve(
                        bytes: 70,
                        minimumFreeSpaceReserveBytes: 20
                    )
                }
            }

            var results: [PlaybackStorageReservationResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let reservedBytes = await ledger.reservedBytes
        let reservationCount = await ledger.reservationCount
        let reservationIDs: [StorageReservationID] = reservations.compactMap {
            result -> StorageReservationID? in
            guard case .reserved(let reservationID) = result else { return nil }
            return reservationID
        }
        XCTAssertEqual(reservationIDs.count, 1)
        XCTAssertEqual(
            reservations.filter { $0 == .denied(.insufficientStorage) }.count,
            1
        )
        XCTAssertEqual(reservedBytes, 70)
        XCTAssertEqual(reservationCount, 1)
    }

    func testReservationTotalAdditionOverflowCannotMintReservation() async throws {
        let ledger = PlaybackStorageReservationLedger(
            capacityProvider: FixedCapacityProvider(bytes: Int64.max)
        )
        let firstResult = await ledger.reserve(
            bytes: Int64.max - 10,
            minimumFreeSpaceReserveBytes: 0
        )
        guard case .reserved(let first) = firstResult else {
            return XCTFail("Expected the first reservation")
        }

        let overflow = await ledger.reserve(
            bytes: 20,
            minimumFreeSpaceReserveBytes: 0
        )

        XCTAssertEqual(overflow, .denied(.insufficientStorage))
        let reservedBytes = await ledger.reservedBytes
        XCTAssertEqual(reservedBytes, Int64.max - 10)
        await ledger.release(first)
    }

    func testDoubleReleaseCannotCreditCapacityTwice() async throws {
        let ledger = PlaybackStorageReservationLedger(
            capacityProvider: FixedCapacityProvider(bytes: 100)
        )
        let firstResult = await ledger.reserve(
            bytes: 60,
            minimumFreeSpaceReserveBytes: 10
        )
        guard case .reserved(let first) = firstResult else {
            return XCTFail("Expected the first reservation")
        }

        await ledger.release(first)
        await ledger.release(first)

        let impossibleAfterHonestRelease = await ledger.reserve(
            bytes: 95,
            minimumFreeSpaceReserveBytes: 10
        )
        let exactCapacity = await ledger.reserve(
            bytes: 90,
            minimumFreeSpaceReserveBytes: 10
        )

        XCTAssertEqual(
            impossibleAfterHonestRelease,
            .denied(.insufficientStorage)
        )
        guard case .reserved = exactCapacity else {
            return XCTFail("Expected exact remaining capacity to reserve")
        }
        let reservedBytes = await ledger.reservedBytes
        XCTAssertEqual(reservedBytes, 90)
    }

    func testConsentDecisionLeavesNoOrphanReservation() async {
        let harness = makeGate(network: .cellular(constrained: false))

        let decision = await harness.gate.evaluate(.fixture())

        XCTAssertEqual(decision.category, .requireConsent)
        let reservedBytes = await harness.ledger.reservedBytes
        let reservationCount = await harness.ledger.reservationCount
        XCTAssertEqual(reservedBytes, 0)
        XCTAssertEqual(reservationCount, 0)
    }

    func testMatchingAcceptedConsentReservesBeforeAllowing() async throws {
        let harness = makeGate(network: .cellular(constrained: false))
        let request = FullResourceTransferRequest.fixture()
        let challengeDecision = await harness.gate.evaluate(request)
        guard case .requireTransferConsent(_, _, let challenge) = challengeDecision else {
            return XCTFail("Expected a consent challenge")
        }
        let issuedGrant = await harness.gate.acceptConsent(challenge)
        let grant = try XCTUnwrap(issuedGrant)

        let decision = await harness.gate.evaluate(
            request,
            consentGrant: grant
        )

        guard case .allow(let reservationID) = decision else {
            return XCTFail("Expected a gate-issued reservation")
        }
        let reservedBeforeRelease = await harness.ledger.reservedBytes
        XCTAssertEqual(reservedBeforeRelease, 210)
        await harness.gate.release(reservationID)
        let reservedAfterRelease = await harness.ledger.reservedBytes
        XCTAssertEqual(reservedAfterRelease, 0)
    }

    func testMismatchedConsentTokenCannotAuthorizeTransfer() async throws {
        let harness = makeGate(network: .cellular(constrained: false))
        let request = FullResourceTransferRequest.fixture()
        let otherRequest = FullResourceTransferRequest.fixture()
        let challengeDecision = await harness.gate.evaluate(otherRequest)
        guard case .requireTransferConsent(_, _, let challenge) = challengeDecision else {
            return XCTFail("Expected a consent challenge")
        }
        let issuedGrant = await harness.gate.acceptConsent(challenge)
        let otherGrant = try XCTUnwrap(issuedGrant)

        let decision = await harness.gate.evaluate(
            request,
            consentGrant: otherGrant
        )

        XCTAssertEqual(decision, .deny(.consentChallengeInvalidated))
        let reservationCount = await harness.ledger.reservationCount
        XCTAssertEqual(reservationCount, 0)
    }

    func testAcceptedConsentCannotCrossMeteredNetworkRevisionOrReprompt() async throws {
        let harness = makeGate(
            network: .wifi(
                expensive: true,
                constrained: false,
                pathVersion: 1
            )
        )
        let request = FullResourceTransferRequest.fixture()
        let initialDecision = await harness.gate.evaluate(request)
        guard case .requireTransferConsent(
            _,
            let initialToken,
            let challenge
        ) = initialDecision else {
            return XCTFail("Expected the original metered consent prompt")
        }
        var lifecycle = FullTransferConsentLifecycle()
        XCTAssertEqual(initialToken, request.failedActionToken)
        XCTAssertEqual(challenge.token, initialToken)
        XCTAssertEqual(challenge.networkPolicyRevision.pathVersion, 1)
        XCTAssertTrue(lifecycle.present(initialToken))
        XCTAssertTrue(lifecycle.accept(initialToken))
        let issuedGrant = await harness.gate.acceptConsent(challenge)
        let revisionOneGrant = try XCTUnwrap(issuedGrant)

        await harness.gate.updateNetwork(
            .wifi(
                expensive: true,
                constrained: false,
                pathVersion: 2
            )
        )
        let staleAcceptance = await harness.gate.evaluate(
            request,
            consentGrant: revisionOneGrant
        )
        let repeatedEvaluation = await harness.gate.evaluate(request)

        XCTAssertEqual(
            staleAcceptance,
            .deny(.consentChallengeInvalidated)
        )
        XCTAssertEqual(
            repeatedEvaluation,
            .deny(.consentChallengeInvalidated)
        )
        XCTAssertEqual(initialToken, request.failedActionToken)
        XCTAssertFalse(lifecycle.present(initialToken))
        let reservationCount = await harness.ledger.reservationCount
        let reservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(reservationCount, 0)
        XCTAssertEqual(reservedBytes, 0)
    }

    func testConsentGrantIsSingleUseAndCannotMintAnotherPrompt() async throws {
        let harness = makeGate(network: .cellular(constrained: false))
        let request = FullResourceTransferRequest.fixture()
        let challengeDecision = await harness.gate.evaluate(request)
        guard case .requireTransferConsent(
            _,
            let token,
            let challenge
        ) = challengeDecision else {
            return XCTFail("Expected a consent challenge")
        }
        var lifecycle = FullTransferConsentLifecycle()
        XCTAssertTrue(lifecycle.present(token))
        XCTAssertTrue(lifecycle.accept(token))
        let issuedGrant = await harness.gate.acceptConsent(challenge)
        let grant = try XCTUnwrap(issuedGrant)

        let firstUse = await harness.gate.evaluate(
            request,
            consentGrant: grant
        )
        guard case .allow(let reservationID) = firstUse else {
            return XCTFail("Expected the one-use grant to allow exactly once")
        }
        await harness.gate.release(reservationID)
        let replay = await harness.gate.evaluate(
            request,
            consentGrant: grant
        )

        XCTAssertEqual(replay, .deny(.consentChallengeInvalidated))
        XCTAssertFalse(lifecycle.present(token))
        let reservationCount = await harness.ledger.reservationCount
        let reservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(reservationCount, 0)
        XCTAssertEqual(reservedBytes, 0)
    }

    func testSameWiFiInterfaceExpensiveAndConstrainedChangesPublishNewVersions() async {
        let recorder = NetworkSnapshotRecorder()
        let monitor = PlaybackNetworkMonitor()
        await monitor.setUpdateHandler { snapshot in
            await recorder.record(snapshot)
        }

        _ = await monitor.receive(
            .wifi(expensive: false, constrained: false)
        )
        _ = await monitor.receive(
            .wifi(expensive: true, constrained: false)
        )
        _ = await monitor.receive(
            .wifi(expensive: true, constrained: false)
        )
        _ = await monitor.receive(
            .wifi(expensive: false, constrained: true)
        )

        let published = await recorder.snapshots
        XCTAssertEqual(published.map(\.pathVersion), [1, 2, 3])
        XCTAssertTrue(published.allSatisfy(\.usesWiFi))
        XCTAssertTrue(published.allSatisfy { !$0.usesCellular })
        XCTAssertEqual(published.map(\.isExpensive), [false, true, false])
        XCTAssertEqual(published.map(\.isConstrained), [false, false, true])
    }

    func testMonitorRestartUsesFreshNativeInstanceAndFailsClosedUntilNewPath() async throws {
        let factory = RecordingNetworkPathMonitorFactory()
        let harness = makeGate(network: .offline)
        let monitor = PlaybackNetworkMonitor(
            monitorFactory: { factory.makeMonitor() }
        )
        let request = FullResourceTransferRequest.fixture()
        let recorder = NetworkSnapshotRecorder()
        let firstWiFiPublished = expectation(
            description: "first native monitor publishes Wi-Fi"
        )
        let secondCellularPublished = expectation(
            description: "second native monitor publishes cellular"
        )
        await monitor.setUpdateHandler { snapshot in
            await harness.gate.updateNetwork(snapshot)
            await recorder.record(snapshot)
            if snapshot.usesWiFi {
                firstWiFiPublished.fulfill()
            }
            if snapshot.usesCellular {
                secondCellularPublished.fulfill()
            }
        }

        await monitor.start()
        let firstMonitor = try XCTUnwrap(factory.instance(at: 0))
        XCTAssertTrue(firstMonitor.isStarted)
        firstMonitor.send(.wifi(expensive: false, constrained: false))
        await fulfillment(of: [firstWiFiPublished], timeout: 1)
        let firstSnapshot = await monitor.currentSnapshot
        XCTAssertTrue(firstSnapshot.usesWiFi)
        let initialDecision = await harness.gate.evaluate(request)
        guard case .allow(let initialReservationID) = initialDecision else {
            return XCTFail("Expected the first native Wi-Fi path to allow")
        }
        await harness.gate.release(initialReservationID)
        let lateFirstDelivery = try XCTUnwrap(firstMonitor.capturedDelivery())

        await monitor.stop()
        XCTAssertTrue(firstMonitor.isCancelled)
        lateFirstDelivery(.wifi(expensive: true, constrained: false))
        await monitor.start()
        let secondMonitor = try XCTUnwrap(factory.instance(at: 1))

        XCTAssertFalse(firstMonitor === secondMonitor)
        XCTAssertTrue(secondMonitor.isStarted)
        XCTAssertFalse(secondMonitor.isCancelled)
        let beforeSecondPath = await harness.gate.evaluate(request)
        XCTAssertEqual(beforeSecondPath, .deny(.offline))
        let reservationCountBeforePath = await harness.ledger.reservationCount
        let reservedBytesBeforePath = await harness.ledger.reservedBytes
        XCTAssertEqual(reservationCountBeforePath, 0)
        XCTAssertEqual(reservedBytesBeforePath, 0)

        lateFirstDelivery(.wifi(expensive: false, constrained: false))
        secondMonitor.send(.cellular(constrained: false))
        await fulfillment(of: [secondCellularPublished], timeout: 1)
        let secondSnapshot = await monitor.currentSnapshot
        XCTAssertTrue(secondSnapshot.usesCellular)
        let deliveredSnapshots = await recorder.snapshots
        XCTAssertEqual(deliveredSnapshots.map(\.pathVersion), [1, 2, 3])
        XCTAssertEqual(deliveredSnapshots.map(\.usesWiFi), [true, false, false])
        XCTAssertEqual(deliveredSnapshots.map(\.usesCellular), [false, false, true])
        let currentDecision = await harness.gate.evaluate(request)
        guard case .requireTransferConsent(
            _,
            let token,
            let challenge
        ) = currentDecision else {
            return XCTFail("Expected only the second monitor path to publish")
        }
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(challenge.networkPolicyRevision, secondSnapshot)
        let finalReservationCount = await harness.ledger.reservationCount
        let finalReservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(finalReservationCount, 0)
        XCTAssertEqual(finalReservedBytes, 0)
        await monitor.stop()
    }

    func testActiveWiFiBecomingExpensiveReleasesReservationAndReentersConsent() async throws {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false)
        )
        let request = FullResourceTransferRequest.fixture()
        let initialDecision = await harness.gate.evaluate(request)
        guard case .allow(let reservationID) = initialDecision else {
            return XCTFail("Expected initial automatic Wi-Fi allowance")
        }
        let activeReservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(activeReservedBytes, 210)

        await harness.gate.updateNetwork(
            .wifi(expensive: true, constrained: false, pathVersion: 2)
        )
        let reevaluated = await harness.gate.releaseReservationAndReevaluate(
            request,
            activeReservationID: reservationID
        )

        guard case .requireTransferConsent(
            let estimate,
            let token,
            let challenge
        ) = reevaluated else {
            return XCTFail("Expected active transfer to re-enter consent")
        }
        XCTAssertEqual(
            estimate,
            FullTransferEstimate(
                networkUpperBoundBytes: 100,
                temporaryStorageUpperBoundBytes: 210
            )
        )
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(challenge.token, token)
        XCTAssertEqual(challenge.networkPolicyRevision.pathVersion, 2)
        let reservationCount = await harness.ledger.reservationCount
        let reservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(reservationCount, 0)
        XCTAssertEqual(reservedBytes, 0)
    }

    func testFailedActionTokenExcludesLatestSeekTarget() {
        let initial = FullResourceTransferRequest.fixture(
            latestSeekTargetSeconds: 10
        )

        let latest = initial.updatingLatestSeekTarget(to: 90)

        XCTAssertEqual(latest.sessionID, initial.sessionID)
        XCTAssertEqual(latest.actionID, initial.actionID)
        XCTAssertEqual(latest.failedActionToken, initial.failedActionToken)
        XCTAssertEqual(latest.latestSeekTargetSeconds, 90)
    }

    func testMonitorPathChangeKeepsActionTokenInGateConsentDecision() async {
        let harness = makeGate(
            network: .wifi(expensive: false, constrained: false)
        )
        let monitor = PlaybackNetworkMonitor()
        let request = FullResourceTransferRequest.fixture()
        await monitor.setUpdateHandler { snapshot in
            await harness.gate.updateNetwork(snapshot)
        }

        _ = await monitor.receive(.wifi(expensive: true, constrained: false))
        _ = await monitor.receive(.cellular(constrained: true))
        let cellular = await harness.gate.evaluate(request)

        guard case .requireTransferConsent(
            _,
            let token,
            let challenge
        ) = cellular else {
            return XCTFail("Expected consent after the latest metered path update")
        }
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(token.actionID, request.actionID)
        XCTAssertEqual(challenge.token, token)
        XCTAssertEqual(challenge.networkPolicyRevision.pathVersion, 2)
    }

    func testStaleNetworkVersionCannotReplaceNewerMeteredSnapshot() async {
        let harness = makeGate(
            network: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 0
            )
        )
        let request = FullResourceTransferRequest.fixture()

        await harness.gate.updateNetwork(
            .cellular(constrained: false, pathVersion: 2)
        )
        await harness.gate.updateNetwork(
            .wifi(expensive: false, constrained: false, pathVersion: 1)
        )
        let decision = await harness.gate.evaluate(request)

        guard case .requireTransferConsent(
            let estimate,
            let token,
            let challenge
        ) = decision else {
            return XCTFail("Expected the newer metered path to require consent")
        }
        XCTAssertEqual(
            estimate,
            FullTransferEstimate(
                networkUpperBoundBytes: 100,
                temporaryStorageUpperBoundBytes: 210
            )
        )
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(challenge.networkPolicyRevision.pathVersion, 2)
        let reservationCount = await harness.ledger.reservationCount
        XCTAssertEqual(reservationCount, 0)
    }

    func testNetworkChangeWhileReservationSuspendsCannotReturnStaleAllow() async {
        let capacityProvider = ControllableCapacityProvider(
            bytes: 10_000,
            blockingCall: 2
        )
        let harness = makeGate(
            network: .wifi(
                expensive: false,
                constrained: false,
                pathVersion: 1
            ),
            capacityProvider: capacityProvider
        )
        let request = FullResourceTransferRequest.fixture()
        let evaluation = Task {
            await harness.gate.evaluate(request)
        }

        await capacityProvider.waitUntilBlockedCallStarts()
        await harness.gate.updateNetwork(
            .cellular(constrained: false, pathVersion: 2)
        )
        await capacityProvider.resumeBlockedCall()
        let decision = await evaluation.value

        guard case .requireTransferConsent(
            let estimate,
            let token,
            let challenge
        ) = decision else {
            return XCTFail("Expected re-evaluation on the newer network")
        }
        XCTAssertEqual(
            estimate,
            FullTransferEstimate(
                networkUpperBoundBytes: 100,
                temporaryStorageUpperBoundBytes: 210
            )
        )
        XCTAssertEqual(token, request.failedActionToken)
        XCTAssertEqual(challenge.networkPolicyRevision.pathVersion, 2)
        let reservedBytes = await harness.ledger.reservedBytes
        XCTAssertEqual(reservedBytes, 0)
    }

    func testOnlyExplicitRetryMintsNewActionIdentityWithoutReplacingSession() {
        let request = FullResourceTransferRequest.fixture()
        let seekUpdate = request.updatingLatestSeekTarget(to: 75)

        let retry = seekUpdate.explicitRetry(intent: .transportRetry)

        XCTAssertEqual(seekUpdate.actionID, request.actionID)
        XCTAssertEqual(retry.sessionID, request.sessionID)
        XCTAssertNotEqual(retry.actionID, request.actionID)
        XCTAssertNotEqual(retry.failedActionToken, request.failedActionToken)
        XCTAssertEqual(retry.latestSeekTargetSeconds, 75)
        XCTAssertEqual(retry.intent, .transportRetry)
    }

    func testPresentationConsumesAllowanceAndAcceptClosesPrompt() {
        var lifecycle = FullTransferConsentLifecycle()
        let token = FullResourceTransferRequest.fixture().failedActionToken

        XCTAssertTrue(lifecycle.present(token))
        XCTAssertFalse(lifecycle.present(token))
        XCTAssertTrue(lifecycle.accept(token))
        XCTAssertEqual(lifecycle.status(for: token), .accepted)
        XCTAssertFalse(lifecycle.accept(token))
        XCTAssertFalse(lifecycle.decline(token))
        XCTAssertFalse(lifecycle.present(token))
    }

    func testDeclineClosesPromptAndSeekOrPathCannotResurrectIt() {
        var lifecycle = FullTransferConsentLifecycle()
        let request = FullResourceTransferRequest.fixture(
            latestSeekTargetSeconds: 20
        )
        let token = request.failedActionToken
        XCTAssertTrue(lifecycle.present(token))
        XCTAssertTrue(lifecycle.decline(token))

        let seekUpdate = request.updatingLatestSeekTarget(to: 80)
        let pathUpdate = NetworkSnapshot.cellular(
            constrained: true,
            pathVersion: 2
        )

        XCTAssertEqual(seekUpdate.failedActionToken, token)
        XCTAssertTrue(pathUpdate.isConstrained)
        XCTAssertEqual(lifecycle.status(for: token), .declined)
        XCTAssertFalse(lifecycle.present(seekUpdate.failedActionToken))
    }

    func testExplicitRetryGetsOneFreshPromptAllowance() {
        var lifecycle = FullTransferConsentLifecycle()
        let request = FullResourceTransferRequest.fixture()
        XCTAssertTrue(lifecycle.present(request.failedActionToken))
        XCTAssertTrue(lifecycle.decline(request.failedActionToken))

        let retry = request.explicitRetry(intent: .transportRetry)

        XCTAssertTrue(lifecycle.present(retry.failedActionToken))
        XCTAssertFalse(lifecycle.present(retry.failedActionToken))
        XCTAssertEqual(lifecycle.status(for: request.failedActionToken), .declined)
        XCTAssertEqual(lifecycle.status(for: retry.failedActionToken), .presented)
    }

    func testSafeResumeAfterDeclineCannotReenterFailedSourceImplicitly() throws {
        let sessionID = PlaybackSessionID.fresh()
        let rangeAttempt = SourceAttempt(
            sessionID: sessionID,
            id: .fresh(),
            source: .rangeStream
        )
        let generation = ContentGenerationScope.attemptOnly(
            sessionID: sessionID,
            sourceAttemptID: rangeAttempt.id,
            totalLength: 100
        )
        let transferRequest = FullResourceTransferRequest.begin(
            sessionID: sessionID,
            initialGeneration: generation,
            failureCategory: .seekVerification,
            intent: .sourceFallback,
            validatedContentLength: 100,
            latestSeekTargetSeconds: 12.5
        )
        var state = PlaybackSessionState(
            phase: .playing(rangeAttempt),
            selectedSource: .rangeStream,
            desiredPlaybackIntent: .playing,
            latestRequestedTarget: nil,
            lastConfirmedPosition: 12.5,
            sessionBudget: .initial,
            consumedConsentTokens: [],
            resourceGenerationFingerprint: generation.localFingerprint
        )

        let gateEffects = state.reduce(
            .requestLegacyFallback(
                sourceAttempt: rangeAttempt,
                token: transferRequest.failedActionToken
            )
        )
        let gateAttempt = try XCTUnwrap(
            gateEffects.compactMap { effect -> PlaybackTransferGateAttempt? in
                guard case .evaluateFullResourceTransferGate(let attempt) = effect else {
                    return nil
                }
                return attempt
            }.first
        )
        XCTAssertEqual(
            state.reduce(.fullTransferGateRequiresConsent(gateAttempt)),
            [.presentFullTransferConsent(gateAttempt)]
        )

        let declineEffects = state.reduce(.transferConsentDeclined(gateAttempt))

        XCTAssertEqual(declineEffects, [.cancelTransferGate(gateAttempt.id)])
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .seekVerification,
                    isRecoverable: true,
                    lastConfirmedPosition: 12.5
                )
            )
        )
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertEqual(state.lastConfirmedPosition, 12.5)
        XCTAssertEqual(
            state.consumedConsentTokens,
            [transferRequest.failedActionToken]
        )
        XCTAssertNil(state.pendingTransferGateAttempt)

        let playEffects = state.reduce(.userPlayed)
        let seekEffects = state.reduce(.requestSeek(targetSeconds: 88))
        let pathEffects = state.reduce(.networkClassChanged(.cellular))

        XCTAssertTrue(playEffects.isEmpty)
        XCTAssertTrue(seekEffects.isEmpty)
        XCTAssertTrue(pathEffects.isEmpty)
        XCTAssertEqual(
            state.phase,
            .failed(
                PlaybackFailure(
                    category: .seekVerification,
                    isRecoverable: true,
                    lastConfirmedPosition: 12.5
                )
            )
        )
        XCTAssertEqual(state.selectedSource, .rangeStream)
        XCTAssertEqual(state.lastConfirmedPosition, 12.5)
        XCTAssertEqual(state.latestRequestedTarget, 88)
        XCTAssertNil(state.pendingTransferGateAttempt)
    }
}

private extension PlaybackPolicyTests {
    typealias GateHarness = (
        gate: PlaybackFullResourceTransferGate,
        ledger: PlaybackStorageReservationLedger
    )

    func makeGate(
        network: NetworkSnapshot,
        compatibilityProfile: PlaybackStorageCompatibilityProfile = .fixture(),
        requiredCalibrationID: String? = "calibration-current",
        availableCapacityBytes: Int64 = 10_000,
        capacityProvider: (any PlaybackCapacityProviding)? = nil
    ) -> GateHarness {
        let ledger = PlaybackStorageReservationLedger(
            capacityProvider: capacityProvider
                ?? FixedCapacityProvider(bytes: availableCapacityBytes)
        )
        let storagePolicy = PlaybackStoragePolicy(
            compatibilityProfile: compatibilityProfile,
            requiredCalibrationID: requiredCalibrationID,
            reservationLedger: ledger
        )
        return (
            PlaybackFullResourceTransferGate(
                network: network,
                storagePolicy: storagePolicy
            ),
            ledger
        )
    }
}

private struct FixedCapacityProvider: PlaybackCapacityProviding {
    let bytes: Int64

    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        bytes
    }
}

private struct ThrowingCapacityProvider: PlaybackCapacityProviding {
    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        throw FixtureCapacityError.unavailable
    }
}

private enum FixtureCapacityError: Error {
    case unavailable
}

private final class RecordingNetworkPathMonitorFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingNetworkPathMonitor] = []

    func makeMonitor() -> any PlaybackNetworkPathMonitorInstance {
        let monitor = RecordingNetworkPathMonitor()
        lock.lock()
        storage.append(monitor)
        lock.unlock()
        return monitor
    }

    func instance(at index: Int) -> RecordingNetworkPathMonitor? {
        lock.lock()
        defer { lock.unlock() }
        guard storage.indices.contains(index) else { return nil }
        return storage[index]
    }
}

private final class RecordingNetworkPathMonitor:
    PlaybackNetworkPathMonitorInstance,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var updateHandler:
        (@Sendable (PlaybackNetworkPathObservation) -> Void)?
    private var started = false
    private var cancelled = false

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setPathUpdateHandler(
        _ updateHandler: (@Sendable (PlaybackNetworkPathObservation) -> Void)?
    ) {
        lock.lock()
        self.updateHandler = updateHandler
        lock.unlock()
    }

    func start(queue: DispatchQueue) {
        lock.lock()
        started = true
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func send(_ observation: PlaybackNetworkPathObservation) {
        lock.lock()
        let handler = updateHandler
        lock.unlock()
        handler?(observation)
    }

    func capturedDelivery() -> (
        @Sendable (PlaybackNetworkPathObservation) -> Void
    )? {
        lock.lock()
        defer { lock.unlock() }
        return updateHandler
    }
}

private actor ControllableCapacityProvider: PlaybackCapacityProviding {
    private let bytes: Int64
    private let blockingCall: Int
    private var callCount = 0
    private var blockedCallStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(bytes: Int64, blockingCall: Int) {
        self.bytes = bytes
        self.blockingCall = blockingCall
    }

    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        callCount += 1
        guard callCount == blockingCall else { return bytes }

        blockedCallStarted = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return bytes
    }

    func waitUntilBlockedCallStarts() async {
        guard !blockedCallStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeBlockedCall() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor SequencedCapacityProvider: PlaybackCapacityProviding {
    enum Outcome: Sendable {
        case bytes(Int64)
        case failure
    }

    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func volumeAvailableCapacityForImportantUsage() async throws -> Int64 {
        guard !outcomes.isEmpty else {
            throw FixtureCapacityError.unavailable
        }
        switch outcomes.removeFirst() {
        case .bytes(let bytes):
            return bytes
        case .failure:
            throw FixtureCapacityError.unavailable
        }
    }
}

private actor TaskStartBarrier {
    private let participants: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            guard continuations.count == participants else { return }
            let waiting = continuations
            continuations.removeAll(keepingCapacity: false)
            for continuation in waiting {
                continuation.resume()
            }
        }
    }
}

private actor NetworkSnapshotRecorder {
    private(set) var snapshots: [NetworkSnapshot] = []

    func record(_ snapshot: NetworkSnapshot) {
        snapshots.append(snapshot)
    }
}

private extension PlaybackStorageCompatibilityProfile {
    static func fixture(
        legacyPeakMultiplier: StoragePeakMultiplier = StoragePeakMultiplier(
            numerator: 2,
            denominator: 1
        ),
        legacySafetyMarginBytes: Int64 = 10,
        minimumFreeSpaceReserveBytes: Int64 = 100,
        storageCalibrationID: String = "calibration-current",
        calibratedContentLengthEnvelope: ClosedRange<Int64> = 1...1_000
    ) -> Self {
        Self(
            legacyPeakMultiplier: legacyPeakMultiplier,
            legacySafetyMarginBytes: legacySafetyMarginBytes,
            minimumFreeSpaceReserveBytes: minimumFreeSpaceReserveBytes,
            storageCalibrationID: storageCalibrationID,
            calibratedContentLengthEnvelope: calibratedContentLengthEnvelope
        )
    }
}

private extension FullResourceTransferRequest {
    static func fixture(
        validatedContentLength: Int64? = 100,
        latestSeekTargetSeconds: TimeInterval = 0,
        intent: FullTransferIntent = .sourceFallback
    ) -> Self {
        let sessionID = PlaybackSessionID.fresh()
        let sourceAttemptID = SourceAttemptID.fresh()
        let generation = ContentGenerationScope.attemptOnly(
            sessionID: sessionID,
            sourceAttemptID: sourceAttemptID,
            totalLength: validatedContentLength ?? 100
        )
        return .begin(
            sessionID: sessionID,
            initialGeneration: generation,
            failureCategory: .transport,
            intent: intent,
            validatedContentLength: validatedContentLength,
            latestSeekTargetSeconds: latestSeekTargetSeconds
        )
    }
}
