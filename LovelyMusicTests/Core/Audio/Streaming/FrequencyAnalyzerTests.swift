import Foundation
import XCTest
@testable import LovelyMusic

final class FrequencyAnalyzerTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let framesPerBuffer = 8_000
    private let analysisFrameCount = 16_384

    func testAcceptanceRequirementsAndCenteredAnalysisWindowAreLocked() {
        let requirements = FrequencyAnalyzer.Requirements.fixtureAcceptance
        XCTAssertEqual(requirements.minimumBufferCount, 3)
        XCTAssertEqual(requirements.minimumDurationSeconds, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(requirements.minimumRMSDecibels, -45, accuracy: 0.000_001)
        XCTAssertEqual(requirements.frequencyToleranceFraction, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(requirements.minimumExpectedToneSeparationDecibels, 6, accuracy: 0.000_001)
        XCTAssertEqual(requirements.analysisWindowIdentifier, .hann)

        let buffers = makeBuffers(
            channels: [[.init(frequencyHz: exactBin(300), peakAmplitude: 0.3)]],
            storage: .float32Interleaved
        )
        let result = analyze(
            buffers,
            expectedFrequencyHz: exactBin(300),
            competingFrequenciesHz: [exactBin(200)]
        )

        XCTAssertEqual(result.verdict, .verified)
        XCTAssertEqual(result.analysisFrameCount, analysisFrameCount)
        XCTAssertEqual(result.analysisStartFrame, (24_000 - analysisFrameCount) / 2)
        XCTAssertEqual(result.bufferCount, 3)
        XCTAssertEqual(result.analyzedDurationSeconds, 0.5, accuracy: 1 / sampleRate)
    }

    func testEverySupportedStorageLayoutAndInt16QuantizationAgree() throws {
        let frequency = exactBin(300)
        let channels = [[SyntheticTone(frequencyHz: frequency, peakAmplitude: 0.35)]]
        let layouts: [SyntheticPCMStorage] = [
            .float32Interleaved,
            .float32NonInterleaved,
            .int16Interleaved,
            .int16NonInterleaved,
        ]
        let results = layouts.map { layout in
            analyze(
                makeBuffers(channels: channels, storage: layout),
                expectedFrequencyHz: frequency,
                competingFrequenciesHz: [exactBin(200)]
            )
        }

        XCTAssertTrue(results.allSatisfy { $0.verdict == .verified })
        guard let baseline = results.first else {
            XCTFail("Missing Float32 baseline")
            return
        }
        for result in results.dropFirst() {
            XCTAssertEqual(
                result.dominantFrequencyHz,
                baseline.dominantFrequencyHz,
                accuracy: sampleRate / Double(analysisFrameCount)
            )
            XCTAssertEqual(result.rmsDecibels, baseline.rmsDecibels, accuracy: 0.1)
        }

        let betweenBinFrequency = exactBin(300.5)
        let betweenBinResult = analyze(
            makeBuffers(
                channels: [[.init(frequencyHz: betweenBinFrequency, peakAmplitude: 0.35)]],
                storage: .float32NonInterleaved
            ),
            expectedFrequencyHz: betweenBinFrequency,
            competingFrequenciesHz: [exactBin(200)]
        )
        XCTAssertEqual(betweenBinResult.verdict, .verified)
        XCTAssertEqual(
            betweenBinResult.dominantFrequencyHz,
            betweenBinFrequency,
            accuracy: sampleRate / Double(analysisFrameCount)
        )

        let leakageCompetitor = exactBin(298)
        let leakageTones: [SyntheticTone] = [
            .init(frequencyHz: betweenBinFrequency, peakAmplitude: 0.35),
            .init(
                frequencyHz: leakageCompetitor,
                peakAmplitude: 0.35 / pow(10, 8 / 20)
            ),
        ]
        let referenceSamples = syntheticMonoSamples(
            tones: leakageTones,
            frameCount: framesPerBuffer * 3
        )
        let hannReference = try independentCenteredBandReference(
            samples: referenceSamples,
            analysisFrameCount: analysisFrameCount,
            expectedBins: 300...302,
            competitorBins: 297...299,
            window: .hann
        )
        let rectangularReference = try independentCenteredBandReference(
            samples: referenceSamples,
            analysisFrameCount: analysisFrameCount,
            expectedBins: 300...302,
            competitorBins: 297...299,
            window: .rectangular
        )
        XCTAssertGreaterThanOrEqual(hannReference.separationDecibels, 6)
        XCTAssertLessThan(rectangularReference.separationDecibels, 6)

        let leakageSuppressionResult = analyze(
            makeBuffers(
                channels: [leakageTones],
                storage: .float32Interleaved
            ),
            expectedFrequencyHz: betweenBinFrequency,
            competingFrequenciesHz: [leakageCompetitor]
        )
        XCTAssertEqual(leakageSuppressionResult.windowIdentifier, .hann)
        XCTAssertEqual(leakageSuppressionResult.verdict, .verified)
        XCTAssertEqual(
            leakageSuppressionResult.expectedToneSeparationDecibels,
            hannReference.separationDecibels,
            accuracy: 0.20
        )
        XCTAssertEqual(
            leakageSuppressionResult.expectedBandPowerDecibels,
            hannReference.expectedBandPowerDecibels,
            accuracy: 0.20
        )
        XCTAssertEqual(
            leakageSuppressionResult.strongestCompetingBandPowerDecibels,
            hannReference.competitorBandPowerDecibels,
            accuracy: 0.20
        )
    }

    func testStereoUsesArithmeticMeanForDistinctChannelsAndOneSilentSide() {
        let target = exactBin(300)
        let competitor = exactBin(200)
        let mono = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)]],
            storage: .float32NonInterleaved
        )
        let oneSideSilent = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)], []],
            storage: .float32NonInterleaved
        )
        let distinctStereo = makeBuffers(
            channels: [
                [.init(frequencyHz: target, peakAmplitude: 0.30)],
                [.init(frequencyHz: competitor, peakAmplitude: 0.10)],
            ],
            storage: .float32Interleaved
        )
        let antiphase = makeBuffers(
            channels: [
                [.init(frequencyHz: target, peakAmplitude: 0.30)],
                [.init(frequencyHz: target, peakAmplitude: -0.30)],
            ],
            storage: .float32NonInterleaved
        )

        let monoResult = analyze(mono, expectedFrequencyHz: target, competingFrequenciesHz: [competitor])
        let silentSideResult = analyze(
            oneSideSilent,
            expectedFrequencyHz: target,
            competingFrequenciesHz: [competitor]
        )
        let distinctResult = analyze(
            distinctStereo,
            expectedFrequencyHz: target,
            competingFrequenciesHz: [competitor]
        )
        let antiphaseResult = analyze(
            antiphase,
            expectedFrequencyHz: target,
            competingFrequenciesHz: [competitor]
        )

        XCTAssertEqual(monoResult.verdict, .verified)
        XCTAssertEqual(silentSideResult.verdict, .verified)
        XCTAssertEqual(
            monoResult.rmsDecibels - silentSideResult.rmsDecibels,
            20 * log10(2),
            accuracy: 0.1
        )
        XCTAssertEqual(distinctResult.verdict, .verified)
        XCTAssertGreaterThanOrEqual(distinctResult.expectedToneSeparationDecibels, 6)
        XCTAssertEqual(antiphaseResult.verdict, .silence)

        for intLayout in [
            SyntheticPCMStorage.int16Interleaved,
            .int16NonInterleaved,
        ] {
            let intSilentSide = analyze(
                makeBuffers(
                    channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)], []],
                    storage: intLayout
                ),
                expectedFrequencyHz: target,
                competingFrequenciesHz: [competitor]
            )
            let intDistinct = analyze(
                makeBuffers(
                    channels: [
                        [.init(frequencyHz: target, peakAmplitude: 0.30)],
                        [.init(frequencyHz: competitor, peakAmplitude: 0.10)],
                    ],
                    storage: intLayout
                ),
                expectedFrequencyHz: target,
                competingFrequenciesHz: [competitor]
            )
            XCTAssertEqual(intSilentSide.verdict, .verified)
            XCTAssertEqual(intDistinct.verdict, .verified)
            XCTAssertGreaterThanOrEqual(intDistinct.expectedToneSeparationDecibels, 6)
        }
    }

    func testSilenceShortDCAndDeterministicNoiseCannotFakeVerification() {
        let target = exactBin(300)
        let competitor = exactBin(200)
        let silence = makeBuffers(channels: [[]], storage: .float32Interleaved)
        let short = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.3)]],
            storage: .float32Interleaved,
            bufferFrameCounts: [12_000, 12_000]
        )
        let dc = buffersFromMono(Array(repeating: 0.2, count: 24_000))
        let noise = buffersFromMono(deterministicNoise(count: 24_000, peakAmplitude: 0.2))

        XCTAssertEqual(
            analyze(silence, expectedFrequencyHz: target, competingFrequenciesHz: [competitor]).verdict,
            .silence
        )
        XCTAssertEqual(
            analyze(short, expectedFrequencyHz: target, competingFrequenciesHz: [competitor]).verdict,
            .insufficientEvidence
        )
        XCTAssertEqual(
            analyze(dc, expectedFrequencyHz: target, competingFrequenciesHz: [competitor]).verdict,
            .silence
        )
        XCTAssertEqual(
            analyze(noise, expectedFrequencyHz: target, competingFrequenciesHz: [competitor]).verdict,
            .insufficientEvidence
        )
    }

    func testRMSFrequencyAndSeparationThresholdsAreInclusiveWithEpsilonFailure() {
        let expectedFrequency = exactBin(300)
        let boundaryFrequency = exactBin(309) // Exactly +3 percent.
        let outsideFrequency = exactBin(310)
        let competitor = exactBin(200)

        let exactRMS = makeBuffers(
            channels: [[
                .init(
                    frequencyHz: expectedFrequency,
                    peakAmplitude: peakAmplitude(forRMSDecibels: -45)
                ),
            ]],
            storage: .float32Interleaved
        )
        let belowRMS = makeBuffers(
            channels: [[
                .init(
                    frequencyHz: expectedFrequency,
                    peakAmplitude: peakAmplitude(forRMSDecibels: -45.05)
                ),
            ]],
            storage: .float32Interleaved
        )
        let exactFrequency = makeBuffers(
            channels: [[.init(frequencyHz: boundaryFrequency, peakAmplitude: 0.30)]],
            storage: .float32Interleaved
        )
        let outsideFrequencyBuffers = makeBuffers(
            channels: [[.init(frequencyHz: outsideFrequency, peakAmplitude: 0.30)]],
            storage: .float32Interleaved
        )
        let targetPeak = 0.35
        let exactSeparation = makeBuffers(
            channels: [[
                .init(frequencyHz: expectedFrequency, peakAmplitude: targetPeak),
                .init(
                    frequencyHz: competitor,
                    peakAmplitude: targetPeak / pow(10, 6.0 / 20)
                ),
            ]],
            storage: .float32Interleaved
        )
        let belowSeparation = makeBuffers(
            channels: [[
                .init(frequencyHz: expectedFrequency, peakAmplitude: targetPeak),
                .init(
                    frequencyHz: competitor,
                    peakAmplitude: targetPeak / pow(10, 5.95 / 20)
                ),
            ]],
            storage: .float32Interleaved
        )

        let exactRMSResult = analyze(
            exactRMS,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )
        let belowRMSResult = analyze(
            belowRMS,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )
        let boundaryFrequencyResult = analyze(
            exactFrequency,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )
        let outsideFrequencyResult = analyze(
            outsideFrequencyBuffers,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )
        let exactSeparationResult = analyze(
            exactSeparation,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )
        let belowSeparationResult = analyze(
            belowSeparation,
            expectedFrequencyHz: expectedFrequency,
            competingFrequenciesHz: [competitor]
        )

        XCTAssertEqual(exactRMSResult.verdict, .verified)
        XCTAssertEqual(exactRMSResult.rmsDecibels, -45, accuracy: 0.02)
        XCTAssertEqual(belowRMSResult.verdict, .insufficientEvidence)
        XCTAssertEqual(boundaryFrequencyResult.verdict, .verified)
        XCTAssertEqual(
            abs(boundaryFrequencyResult.dominantFrequencyHz - expectedFrequency)
                / expectedFrequency,
            0.03,
            accuracy: 0.001
        )
        XCTAssertEqual(outsideFrequencyResult.verdict, .insufficientEvidence)
        XCTAssertEqual(exactSeparationResult.verdict, .verified)
        XCTAssertEqual(
            exactSeparationResult.expectedToneSeparationDecibels,
            6,
            accuracy: 0.05
        )
        XCTAssertEqual(belowSeparationResult.verdict, .insufficientEvidence)
    }

    func testInvalidInputsAreRejectedBeforeEvidenceClassification() throws {
        let target = exactBin(300)
        let competitor = exactBin(200)
        let valid = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)]],
            storage: .float32Interleaved
        )
        let firstValid = try XCTUnwrap(valid.first)
        let thirdValid = try XCTUnwrap(valid.dropFirst(2).first)
        let validFloatSamples = floatInterleavedSamples(from: firstValid)
        let validIntSamples = validFloatSamples.map(quantize)

        func repeated(_ buffer: FrequencyAnalyzer.PCMBuffer) -> [FrequencyAnalyzer.PCMBuffer] {
            [buffer, buffer, buffer]
        }
        func malformed(
            frameCount: Int = 8_000,
            channelCount: Int = 1,
            sampleRate: Double = 48_000,
            storage: FrequencyAnalyzer.PCMBuffer.Storage
        ) -> [FrequencyAnalyzer.PCMBuffer] {
            repeated(
                .init(
                    sampleRate: sampleRate,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    storage: storage
                )
            )
        }

        var nanSamples = validFloatSamples
        var infiniteSamples = validFloatSamples
        let firstSampleIndex = try XCTUnwrap(validFloatSamples.indices.first)
        nanSamples[firstSampleIndex] = .nan
        infiniteSamples[firstSampleIndex] = .infinity
        let validPlanarFloat = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)]],
            storage: .float32NonInterleaved
        )
        let validStereo = makeBuffers(
            channels: [
                [.init(frequencyHz: target, peakAmplitude: 0.30)],
                [.init(frequencyHz: target, peakAmplitude: 0.20)],
            ],
            storage: .float32Interleaved
        )
        let stereoFirst = try XCTUnwrap(validStereo.first)
        let mixedFormats = [
            firstValid,
            .init(
                sampleRate: sampleRate,
                frameCount: framesPerBuffer,
                channelCount: 1,
                storage: .int16Interleaved(validIntSamples)
            ),
            thirdValid,
        ]
        let sampleRateMismatch = [
            firstValid,
            .init(
                sampleRate: 44_100,
                frameCount: framesPerBuffer,
                channelCount: 1,
                storage: .float32Interleaved(validFloatSamples)
            ),
            thirdValid,
        ]
        let channelMismatch = [firstValid, stereoFirst, thirdValid]
        let layoutMismatch = [
            firstValid,
            try XCTUnwrap(validPlanarFloat.dropFirst().first),
            thirdValid,
        ]
        let rows: [InvalidAnalyzerRow] = [
            .init("empty buffer list", []),
            .init("negative frame", malformed(frameCount: -1, storage: .float32Interleaved([]))),
            .init("zero frame", malformed(frameCount: 0, storage: .float32Interleaved([]))),
            .init("negative channel", malformed(channelCount: -1, storage: .float32Interleaved([]))),
            .init("zero channel", malformed(channelCount: 0, storage: .float32Interleaved([]))),
            .init(
                "more than stereo channels",
                malformed(
                    channelCount: 3,
                    storage: .float32Interleaved(Array(repeating: 0, count: 24_000))
                )
            ),
            .init("zero rate", malformed(sampleRate: 0, storage: .float32Interleaved(validFloatSamples))),
            .init("negative rate", malformed(sampleRate: -1, storage: .float32Interleaved(validFloatSamples))),
            .init("NaN rate", malformed(sampleRate: .nan, storage: .float32Interleaved(validFloatSamples))),
            .init("infinite rate", malformed(sampleRate: .infinity, storage: .float32Interleaved(validFloatSamples))),
            .init("NaN sample", malformed(storage: .float32Interleaved(nanSamples))),
            .init("infinite sample", malformed(storage: .float32Interleaved(infiniteSamples))),
            .init(
                "Float interleaved shape",
                malformed(channelCount: 2, storage: .float32Interleaved(Array(validFloatSamples.dropLast())))
            ),
            .init(
                "Int interleaved shape",
                malformed(channelCount: 2, storage: .int16Interleaved(validIntSamples + [0]))
            ),
            .init(
                "Float planar outer shape",
                malformed(channelCount: 2, storage: .float32NonInterleaved([validFloatSamples]))
            ),
            .init(
                "Float planar inner shape",
                malformed(
                    channelCount: 2,
                    storage: .float32NonInterleaved([
                        validFloatSamples,
                        Array(validFloatSamples.dropLast()),
                    ])
                )
            ),
            .init(
                "Int planar outer shape",
                malformed(channelCount: 2, storage: .int16NonInterleaved([validIntSamples]))
            ),
            .init(
                "Int planar inner shape",
                malformed(
                    channelCount: 2,
                    storage: .int16NonInterleaved([validIntSamples, Array(validIntSamples.dropLast())])
                )
            ),
            .init(
                "Float planar NaN",
                malformed(storage: .float32NonInterleaved([nanSamples]))
            ),
            .init(
                "Float planar infinity",
                malformed(storage: .float32NonInterleaved([infiniteSamples]))
            ),
            .init(
                "overflow shape",
                malformed(
                    frameCount: .max,
                    channelCount: 2,
                    storage: .float32Interleaved([])
                )
            ),
            .init("mixed Float and Int buffers", mixedFormats),
            .init("cross-buffer sample rate", sampleRateMismatch),
            .init("cross-buffer channel count", channelMismatch),
            .init("cross-buffer layout", layoutMismatch),
            .init("expected zero", valid, expected: 0, competitors: [competitor]),
            .init("expected negative", valid, expected: -1, competitors: [competitor]),
            .init("expected NaN", valid, expected: .nan, competitors: [competitor]),
            .init("expected infinity", valid, expected: .infinity, competitors: [competitor]),
            .init("expected Nyquist", valid, expected: sampleRate / 2, competitors: [competitor]),
            .init("empty competitor", valid, expected: target, competitors: []),
            .init("competitor zero", valid, expected: target, competitors: [0]),
            .init("competitor negative", valid, expected: target, competitors: [-1]),
            .init("competitor NaN", valid, expected: target, competitors: [.nan]),
            .init("competitor infinity", valid, expected: target, competitors: [.infinity]),
            .init("competitor Nyquist", valid, expected: target, competitors: [sampleRate / 2]),
            .init("competitor equals expected", valid, expected: target, competitors: [target]),
            .init("duplicate competitor", valid, expected: target, competitors: [competitor, competitor]),
        ]

        for row in rows {
            let result = analyze(
                row.buffers,
                expectedFrequencyHz: row.expectedFrequencyHz ?? target,
                competingFrequenciesHz: row.competingFrequenciesHz ?? [competitor]
            )
            XCTAssertEqual(result.verdict, .invalidInput, row.name)
        }
    }

    func testAnalysisDoesNotMutateInputBuffers() {
        let target = exactBin(300)
        let competitor = exactBin(200)
        let buffers = makeBuffers(
            channels: [[.init(frequencyHz: target, peakAmplitude: 0.30)]],
            storage: .float32NonInterleaved
        )
        let snapshot = buffers

        _ = analyze(
            buffers,
            expectedFrequencyHz: target,
            competingFrequenciesHz: [competitor]
        )

        XCTAssertEqual(buffers, snapshot)
    }

    private func analyze(
        _ buffers: [FrequencyAnalyzer.PCMBuffer],
        expectedFrequencyHz: Double,
        competingFrequenciesHz: [Double]
    ) -> FrequencyAnalyzer.Analysis {
        FrequencyAnalyzer(requirements: .fixtureAcceptance).analyze(
            buffers: buffers,
            expectedFrequencyHz: expectedFrequencyHz,
            competingFrequenciesHz: competingFrequenciesHz
        )
    }

    private func makeBuffers(
        channels: [[SyntheticTone]],
        storage: SyntheticPCMStorage,
        bufferFrameCounts: [Int]? = nil
    ) -> [FrequencyAnalyzer.PCMBuffer] {
        let frameCounts = bufferFrameCounts ?? Array(repeating: framesPerBuffer, count: 3)
        let channelCount = max(1, channels.count)
        var frameOffset = 0
        return frameCounts.map { frameCount in
            defer { frameOffset += frameCount }
            let floatChannels = (0..<channelCount).map { channelIndex in
                let tones = channels.indices.contains(channelIndex) ? channels[channelIndex] : []
                return (0..<frameCount).map { localFrame in
                    let time = Double(frameOffset + localFrame) / sampleRate
                    return Float(
                        tones.reduce(0.0) { partial, tone in
                            partial + tone.peakAmplitude
                                * sin(2 * .pi * tone.frequencyHz * time)
                        }
                    )
                }
            }
            return .init(
                sampleRate: sampleRate,
                frameCount: frameCount,
                channelCount: channelCount,
                storage: makeStorage(floatChannels, layout: storage)
            )
        }
    }

    private func syntheticMonoSamples(
        tones: [SyntheticTone],
        frameCount: Int
    ) -> [Float] {
        (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            return Float(
                tones.reduce(0.0) { partial, tone in
                    partial + tone.peakAmplitude
                        * sin(2 * .pi * tone.frequencyHz * time)
                }
            )
        }
    }

    private func buffersFromMono(_ samples: [Float]) -> [FrequencyAnalyzer.PCMBuffer] {
        precondition(samples.count == framesPerBuffer * 3)
        return (0..<3).map { index in
            let range = (index * framesPerBuffer)..<((index + 1) * framesPerBuffer)
            return .init(
                sampleRate: sampleRate,
                frameCount: framesPerBuffer,
                channelCount: 1,
                storage: .float32Interleaved(Array(samples[range]))
            )
        }
    }

    private func makeStorage(
        _ channels: [[Float]],
        layout: SyntheticPCMStorage
    ) -> FrequencyAnalyzer.PCMBuffer.Storage {
        let frameCount = channels.first?.count ?? 0
        switch layout {
        case .float32Interleaved:
            return .float32Interleaved(interleave(channels, frameCount: frameCount))
        case .float32NonInterleaved:
            return .float32NonInterleaved(channels)
        case .int16Interleaved:
            return .int16Interleaved(
                interleave(channels, frameCount: frameCount).map(quantize)
            )
        case .int16NonInterleaved:
            return .int16NonInterleaved(channels.map { $0.map(quantize) })
        }
    }

    private func interleave(_ channels: [[Float]], frameCount: Int) -> [Float] {
        (0..<frameCount).flatMap { frame in
            channels.indices.compactMap { channel in
                channels[channel].indices.contains(frame) ? channels[channel][frame] : nil
            }
        }
    }

    private func floatInterleavedSamples(
        from buffer: FrequencyAnalyzer.PCMBuffer
    ) -> [Float] {
        guard case let .float32Interleaved(samples) = buffer.storage else {
            XCTFail("Expected Float32 interleaved fixture")
            return []
        }
        return samples
    }

    private func quantize(_ sample: Float) -> Int16 {
        let bounded = min(1, max(-1, sample))
        return Int16((bounded * Float(Int16.max)).rounded())
    }

    private func peakAmplitude(forRMSDecibels decibels: Double) -> Double {
        pow(10, decibels / 20) * sqrt(2)
    }

    private func exactBin(_ index: Double) -> Double {
        index * sampleRate / Double(analysisFrameCount)
    }

    private func deterministicNoise(count: Int, peakAmplitude: Float) -> [Float] {
        var state: UInt64 = 0xD37E_2A19_7B41_C005
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float((state >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF)
            return (unit * 2 - 1) * peakAmplitude
        }
    }
}

private enum IndependentAnalysisWindow {
    case hann
    case rectangular
}

private struct IndependentBandReference {
    let expectedBandPowerDecibels: Double
    let competitorBandPowerDecibels: Double

    var separationDecibels: Double {
        expectedBandPowerDecibels - competitorBandPowerDecibels
    }
}

private enum IndependentBandReferenceError: Error {
    case invalidInput
    case invalidPower
}

private func independentCenteredBandReference(
    samples: [Float],
    analysisFrameCount: Int,
    expectedBins: ClosedRange<Int>,
    competitorBins: ClosedRange<Int>,
    window: IndependentAnalysisWindow
) throws -> IndependentBandReference {
    guard analysisFrameCount > 1,
        samples.count >= analysisFrameCount,
        expectedBins.lowerBound >= 0,
        competitorBins.lowerBound >= 0
    else { throw IndependentBandReferenceError.invalidInput }
    let start = (samples.count - analysisFrameCount) / 2
    let end = start + analysisFrameCount
    guard start >= 0, end <= samples.count else {
        throw IndependentBandReferenceError.invalidInput
    }
    let centeredSlice = samples[start..<end].map(Double.init)
    let mean = centeredSlice.reduce(0, +) / Double(analysisFrameCount)
    let weights = (0..<analysisFrameCount).map { index -> Double in
        switch window {
        case .hann:
            return 0.5 - 0.5 * cos(
                2 * .pi * Double(index) / Double(analysisFrameCount - 1)
            )
        case .rectangular:
            return 1
        }
    }
    let windowed = zip(centeredSlice, weights).map { sample, weight in
        (sample - mean) * weight
    }
    let coherentGain = weights.reduce(0, +)
    guard coherentGain > 0 else { throw IndependentBandReferenceError.invalidPower }

    func normalizedBandPower(_ bins: ClosedRange<Int>) -> Double {
        let rawPower = bins.reduce(0.0) { partial, bin in
            var real = 0.0
            var imaginary = 0.0
            for (index, sample) in windowed.enumerated() {
                let phase = 2 * .pi * Double(bin * index) / Double(analysisFrameCount)
                real += sample * cos(phase)
                imaginary -= sample * sin(phase)
            }
            return partial + real * real + imaginary * imaginary
        }
        return 4 * rawPower / (coherentGain * coherentGain)
    }

    let expectedPower = normalizedBandPower(expectedBins)
    let competitorPower = normalizedBandPower(competitorBins)
    guard expectedPower.isFinite,
        competitorPower.isFinite,
        expectedPower > 0,
        competitorPower > 0
    else { throw IndependentBandReferenceError.invalidPower }
    return IndependentBandReference(
        expectedBandPowerDecibels: 10 * log10(expectedPower),
        competitorBandPowerDecibels: 10 * log10(competitorPower)
    )
}

private struct InvalidAnalyzerRow {
    let name: String
    let buffers: [FrequencyAnalyzer.PCMBuffer]
    let expectedFrequencyHz: Double?
    let competingFrequenciesHz: [Double]?

    init(
        _ name: String,
        _ buffers: [FrequencyAnalyzer.PCMBuffer],
        expected: Double? = nil,
        competitors: [Double]? = nil
    ) {
        self.name = name
        self.buffers = buffers
        expectedFrequencyHz = expected
        competingFrequenciesHz = competitors
    }
}

private struct SyntheticTone {
    let frequencyHz: Double
    let peakAmplitude: Double
}

private enum SyntheticPCMStorage {
    case float32Interleaved
    case float32NonInterleaved
    case int16Interleaved
    case int16NonInterleaved
}
