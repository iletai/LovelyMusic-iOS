import GoogleMobileAds
import UIKit
import os

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TelemetryManager.shared.logBreadcrumb("App finished launching")

        // Initialize Google Mobile Ads SDK — must be called before any ad request.
        // The SDK reads GADApplicationIdentifier from Info.plist automatically.
        MobileAds.shared.start()

        configureAudioSession()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            APNsManager.shared.handleDeviceTokenRegistration(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        TelemetryManager.shared.recordError(error, additionalInfo: ["context": "apns_registration"])
        os_log(.error, "Remote notification registration failed: %{public}@", error.localizedDescription)
    }

    /// Dynamically restrict supported orientations via `OrientationLock`.
    /// Default is portrait-only; the fullscreen video viewer opens this up
    /// to landscape while presented and restores portrait on dismiss.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.shared.mask }
    }

    private func configureAudioSession() {
        // Configure category at launch but defer activation to the playback path.
        // See `AudioSessionManager.setCategory` for rationale (F1 — cold-start
        // Now Playing binding race).
        AudioSessionManager.setCategory()
    }
}
