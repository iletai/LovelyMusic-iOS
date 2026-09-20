import CryptoKit
import Foundation
import os
import Security

// MARK: - Fail-closed remote controls

struct PlaybackFeatureSnapshot: Equatable, Sendable {
    static let supportedLoaderVersion = 1
    static let supportedHeaderSchemaVersion = 1

    let rangeStreamingV1: Bool
    let cohortPercent: Int
    let boundedPreloadV1: Bool
    let killSwitch: Bool
    let killSwitchEpoch: UInt64
    let loaderVersion: Int
    let headerSchemaVersion: Int

    static let failClosed = Self(
        rangeStreamingV1: false,
        cohortPercent: 0,
        boundedPreloadV1: false,
        killSwitch: true,
        killSwitchEpoch: 0,
        loaderVersion: 0,
        headerSchemaVersion: 0
    )

    var hasSupportedSchema: Bool {
        loaderVersion == Self.supportedLoaderVersion
            && headerSchemaVersion == Self.supportedHeaderSchemaVersion
    }
}

final class PlaybackFeatureSnapshotStore: Sendable {
    private let state: OSAllocatedUnfairLock<PlaybackFeatureSnapshot>

    init(initial: PlaybackFeatureSnapshot = .failClosed) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func snapshot() -> PlaybackFeatureSnapshot {
        state.withLock { $0 }
    }

    func update(_ snapshot: PlaybackFeatureSnapshot) {
        state.withLock { $0 = snapshot }
    }
}

// MARK: - Stable privacy-preserving cohort

protocol PlaybackInstallIDStoring: Sendable {
    func readInstallID() throws -> Data?
    func writeInstallID(_ value: Data) throws
}

enum PlaybackInstallIDStorageError: Error, Sendable {
    case readFailed
    case writeFailed
    case generationFailed
}

final class KeychainPlaybackInstallIDStore: PlaybackInstallIDStoring, Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "com.lovelymusic.playback-cohort",
        account: String = "install-scoped-id-v1"
    ) {
        self.service = service
        self.account = account
    }

    func readInstallID() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PlaybackInstallIDStorageError.readFailed
        }
        return data
    }

    func writeInstallID(_ value: Data) throws {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData: value] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PlaybackInstallIDStorageError.writeFailed
        }

        var insert = lookup
        insert[kSecValueData] = value
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw PlaybackInstallIDStorageError.writeFailed
        }
    }
}

final class PlaybackCohortAssigner: Sendable, CustomStringConvertible {
    typealias InstallIDGenerator = @Sendable () throws -> Data
    typealias BucketProvider = @Sendable (Data, Int) -> Int

    private enum InstallIDState: Sendable {
        case unresolved
        case valid(Data)
        case failed
    }

    private static let installIDByteCount = 32
    private static let bucketCount = 10_000

    private let idStore: any PlaybackInstallIDStoring
    private let generateID: InstallIDGenerator
    private let bucketProvider: BucketProvider
    private let installIDState = OSAllocatedUnfairLock(initialState: InstallIDState.unresolved)

    init(
        idStore: any PlaybackInstallIDStoring = KeychainPlaybackInstallIDStore(),
        generateID: @escaping InstallIDGenerator = {
            try PlaybackCohortAssigner.generateRandomID()
        },
        bucketProvider: @escaping BucketProvider = { installID, policyVersion in
            PlaybackCohortAssigner.hashBucket(
                installID: installID,
                policyVersion: policyVersion
            )
        }
    ) {
        self.idStore = idStore
        self.generateID = generateID
        self.bucketProvider = bucketProvider
    }

    convenience init(
        idStore: any PlaybackInstallIDStoring,
        bucketProvider: @escaping BucketProvider
    ) {
        self.init(
            idStore: idStore,
            generateID: { try PlaybackCohortAssigner.generateRandomID() },
            bucketProvider: bucketProvider
        )
    }

    var description: String { "PlaybackCohortAssigner" }

    func isEligible(for controls: PlaybackFeatureSnapshot) -> Bool {
        guard controls.rangeStreamingV1,
            !controls.killSwitch,
            controls.hasSupportedSchema,
            (0...100).contains(controls.cohortPercent)
        else {
            return false
        }
        guard controls.cohortPercent > 0 else { return false }
        guard let bucket = bucket(policyVersion: controls.loaderVersion) else { return false }
        return bucket < controls.cohortPercent * 100
    }

    func bucket(policyVersion: Int) -> Int? {
        guard policyVersion > 0, let installID = installID() else { return nil }
        let bucket = bucketProvider(installID, policyVersion)
        guard (0..<Self.bucketCount).contains(bucket) else { return nil }
        return bucket
    }

    private func installID() -> Data? {
        installIDState.withLock { state in
            switch state {
            case .valid(let value):
                return value
            case .failed:
                return nil
            case .unresolved:
                do {
                    if let stored = try idStore.readInstallID() {
                        guard stored.count == Self.installIDByteCount else {
                            state = .failed
                            return nil
                        }
                        state = .valid(stored)
                        return stored
                    }

                    let generated = try generateID()
                    guard generated.count == Self.installIDByteCount else {
                        state = .failed
                        return nil
                    }
                    try idStore.writeInstallID(generated)
                    state = .valid(generated)
                    return generated
                } catch {
                    state = .failed
                    return nil
                }
            }
        }
    }

    private static func generateRandomID() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: installIDByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PlaybackInstallIDStorageError.generationFailed
        }
        return Data(bytes)
    }

    private static func hashBucket(installID: Data, policyVersion: Int) -> Int {
        var input = Data("com.lovelymusic.playback-cohort-v1".utf8)
        input.append(0)
        input.append(Data(String(policyVersion).utf8))
        input.append(0)
        input.append(installID)
        let digest = SHA256.hash(data: input)
        let prefix = digest.prefix(8)
        let value = prefix.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return Int(value % UInt64(bucketCount))
    }
}

// MARK: - Structural capability registry

struct PlaybackCapabilityEnvironment: Equatable, Codable, Sendable {
    let appBuild: String
    let iOSBuild: String
    let deviceFamily: String
}

struct CapabilityKey: Hashable, Codable, Sendable {
    let appBuild: String
    let iOSBuild: String
    let deviceFamily: String
    let itag: Int
    let mimeType: String
    let codec: String
    let containerLayoutProfile: String
    let qualityTier: AudioQuality
    let headerSchemaVersion: Int
    let loaderVersion: Int
}

struct PlaybackCompatibilityProfile: Codable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let loaderVersion: Int
    let headerSchemaVersion: Int
    let validUntil: Date
    let supportedCapabilities: Set<CapabilityKey>
}

enum PlaybackCapabilityStatus: Equatable, Sendable {
    case unknown
    case supported
    case incompatible
}

enum ValidatedStructuralFailure: String, Codable, Sendable {
    case nonzeroRangeReturnedFullResponse
    case inconsistentContentRange
    case changedStrongValidator
    case malformedContainerLayout
    case decoderRejectedContainer
    case seekRestartedFromZero
    case avFoundationPlayerErrorMinus12371
    case avFoundationPlayerErrorMinus12864
    case seekCompletedWithoutResumedDecodedPCM

    var compatibilityDisposition: PlaybackCapabilityFailureDisposition {
        switch self {
        case .nonzeroRangeReturnedFullResponse,
            .inconsistentContentRange,
            .changedStrongValidator,
            .malformedContainerLayout,
            .decoderRejectedContainer,
            .seekRestartedFromZero,
            .avFoundationPlayerErrorMinus12371,
            .avFoundationPlayerErrorMinus12864,
            .seekCompletedWithoutResumedDecodedPCM:
            return .structuralIncompatibility
        }
    }
}

struct ValidatedTransientHTTP5xx: Equatable, Sendable {
    let statusCode: Int

    init?(statusCode: Int) {
        guard (500...599).contains(statusCode) else {
            return nil
        }
        self.statusCode = statusCode
    }
}

enum PlaybackCapabilityFailure: Equatable, Sendable {
    case timeout
    case validatedHTTP5xx(ValidatedTransientHTTP5xx)
    case temporaryConnectivityLoss
    case cancelled
    case backgroundSuspension
    case networkPolicyDenied
    case userDeclined
    case validatedStructural(ValidatedStructuralFailure)

    var compatibilityDisposition: PlaybackCapabilityFailureDisposition {
        switch self {
        case .validatedStructural(let failure):
            return failure.compatibilityDisposition
        case .timeout,
            .validatedHTTP5xx,
            .temporaryConnectivityLoss,
            .cancelled,
            .backgroundSuspension:
            return .transient
        case .networkPolicyDenied, .userDeclined:
            return .policy
        }
    }
}

enum PlaybackCapabilityFailureDisposition: Equatable, Sendable {
    case structuralIncompatibility
    case transient
    case policy
}

enum PlaybackCapabilityOutcome: Equatable, Sendable {
    case success
    case failure(PlaybackCapabilityFailure)
}

final class PlaybackCapabilityRegistry: Sendable {
    private let profile: PlaybackCompatibilityProfile?
    private let now: @Sendable () -> Date
    private let incompatible = OSAllocatedUnfairLock(initialState: Set<CapabilityKey>())

    init(
        profile: PlaybackCompatibilityProfile?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profile = profile
        self.now = now
    }

    func status(
        for key: CapabilityKey,
        controls: PlaybackFeatureSnapshot
    ) -> PlaybackCapabilityStatus {
        if incompatible.withLock({ $0.contains(key) }) {
            return .incompatible
        }
        guard controls.rangeStreamingV1,
            !controls.killSwitch,
            controls.hasSupportedSchema,
            let profile,
            profile.schemaVersion == PlaybackCompatibilityProfile.supportedSchemaVersion,
            profile.loaderVersion == controls.loaderVersion,
            profile.headerSchemaVersion == controls.headerSchemaVersion,
            key.loaderVersion == controls.loaderVersion,
            key.headerSchemaVersion == controls.headerSchemaVersion,
            profile.validUntil > now(),
            profile.supportedCapabilities.contains(key)
        else {
            return .unknown
        }
        return .supported
    }

    func record(_ outcome: PlaybackCapabilityOutcome, for key: CapabilityKey) {
        guard case .failure(let failure) = outcome,
            failure.compatibilityDisposition == .structuralIncompatibility
        else {
            return
        }
        _ = incompatible.withLock { $0.insert(key) }
    }
}

// MARK: - Per-network quality settings

@MainActor
final class PlaybackQualitySettings {
    private enum Key {
        static let legacy = "audioQuality"
        static let migration = "audioQualityPerNetworkMigrationV1"
        static let wifi = "audioQualityWiFiV1"
        static let cellular = "audioQualityCellularV1"
        static let constrained = "audioQualityConstrainedV1"
        static let download = "audioQualityDownloadV1"
    }

    private let defaults: UserDefaults

    var wifi: AudioQuality {
        didSet { defaults.set(wifi.rawValue, forKey: Key.wifi) }
    }
    var cellular: AudioQuality {
        didSet { defaults.set(cellular.rawValue, forKey: Key.cellular) }
    }
    var constrained: AudioQuality {
        didSet { defaults.set(constrained.rawValue, forKey: Key.constrained) }
    }
    var download: AudioQuality {
        didSet { defaults.set(download.rawValue, forKey: Key.download) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let migrationValue: AudioQuality?
        if !defaults.bool(forKey: Key.migration),
            let legacy = defaults.string(forKey: Key.legacy).flatMap(AudioQuality.init(rawValue:))
        {
            migrationValue = legacy
        } else {
            migrationValue = nil
        }

        wifi = Self.quality(in: defaults, key: Key.wifi) ?? migrationValue ?? .high
        cellular = Self.quality(in: defaults, key: Key.cellular) ?? migrationValue ?? .medium
        constrained = Self.quality(in: defaults, key: Key.constrained) ?? migrationValue ?? .low
        download = Self.quality(in: defaults, key: Key.download) ?? migrationValue ?? .high

        defaults.set(wifi.rawValue, forKey: Key.wifi)
        defaults.set(cellular.rawValue, forKey: Key.cellular)
        defaults.set(constrained.rawValue, forKey: Key.constrained)
        defaults.set(download.rawValue, forKey: Key.download)
        defaults.set(true, forKey: Key.migration)
    }

    var legacyGlobalProjection: AudioQuality? {
        defaults.string(forKey: Key.legacy).flatMap(AudioQuality.init(rawValue:))
    }

    func reloadFromDefaults() {
        wifi = Self.quality(in: defaults, key: Key.wifi) ?? .high
        cellular = Self.quality(in: defaults, key: Key.cellular) ?? .medium
        constrained = Self.quality(in: defaults, key: Key.constrained) ?? .low
        download = Self.quality(in: defaults, key: Key.download) ?? .high
    }

    func effectiveStreamingQuality(
        for network: NetworkSnapshot,
        isPremium: Bool
    ) -> AudioQuality {
        let selected: AudioQuality
        if network.isConstrained || network.classification == .offline {
            selected = constrained
        } else if network.usesCellular || network.classification == .cellular {
            selected = cellular
        } else if network.usesWiFi && network.isExpensive {
            selected = constrained
        } else if network.usesWiFi && network.classification == .wifiUnconstrained {
            selected = wifi
        } else {
            // ponytail: unknown network — if we reached here a stream is being
            // requested so connectivity likely exists; use wifi quality to avoid
            // selecting HE-AAC (mp4a.40.5) which AVPlayer cannot open on some configs.
            selected = wifi
        }
        return Self.cap(selected, isPremium: isPremium)
    }

    func effectiveDownloadQuality(isPremium: Bool) -> AudioQuality {
        Self.cap(download, isPremium: isPremium)
    }

    func resetToDefaults() {
        wifi = .high
        cellular = .medium
        constrained = .low
        download = .high
    }

    private static func quality(in defaults: UserDefaults, key: String) -> AudioQuality? {
        defaults.string(forKey: key).flatMap(AudioQuality.init(rawValue:))
    }

    private static func cap(_ quality: AudioQuality, isPremium: Bool) -> AudioQuality {
        !isPremium && quality == .high ? .medium : quality
    }
}

// MARK: - Explicit quality wiring

@MainActor
enum PlaybackQualityWiring {
    typealias StreamURLResolver =
        (String) async throws -> (url: String, contentLength: Int64?)

    static func makePlaybackResolver(
        useCase: ResolveStreamUseCase,
        settings: PlaybackQualitySettings,
        networkSnapshot: @escaping () async -> NetworkSnapshot,
        isPremium: @escaping @MainActor () -> Bool,
        requestHeaders: [String: String] = [:]
    ) -> StreamURLResolver {
        { videoID in
            let network = await networkSnapshot()
            let quality = await MainActor.run {
                settings.reloadFromDefaults()
                return settings.effectiveStreamingQuality(
                    for: network,
                    isPremium: isPremium()
                )
            }
            return try await useCase.execute(
                videoId: videoID,
                quality: quality,
                requestHeaders: requestHeaders
            )
        }
    }

    static func makeExplicitDownloadResolver(
        useCase: ResolveStreamUseCase,
        capturedEffectiveQuality: AudioQuality,
        requestHeaders: [String: String] = [:]
    ) -> StreamURLResolver {
        { videoID in
            try await useCase.execute(
                videoId: videoID,
                quality: capturedEffectiveQuality,
                requestHeaders: requestHeaders
            )
        }
    }

    static func installExplicitDownloadResolverFactory(
        on manager: DownloadManager,
        useCase: ResolveStreamUseCase,
        settings: PlaybackQualitySettings,
        isPremium: @escaping @MainActor () -> Bool
    ) {
        manager.streamURLResolverFactory = {
            settings.reloadFromDefaults()
            let capturedQuality = settings.effectiveDownloadQuality(
                isPremium: isPremium()
            )
            return makeExplicitDownloadResolver(
                useCase: useCase,
                capturedEffectiveQuality: capturedQuality
            )
        }
    }
}
