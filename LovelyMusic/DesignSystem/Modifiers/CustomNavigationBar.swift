import SwiftUI

/// Custom Navigation Bar ViewModifier providing unified Theme styling and CustomBackButton across all views.
struct CustomNavigationBarModifier: ViewModifier {
    let title: String?
    let isRoot: Bool
    let backButtonStyle: CustomBackButton.Style
    let displayMode: NavigationBarItem.TitleDisplayMode
    let onBack: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(!isRoot)
            .navigationBarTitleDisplayMode(displayMode)
            .toolbar {
                if !isRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        CustomBackButton(style: backButtonStyle, action: onBack)
                    }
                }
            }
            .modifier(TitleModifier(title: title))
    }
}

private struct TitleModifier: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title = title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

extension View {
    /// Applies LovelyMusic unified custom navigation bar with theme-styled back button.
    func customNavigationBar(
        title: String? = nil,
        isRoot: Bool = false,
        backButtonStyle: CustomBackButton.Style = .plain,
        displayMode: NavigationBarItem.TitleDisplayMode = .inline,
        onBack: (() -> Void)? = nil
    ) -> some View {
        modifier(CustomNavigationBarModifier(
            title: title,
            isRoot: isRoot,
            backButtonStyle: backButtonStyle,
            displayMode: displayMode,
            onBack: onBack
        ))
    }
}
