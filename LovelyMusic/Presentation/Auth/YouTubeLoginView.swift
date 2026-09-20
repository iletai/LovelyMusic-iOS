import SwiftUI
import WebKit

struct YouTubeLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let authManager: YouTubeAuthManager
    let onLoginComplete: () -> Void

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView(authManager: authManager) {
                onLoginComplete()
                dismiss()
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CustomCloseButton()
                }
            }
        }
    }
}

struct YouTubeLoginWebView: UIViewRepresentable {
    let authManager: YouTubeAuthManager
    let onComplete: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let loginURLString = "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F&hl=en"
        if let url = URL(string: loginURLString) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(authManager: authManager, onComplete: onComplete)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let authManager: YouTubeAuthManager
        let onComplete: () -> Void
        // Must have navigated through Google accounts page before completing login
        private var hasSeenGoogleAccountsPage = false

        init(authManager: YouTubeAuthManager, onComplete: @escaping () -> Void) {
            self.authManager = authManager
            self.onComplete = onComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url?.absoluteString else { return }

            // Track when we've visited Google accounts (so we know auth started)
            if url.contains("accounts.google.com") {
                hasSeenGoogleAccountsPage = true
                return
            }

            // Only complete if user went through Google accounts AND landed on YouTube
            guard hasSeenGoogleAccountsPage else { return }
            guard url.contains("music.youtube.com") || url.contains("youtube.com/") else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }

                let ytCookies = cookies.filter {
                    $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
                }
                let hasSAPISID = ytCookies.contains { $0.name == "SAPISID" }
                let hasSID = ytCookies.contains { $0.name == "SID" }

                // Require both key auth cookies; using || would allow partial auth state
                guard hasSAPISID && hasSID else {
                    // Key auth cookies not yet set — wait for final music.youtube.com navigation
                    return
                }

                self.authManager.storeAuthCookies(ytCookies)
                DispatchQueue.main.async { self.onComplete() }
            }
        }
    }
}
