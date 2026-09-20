#if DEBUG
import Accelerate
import Foundation

struct FrequencyAnalyzer: Sendable {
    struct Requirements: Equatable, Sendable {
        let minimumBufferCount: Int
        let minimumDurationSeconds: Double
        let minimumRMSDecibels: Double
        let frequencyToleranceFraction: Double
        let minimumExpectedToneSeparationDecibels: Double
        let analysisWindowIdentifier: WindowIdentifier

        static let fixtureAcceptance = Requirements(
            minimumBufferCount: 3,
            minimumDurationSeconds: 0.5,
            minimumRMSDecibels: -45,
            frequencyToleranceFraction: 0.03,
            minimumExpectedToneSeparationDecibels: 6,
            analysisWindowIdentifier: .hann
        )
    }

    enum WindowIdentifier: String, Equatable, Sendable {
        case hann
    }

    struct PCMBuffer: Equatable, Sendable {
        enum Storage: Equatable, Sendable {
            case float32Interleaved([Float])
            case float32NonInterleaved([[Float]])
            case int16Interleaved([Int16])
            case int16NonInterleaved([[Int16]])
        }

        let sampleRate: Double
        let frameCount: Int
        let channelCount: Int
        let storage: Storage
    }

    enum Verdict: Equatable, Sendable {
        case verified
        case silence
        case insufficientEvidence
        case invalidInput
    }

    struct Analysis: Equatable, Sendable {
        let verdict: Verdict
        let bufferCount: Int
        let analyzedDurationSeconds: Double
        let analysisStartFrame: Int
        let analysisFrameCount: Int
        let rmsDecibels: Double
        let dominantFrequencyHz: Double
        let expectedBandPowerDecibels: Double
        let strongestCompetingBandPowerDecibels: Double
        let expectedToneSeparationDecibels: Double
        let windowIdentifier: WindowIdentifier
    }

    let requirements: Requirements

    init(requirements: Requirements) {
        self.requirements = requirements
    }

    func analyze(
        buffers: [PCMBuffer],
        expectedFrequencyHz: Double,
        competingFrequenciesHz: [Double]
    ) -> Analysis {
        guard requirementsAreValid,
              let validated = validate(
                  buffers: buffers,
                  expectedFrequencyHz: expectedFrequencyHz,
                  competingFrequenciesHz: competingFrequenciesHz
              )
        else {
            return emptyAnalysis(
                verdict: .invalidInput,
                bufferCount: buffers.count
            )
        }

        let analysisFrameCount = largestPowerOfTwo(notExceeding: validated.totalFrameCount)
        let analysisStartFrame = (validated.totalFrameCount - analysisFrameCount) / 2
        let duration = Double(validated.totalFrameCount) / validated.sampleRate

        guard buffers.count >= requirements.minimumBufferCount,
              duration >= requirements.minimumDurationSeconds,
              analysisFrameCount >= 2
        else {
            return emptyAnalysis(
                verdict: .insufficientEvidence,
                bufferCount: buffers.count,
                analyzedDurationSeconds: duration,
                analysisStartFrame: analysisStartFrame,
                analysisFrameCount: analysisFrameCount
            )
        }

        let monoSamples = normalizeAndDownmix(buffers: buffers)
        let analysisEndFrame = analysisStartFrame + analysisFrameCount
        guard analysisStartFrame >= 0,
              analysisEndFrame <= monoSamples.count
        else {
            return emptyAnalysis(
                verdict: .invalidInput,
                bufferCount: buffers.count
            )
        }

        var centeredSamples = Array(monoSamples[analysisStartFrame..<analysisEndFrame])
        let mean = centeredSamples.reduce(0, +) / Double(analysisFrameCount)
        for index in centeredSamples.indices {
            centeredSamples[index] -= mean
        }

        let squaredSum = centeredSamples.reduce(0) { partial, sample in
            partial + sample * sample
        }
        let rms = sqrt(squaredSum / Double(analysisFrameCount))
        let rmsDecibels = rms > 0 ? 20 * log10(rms) : -.infinity
        let baseAnalysis = Analysis(
            verdict: .insufficientEvidence,
            bufferCount: buffers.count,
            analyzedDurationSeconds: duration,
            analysisStartFrame: analysisStartFrame,
            analysisFrameCount: analysisFrameCount,
            rmsDecibels: rmsDecibels,
            dominantFrequencyHz: 0,
            expectedBandPowerDecibels: -.infinity,
            strongestCompetingBandPowerDecibels: -.infinity,
            expectedToneSeparationDecibels: -.infinity,
            windowIdentifier: requirements.analysisWindowIdentifier
        )

        // Exact silence, antiphase cancellation, and a removed DC signal all
        // land at numerical zero. A merely quiet signal remains evidence that
        // fails the separately locked -45 dBFS acceptance threshold.
        guard rms > Self.silenceAmplitudeEpsilon else {
            return replacingVerdict(in: baseAnalysis, with: .silence)
        }
        guard rmsDecibels + Self.thresholdEpsilon
                >= requirements.minimumRMSDecibels
        else {
            return baseAnalysis
        }

        let hannWindow = makeHannWindow(count: analysisFrameCount)
        let coherentGain = hannWindow.reduce(0, +)
        guard coherentGain > 0 else {
            return replacingVerdict(in: baseAnalysis, with: .invalidInput)
        }
        for index in centeredSamples.indices {
            centeredSamples[index] *= hannWindow[index]
        }

        guard let spectrum = spectrum(of: centeredSamples) else {
            return baseAnalysis
        }
        let binWidth = validated.sampleRate / Double(analysisFrameCount)
        let dominantBin = dominantBin(in: spectrum)
        let dominantFrequencyHz = Double(dominantBin) * binWidth

        // For a between-bin tone, center its three-bin band on the nominal
        // rounded bin. Once an observed tone is farther away, center on the
        // observed dominant bin so the +/-3% boundary remains measurable.
        let nominalExpectedBin = nearestUsableBin(
            for: expectedFrequencyHz,
            binWidth: binWidth,
            spectrumCount: spectrum.count
        )
        let observedExpectedBin = abs(dominantBin - nominalExpectedBin) <= 1
            ? nominalExpectedBin
            : dominantBin
        let expectedPower = normalizedBandPower(
            centeredAt: observedExpectedBin,
            spectrum: spectrum,
            coherentGain: coherentGain
        )
        let competitorPowers = competingFrequenciesHz.map { frequency in
            normalizedBandPower(
                centeredAt: nearestUsableBin(
                    for: frequency,
                    binWidth: binWidth,
                    spectrumCount: spectrum.count
                ),
                spectrum: spectrum,
                coherentGain: coherentGain
            )
        }
        let expectedPowerDecibels = powerDecibels(expectedPower)
        let strongestCompetingPowerDecibels = competitorPowers
            .map(powerDecibels)
            .max() ?? -.infinity
        let separationDecibels = expectedPowerDecibels
            - strongestCompetingPowerDecibels

        let measuredAnalysis = Analysis(
            verdict: .insufficientEvidence,
            bufferCount: buffers.count,
            analyzedDurationSeconds: duration,
            analysisStartFrame: analysisStartFrame,
            analysisFrameCount: analysisFrameCount,
            rmsDecibels: rmsDecibels,
            dominantFrequencyHz: dominantFrequencyHz,
            expectedBandPowerDecibels: expectedPowerDecibels,
            strongestCompetingBandPowerDecibels: strongestCompetingPowerDecibels,
            expectedToneSeparationDecibels: separationDecibels,
            windowIdentifier: requirements.analysisWindowIdentifier
        )
        let relativeFrequencyError = abs(dominantFrequencyHz - expectedFrequencyHz)
            / expectedFrequencyHz
        guard relativeFrequencyError
                <= requirements.frequencyToleranceFraction + Self.thresholdEpsilon,
              separationDecibels + Self.thresholdEpsilon
                >= requirements.minimumExpectedToneSeparationDecibels
        else {
            return measuredAnalysis
        }
        return replacingVerdict(in: measuredAnalysis, with: .verified)
    }

    private static let silenceAmplitudeEpsilon = 1e-12
    private static let thresholdEpsilon = 1e-6

    private var requirementsAreValid: Bool {
        requirements.minimumBufferCount > 0
            && requirements.minimumDurationSeconds.isFinite
            && requirements.minimumDurationSeconds >= 0
            && requirements.minimumRMSDecibels.isFinite
            && requirements.frequencyToleranceFraction.isFinite
            && requirements.frequencyToleranceFraction >= 0
            && requirements.minimumExpectedToneSeparationDecibels.isFinite
    }

    private func validate(
        buffers: [PCMBuffer],
        expectedFrequencyHz: Double,
        competingFrequenciesHz: [Double]
    ) -> ValidatedInput? {
        guard let first = buffers.first,
              first.sampleRate.isFinite,
              first.sampleRate > 0
        else { return nil }

        let sampleRate = first.sampleRate
        let nyquist = sampleRate / 2
        guard expectedFrequencyHz.isFinite,
              expectedFrequencyHz > 0,
              expectedFrequencyHz < nyquist,
              !competingFrequenciesHz.isEmpty
        else { return nil }

        var uniqueCompetitors = Set<Double>()
        for frequency in competingFrequenciesHz {
            guard frequency.isFinite,
                  frequency > 0,
                  frequency < nyquist,
                  frequency != expectedFrequencyHz,
                  uniqueCompetitors.insert(frequency).inserted
            else { return nil }
        }

        let expectedFormat = first.storage.format
        let expectedChannelCount = first.channelCount
        var totalFrameCount = 0

        // This complete validation pass precedes every sample subscript used
        // by normalization and downmixing.
        for buffer in buffers {
            guard buffer.sampleRate.isFinite,
                  buffer.sampleRate == sampleRate,
                  buffer.frameCount > 0,
                  (1...2).contains(buffer.channelCount),
                  buffer.channelCount == expectedChannelCount,
                  buffer.storage.format == expectedFormat,
                  buffer.storage.hasValidShape(
                      frameCount: buffer.frameCount,
                      channelCount: buffer.channelCount
                  ),
                  buffer.storage.containsOnlyFiniteSamples
            else { return nil }

            let (newTotal, overflow) = totalFrameCount.addingReportingOverflow(
                buffer.frameCount
            )
            guard !overflow else { return nil }
            totalFrameCount = newTotal
        }
        return ValidatedInput(
            sampleRate: sampleRate,
            totalFrameCount: totalFrameCount
        )
    }

    private func normalizeAndDownmix(buffers: [PCMBuffer]) -> [Double] {
        let totalFrameCount = buffers.reduce(0) { $0 + $1.frameCount }
        var monoSamples = [Double]()
        monoSamples.reserveCapacity(totalFrameCount)

        for buffer in buffers {
            let divisor = Double(buffer.channelCount)
            switch buffer.storage {
            case let .float32Interleaved(samples):
                for frame in 0..<buffer.frameCount {
                    let offset = frame * buffer.channelCount
                    var channelSum = 0.0
                    for channel in 0..<buffer.channelCount {
                        channelSum += Double(samples[offset + channel])
                    }
                    monoSamples.append(channelSum / divisor)
                }
            case let .float32NonInterleaved(channels):
                for frame in 0..<buffer.frameCount {
                    var channelSum = 0.0
                    for channel in 0..<buffer.channelCount {
                        channelSum += Double(channels[channel][frame])
                    }
                    monoSamples.append(channelSum / divisor)
                }
            case let .int16Interleaved(samples):
                for frame in 0..<buffer.frameCount {
                    let offset = frame * buffer.channelCount
                    var channelSum = 0.0
                    for channel in 0..<buffer.channelCount {
                        channelSum += normalizedInt16(samples[offset + channel])
                    }
                    monoSamples.append(channelSum / divisor)
                }
            case let .int16NonInterleaved(channels):
                for frame in 0..<buffer.frameCount {
                    var channelSum = 0.0
                    for channel in 0..<buffer.channelCount {
                        channelSum += normalizedInt16(channels[channel][frame])
                    }
                    monoSamples.append(channelSum / divisor)
                }
            }
        }
        return monoSamples
    }

    private func normalizedInt16(_ sample: Int16) -> Double {
        Double(sample) / 32_768
    }

    private func largestPowerOfTwo(notExceeding value: Int) -> Int {
        guard value > 0 else { return 0 }
        var result = 1
        while result <= value / 2 {
            result *= 2
        }
        return result
    }

    private func makeHannWindow(count: Int) -> [Double] {
        guard count > 1 else { return Array(repeating: 1, count: count) }
        let denominator = Double(count - 1)
        return (0..<count).map { index in
            0.5 - 0.5 * cos(2 * .pi * Double(index) / denominator)
        }
    }

    private func spectrum(of samples: [Double]) -> Spectrum? {
        let count = samples.count
        guard count >= 2,
              let setup = vDSP_DFT_zop_CreateSetupD(
                  nil,
                  vDSP_Length(count),
                  vDSP_DFT_Direction.FORWARD
              )
        else { return nil }
        defer { vDSP_DFT_DestroySetupD(setup) }

        let imaginaryInput = [Double](repeating: 0, count: count)
        var realOutput = [Double](repeating: 0, count: count)
        var imaginaryOutput = [Double](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { realInput in
            imaginaryInput.withUnsafeBufferPointer { imaginaryInput in
                realOutput.withUnsafeMutableBufferPointer { realOutput in
                    imaginaryOutput.withUnsafeMutableBufferPointer { imaginaryOutput in
                        guard let realInputBase = realInput.baseAddress,
                              let imaginaryInputBase = imaginaryInput.baseAddress,
                              let realOutputBase = realOutput.baseAddress,
                              let imaginaryOutputBase = imaginaryOutput.baseAddress
                        else { return }
                        vDSP_DFT_ExecuteD(
                            setup,
                            realInputBase,
                            imaginaryInputBase,
                            realOutputBase,
                            imaginaryOutputBase
                        )
                    }
                }
            }
        }
        let usableCount = count / 2
        return Spectrum(
            real: Array(realOutput[..<usableCount]),
            imaginary: Array(imaginaryOutput[..<usableCount])
        )
    }

    private func dominantBin(in spectrum: Spectrum) -> Int {
        guard spectrum.count > 1 else { return 0 }
        var strongestBin = 1
        var strongestPower = spectrum.power(at: strongestBin)
        if spectrum.count > 2 {
            for bin in 2..<spectrum.count {
                let power = spectrum.power(at: bin)
                if power > strongestPower {
                    strongestPower = power
                    strongestBin = bin
                }
            }
        }
        return strongestBin
    }

    private func nearestUsableBin(
        for frequency: Double,
        binWidth: Double,
        spectrumCount: Int
    ) -> Int {
        let bin = Int((frequency / binWidth).rounded())
        return min(max(1, bin), max(1, spectrumCount - 1))
    }

    private func normalizedBandPower(
        centeredAt centerBin: Int,
        spectrum: Spectrum,
        coherentGain: Double
    ) -> Double {
        guard spectrum.count > 1, coherentGain > 0 else { return 0 }
        let lowerBound = max(1, centerBin - 1)
        let upperBound = min(spectrum.count - 1, centerBin + 1)
        guard lowerBound <= upperBound else { return 0 }
        var rawPower = 0.0
        for bin in lowerBound...upperBound {
            rawPower += spectrum.power(at: bin)
        }
        return 4 * rawPower / (coherentGain * coherentGain)
    }

    private func powerDecibels(_ power: Double) -> Double {
        guard power.isFinite, power > 0 else { return -.infinity }
        return 10 * log10(power)
    }

    private func replacingVerdict(
        in analysis: Analysis,
        with verdict: Verdict
    ) -> Analysis {
        Analysis(
            verdict: verdict,
            bufferCount: analysis.bufferCount,
            analyzedDurationSeconds: analysis.analyzedDurationSeconds,
            analysisStartFrame: analysis.analysisStartFrame,
            analysisFrameCount: analysis.analysisFrameCount,
            rmsDecibels: analysis.rmsDecibels,
            dominantFrequencyHz: analysis.dominantFrequencyHz,
            expectedBandPowerDecibels: analysis.expectedBandPowerDecibels,
            strongestCompetingBandPowerDecibels: analysis.strongestCompetingBandPowerDecibels,
            expectedToneSeparationDecibels: analysis.expectedToneSeparationDecibels,
            windowIdentifier: analysis.windowIdentifier
        )
    }

    private func emptyAnalysis(
        verdict: Verdict,
        bufferCount: Int,
        analyzedDurationSeconds: Double = 0,
        analysisStartFrame: Int = 0,
        analysisFrameCount: Int = 0
    ) -> Analysis {
        Analysis(
            verdict: verdict,
            bufferCount: bufferCount,
            analyzedDurationSeconds: analyzedDurationSeconds,
            analysisStartFrame: analysisStartFrame,
            analysisFrameCount: analysisFrameCount,
            rmsDecibels: -.infinity,
            dominantFrequencyHz: 0,
            expectedBandPowerDecibels: -.infinity,
            strongestCompetingBandPowerDecibels: -.infinity,
            expectedToneSeparationDecibels: -.infinity,
            windowIdentifier: requirements.analysisWindowIdentifier
        )
    }
}

private extension FrequencyAnalyzer {
    struct ValidatedInput {
        let sampleRate: Double
        let totalFrameCount: Int
    }

    struct Spectrum {
        let real: [Double]
        let imaginary: [Double]

        var count: Int { real.count }

        func power(at bin: Int) -> Double {
            let realValue = real[bin]
            let imaginaryValue = imaginary[bin]
            return realValue * realValue + imaginaryValue * imaginaryValue
        }
    }

    enum StorageFormat: Equatable {
        case float32Interleaved
        case float32NonInterleaved
        case int16Interleaved
        case int16NonInterleaved
    }
}

private extension FrequencyAnalyzer.PCMBuffer.Storage {
    var format: FrequencyAnalyzer.StorageFormat {
        switch self {
        case .float32Interleaved:
            return .float32Interleaved
        case .float32NonInterleaved:
            return .float32NonInterleaved
        case .int16Interleaved:
            return .int16Interleaved
        case .int16NonInterleaved:
            return .int16NonInterleaved
        }
    }

    func hasValidShape(frameCount: Int, channelCount: Int) -> Bool {
        let (interleavedCount, overflow) = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        guard !overflow else { return false }

        switch self {
        case let .float32Interleaved(samples):
            return samples.count == interleavedCount
        case let .int16Interleaved(samples):
            return samples.count == interleavedCount
        case let .float32NonInterleaved(channels):
            return channels.count == channelCount
                && channels.allSatisfy { $0.count == frameCount }
        case let .int16NonInterleaved(channels):
            return channels.count == channelCount
                && channels.allSatisfy { $0.count == frameCount }
        }
    }

    var containsOnlyFiniteSamples: Bool {
        switch self {
        case let .float32Interleaved(samples):
            return samples.allSatisfy(\.isFinite)
        case let .float32NonInterleaved(channels):
            return channels.allSatisfy { $0.allSatisfy(\.isFinite) }
        case .int16Interleaved, .int16NonInterleaved:
            return true
        }
    }
}
#endif
