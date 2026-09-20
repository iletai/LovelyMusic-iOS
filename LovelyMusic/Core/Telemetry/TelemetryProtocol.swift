import Foundation

public protocol AnalyticsTrackerProtocol: Sendable {
    func logEvent(_ name: String, parameters: [String: Any]?)
    func setUserProperty(_ value: String?, forName name: String)
}

public protocol CrashLoggerProtocol: Sendable {
    func recordError(_ error: Error, additionalInfo: [String: Any]?)
    func log(_ message: String)
    func setUserId(_ userId: String?)
}

public final class NoOpAnalyticsProvider: AnalyticsTrackerProtocol, @unchecked Sendable {
    public init() {}
    public func logEvent(_ name: String, parameters: [String: Any]?) {}
    public func setUserProperty(_ value: String?, forName name: String) {}
}

public final class NoOpCrashProvider: CrashLoggerProtocol, @unchecked Sendable {
    public init() {}
    public func recordError(_ error: Error, additionalInfo: [String: Any]?) {}
    public func log(_ message: String) {}
    public func setUserId(_ userId: String?) {}
}
