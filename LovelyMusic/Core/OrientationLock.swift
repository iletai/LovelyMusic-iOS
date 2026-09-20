import UIKit

/// Process-wide orientation gate consulted by `AppDelegate`'s
/// `application(_:supportedInterfaceOrientationsFor:)`. Default state is
/// portrait-only (matches the rest of the app). Screens that need to
/// rotate — currently only the fullscreen video viewer — flip
/// `mask` while presented and restore it on dismiss.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    /// Currently-allowed orientations. Read by `AppDelegate` on every
    /// rotation query.
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    private init() {}

    /// Set the allowed orientations and ask the system to re-evaluate the
    /// active scene immediately so already-presented views rotate without
    /// waiting for the next device-orientation event.
    func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        guard
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
        scene.windows.first?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Allow both landscape orientations AND immediately force-rotate to
    /// landscapeLeft so the user doesn't have to physically turn the device.
    func enterFullscreen() {
        mask = .landscape  // AppDelegate allows both landscape orientations
        guard
            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        // Force rotation; user can freely switch to landscapeRight after.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { _ in }
        scene.windows.first?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
