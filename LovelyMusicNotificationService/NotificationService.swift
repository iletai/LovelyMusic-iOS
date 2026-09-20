import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var didComplete = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            complete(request.content)
            return
        }

        guard let mediaURLString = request.content.userInfo["media_url"] as? String,
              let mediaURL = URL(string: mediaURLString) else {
            complete(bestAttemptContent)
            return
        }

        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: mediaURL)
                let ext = mediaURL.pathExtension.isEmpty ? "jpg" : mediaURL.pathExtension
                let targetURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext)")

                try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.moveItem(at: tempURL, to: targetURL)

                let attachment = try UNNotificationAttachment(
                    identifier: "media_attachment",
                    url: targetURL,
                    options: nil
                )
                bestAttemptContent.attachments = [attachment]
                complete(bestAttemptContent)
            } catch {
                complete(bestAttemptContent)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent = bestAttemptContent {
            complete(bestAttemptContent)
        }
    }

    private func complete(_ content: UNNotificationContent) {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return }
        didComplete = true
        contentHandler?(content)
        contentHandler = nil
    }
}