import Foundation
import UIKit
import UserNotifications
import os

@MainActor
final class APNsManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = APNsManager()
    private let logger = Logger(subsystem: "com.lovelymusic.app", category: "APNs")
    private var registerUseCase: RegisterDeviceTokenUseCase?
    private(set) var pendingRoute: Route?

    func configureDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func injectRegisterUseCase(_ registerUseCase: RegisterDeviceTokenUseCase) {
        self.registerUseCase = registerUseCase
    }

    func configure(registerUseCase: RegisterDeviceTokenUseCase) {
        injectRegisterUseCase(registerUseCase)
        configureDelegate()
    }

    func consumePendingRoute() -> Route? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    func requestPushAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            logger.error("Push auth error: \(error.localizedDescription)")
            return false
        }
    }

    func handleDeviceTokenRegistration(_ deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        logger.info("Received APNs Token: \(tokenString, privacy: .private)")
        let osVersion = UIDevice.current.systemVersion
        Task {
            do {
                try await registerUseCase?.execute(token: tokenString, osVersion: osVersion)
            } catch {
                logger.error("Failed to register token with backend: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func parseRoute(from userInfo: [AnyHashable: Any]) -> Route? {
        guard let routeType = userInfo["route"] as? String else { return nil }
        let rawBrowseId = (userInfo["browse_id"] as? String) ?? (userInfo["browseId"] as? String)
        let rawPlaylistId = (userInfo["playlist_id"] as? String) ?? (userInfo["playlistId"] as? String) ?? rawBrowseId

        switch routeType {
        case "album":
            if let browseId = rawBrowseId { return .album(browseId: browseId) }
        case "artist":
            if let browseId = rawBrowseId { return .artist(browseId: browseId) }
        case "playlist":
            if let playlistId = rawPlaylistId { return .playlist(playlistId: playlistId) }
        case "downloads":
            return .downloads
        case "likedSongs":
            return .likedSongs
        default:
            break
        }
        return nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let route = Self.parseRoute(from: userInfo) else { return }

        await MainActor.run {
            APNsManager.shared.pendingRoute = route
            NotificationCenter.default.post(
                name: Notification.Name("handleDeepLinkRoute"),
                object: nil,
                userInfo: ["targetRoute": route]
            )
        }
    }
}
