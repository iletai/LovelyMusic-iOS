import SwiftUI
import UIKit

struct ScreenshotProtectionModifier: ViewModifier {
    let isProtected: Bool

    func body(content: Content) -> some View {
        if isProtected {
            content.overlay(SecureView())
        } else {
            content
        }
    }
}

struct SecureView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let field = UITextField()
        field.isSecureTextEntry = true
        guard let secureView = field.subviews.first else {
            return UIView()
        }
        secureView.subviews.forEach { $0.removeFromSuperview() }
        secureView.isUserInteractionEnabled = true
        return secureView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    func screenshotProtected(_ isProtected: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isProtected: isProtected))
    }
}
