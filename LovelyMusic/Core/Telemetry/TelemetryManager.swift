import Foundation

public final class TelemetryManager: Sendable {
    public static let shared = TelemetryManager()

    private let analyticsProvider: AnalyticsTrackerProtocol
    private let crashProvider: CrashLoggerProtocol

    public init(
        analyticsProvider: AnalyticsTrackerProtocol = NoOpAnalyticsProvider(),
        crashProvider: CrashLoggerProtocol = NoOpCrashProvider()
    ) {
        self.analyticsProvider = analyticsProvider
        self.crashProvider = crashProvider
    }

    public func trackEvent(_ name: String, parameters: [String: Any]? = nil) {
        analyticsProvider.logEvent(name, parameters: parameters)
    }

    public func recordError(_ error: Error, additionalInfo: [String: Any]? = nil) {
        crashProvider.recordError(error, additionalInfo: additionalInfo)
    }

    public func logBreadcrumb(_ message: String) {
        crashProvider.log(message)
    }

    public func setUserId(_ userId: String?) {
        crashProvider.setUserId(userId)
    }

    public func setUserProperty(_ value: String?, forName name: String) {
        analyticsProvider.setUserProperty(value, forName: name)
    }
}
