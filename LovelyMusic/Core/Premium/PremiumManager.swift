import Foundation
import StoreKit
import UIKit

extension Notification.Name {
    static let premiumStatusChanged = Notification.Name("premiumStatusChanged")
}

@MainActor
@Observable
final class PremiumManager {
    // MARK: - Product IDs
    static let monthlyProductID = "com.lovelymusic.premium.monthly"
    static let yearlyProductID = "com.lovelymusic.premium.yearly"
    static let lifetimeProductID = "com.lovelymusic.premium.lifetime.v2"

    private static let allProductIDs: Set<String> = [
        monthlyProductID,
        yearlyProductID,
        lifetimeProductID,
    ]

    private static let premiumCacheKey = "isPremiumCached"
    private static let iCloudPremiumKey = "isPremiumSynced"
    private static let subscriptionExpirationKey = "subscriptionExpirationDate"
    private static let cacheTimestampKey = "isPremiumCacheTimestamp"
    private static let skipCountKey = "skipCount"
    private static let skipResetDateKey = "skipCountResetDate"
    private static let cacheMaxAge: TimeInterval = 86400  // 24 hours

    // MARK: - Free Tier Limits (defaults, overridden by CMS)
    private static let defaultFreeSkipLimit = 6
    private static let defaultFreeDownloadLimit = 5

    var freeSkipLimit: Int {
        featureFlagManager?.freeSkipLimit ?? Self.defaultFreeSkipLimit
    }

    var freeDownloadLimit: Int {
        featureFlagManager?.freeDownloadLimit ?? Self.defaultFreeDownloadLimit
    }

    private let featureFlagManager: FeatureFlagManager?

    // MARK: - Published State
    private(set) var isPremium: Bool = false {
        didSet {
            guard oldValue != isPremium else { return }
            NotificationCenter.default.post(name: .premiumStatusChanged, object: nil)
        }
    }
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchaseError: String?
    private(set) var subscriptionExpirationDate: Date?

    // MARK: - Redemption Feedback (polish-C2)

    /// User-facing result of an `.offerCodeRedemption` flow. Auto-clears after
    /// `redemptionFeedbackAutoClearInterval` seconds. Rendered inline in
    /// SettingsView below the redeem row.
    enum RedemptionFeedback: Equatable {
        case success(String)
        case failure(String)
    }

    private(set) var redemptionFeedback: RedemptionFeedback?

    /// Auto-clear interval for `redemptionFeedback`. Injectable for tests.
    @ObservationIgnored
    private let redemptionFeedbackAutoClearInterval: TimeInterval

    @ObservationIgnored
    private var redemptionFeedbackClearTask: Task<Void, Never>?

    func setRedemptionSuccess() {
        redemptionFeedback = .success(String(localized: "Premium activated"))
        scheduleRedemptionFeedbackClear()
    }

    func setRedemptionFailure(_ message: String) {
        redemptionFeedback = .failure(message)
        scheduleRedemptionFeedbackClear()
    }

    /// Legacy alias retained for `PaywallView` (Phase 3 will migrate it).
    func setRedemptionError(_ message: String) {
        purchaseError = message
        setRedemptionFailure(message)
    }

    private func scheduleRedemptionFeedbackClear() {
        redemptionFeedbackClearTask?.cancel()
        let interval = redemptionFeedbackAutoClearInterval
        redemptionFeedbackClearTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.redemptionFeedback = nil
        }
    }

    // MARK: - Dev Testing
    /// Toggle via Settings (controlled by CMS dev_mode_enabled flag).
    /// Only modifies in-memory state — never persists to UserDefaults.
    var devPremiumOverride: Bool? = nil {
        didSet {
            if let override = devPremiumOverride {
                isPremium = override
            }
        }
    }

    // MARK: - Skip Tracking (persisted to prevent bypass via force-quit)
    private(set) var skipCount: Int = UserDefaults.standard.integer(forKey: "skipCount")

    // MARK: - Private
    @ObservationIgnored
    private var transactionListener: Task<Void, Never>?
    @ObservationIgnored
    private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored
    private var iCloudObserver: (any NSObjectProtocol)?
    @ObservationIgnored
    private let iCloudStore = NSUbiquitousKeyValueStore.default

    // MARK: - Init
    init(
        featureFlagManager: FeatureFlagManager? = nil,
        redemptionFeedbackAutoClearInterval: TimeInterval = 6.0
    ) {
        self.featureFlagManager = featureFlagManager
        self.redemptionFeedbackAutoClearInterval = redemptionFeedbackAutoClearInterval
        // Trust local cache for instant launch UX, but only if not stale
        let localCached = UserDefaults.standard.bool(forKey: Self.premiumCacheKey)
        let iCloudCached = iCloudStore.bool(forKey: Self.iCloudPremiumKey)
        let cacheTimestamp = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        let cacheAge = Date().timeIntervalSince1970 - cacheTimestamp
        let cacheValid = cacheTimestamp > 0 && cacheAge < Self.cacheMaxAge

        isPremium = cacheValid && (localCached || iCloudCached)

        transactionListener = listenForTransactions()
        setupForegroundObserver()
        setupICloudObserver()

        Task {
            // Process any unfinished transactions from previous sessions
            for await result in Transaction.unfinished {
                do {
                    let transaction = try checkVerification(result)
                    await transaction.finish()
                } catch {
                    Log.app.error(
                        "Failed to verify unfinished transaction: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            await checkSubscriptionStatus()
        }
    }

    deinit {
        transactionListener?.cancel()
        redemptionFeedbackClearTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let iCloudObserver {
            NotificationCenter.default.removeObserver(iCloudObserver)
        }
    }

    // MARK: - Load Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let storeProducts = try await Product.products(for: Self.allProductIDs)
            products = storeProducts.sorted { lhs, rhs in
                let order: [String: Int] = [
                    Self.monthlyProductID: 0,
                    Self.yearlyProductID: 1,
                    Self.lifetimeProductID: 2,
                ]
                return (order[lhs.id] ?? 99) < (order[rhs.id] ?? 99)
            }
        } catch {
            purchaseError = String(
                localized: "Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        purchaseError = nil
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerification(verification)
            await updatePremiumStatus(true, expirationDate: transaction.expirationDate)
            await transaction.finish()

        case .userCancelled:
            break

        case .pending:
            purchaseError = String(localized: "Purchase is pending approval.")

        @unknown default:
            purchaseError = String(localized: "An unknown purchase result occurred.")
        }
    }

    // MARK: - Restore

    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        purchaseError = nil

        try await AppStore.sync()
        await checkSubscriptionStatus()

        if !isPremium {
            purchaseError = String(localized: "No active subscriptions found to restore.")
        }
    }

    // MARK: - Check Status

    func checkSubscriptionStatus() async {
        var hasActiveSubscription = false
        var latestExpiration: Date?

        for await result in Transaction.currentEntitlements {
            let transaction: Transaction
            do {
                transaction = try checkVerification(result)
            } catch {
                Log.app.error(
                    "Failed to verify entitlement: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard Self.allProductIDs.contains(transaction.productID) else { continue }

            // Skip revoked transactions (refunded by Apple)
            if transaction.revocationDate != nil {
                continue
            }

            // For auto-renewable subscriptions, verify not expired
            if let expirationDate = transaction.expirationDate {
                if expirationDate > Date() {
                    hasActiveSubscription = true
                    if let current = latestExpiration {
                        if expirationDate > current {
                            latestExpiration = expirationDate
                        }
                    } else {
                        latestExpiration = expirationDate
                    }
                }
                // Expired subscription — don't grant premium
            } else {
                // Non-expiring (lifetime) product
                hasActiveSubscription = true
            }
        }

        await updatePremiumStatus(hasActiveSubscription, expirationDate: latestExpiration)
    }

    // MARK: - Feature Gating

    func canAccess(_ feature: PremiumFeature) -> Bool {
        if let override = devPremiumOverride { return override }
        return isPremium
    }

    var remainingSkips: Int {
        isPremium ? .max : max(0, freeSkipLimit - skipCount)
    }

    func recordSkip() -> Bool {
        guard !isPremium else { return true }
        resetSkipsIfNeeded()
        if skipCount >= freeSkipLimit { return false }
        skipCount += 1
        UserDefaults.standard.set(skipCount, forKey: Self.skipCountKey)
        return true
    }

    func canDownload(currentCount: Int) -> Bool {
        if let override = devPremiumOverride { return override }
        return isPremium || currentCount < freeDownloadLimit
    }

    func maxAllowedQuality() -> String {
        isPremium ? "high" : "medium"
    }

    // MARK: - Helpers

    var monthlyProduct: Product? {
        products.first { $0.id == Self.monthlyProductID }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == Self.yearlyProductID }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == Self.lifetimeProductID }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try checkVerification(result)
                    // Handle refund/revocation immediately
                    if transaction.revocationDate != nil {
                        await self.handleRevocation(transaction)
                    } else {
                        await self.checkSubscriptionStatus()
                    }
                    await transaction.finish()
                } catch {
                    Log.app.error(
                        "Failed to verify transaction update: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Revocation Handling

    private func handleRevocation(_ transaction: Transaction) {
        // Immediately revoke access, then re-verify to catch any remaining entitlements
        isPremium = false
        Task {
            await checkSubscriptionStatus()
        }
    }

    // MARK: - Foreground Observer

    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkSubscriptionStatus()
            }
        }
    }

    // MARK: - iCloud Sync

    private func setupICloudObserver() {
        // Sync initial state from iCloud
        iCloudStore.synchronize()

        // Listen for external iCloud changes (e.g. premium purchased on another device)
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard
                let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey]
                    as? [String]
            else { return }

            if changedKeys.contains(Self.iCloudPremiumKey) {
                // Another device updated premium status — verify with StoreKit
                Task { @MainActor in
                    await self.checkSubscriptionStatus()
                }
            }
        }
    }

    // MARK: - Private Helpers

    private nonisolated func checkVerification<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }

    private func updatePremiumStatus(_ newValue: Bool, expirationDate: Date? = nil) async {
        isPremium = newValue
        subscriptionExpirationDate = expirationDate

        // Sync to local cache with timestamp for expiration
        UserDefaults.standard.set(newValue, forKey: Self.premiumCacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimestampKey)

        // Sync to iCloud for multi-device consistency
        iCloudStore.set(newValue, forKey: Self.iCloudPremiumKey)
        if let expirationDate {
            iCloudStore.set(
                expirationDate.timeIntervalSince1970, forKey: Self.subscriptionExpirationKey)
        } else {
            iCloudStore.removeObject(forKey: Self.subscriptionExpirationKey)
        }
    }

    private func resetSkipsIfNeeded() {
        let lastReset =
            UserDefaults.standard.object(forKey: Self.skipResetDateKey) as? Date ?? .distantPast
        let elapsed = Date().timeIntervalSince(lastReset)
        if elapsed >= 3600 {
            skipCount = 0
            UserDefaults.standard.set(0, forKey: Self.skipCountKey)
            UserDefaults.standard.set(Date(), forKey: Self.skipResetDateKey)
        }
    }
}
