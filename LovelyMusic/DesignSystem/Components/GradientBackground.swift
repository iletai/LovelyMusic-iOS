import SwiftUI

struct DynamicGradientBackground: View {
    let dominantColor: Color
    var opacity: Double = 0.40

    var body: some View {
        ZStack {
            Theme.Colors.backgroundPrimary

            LinearGradient(
                colors: [
                    dominantColor.opacity(opacity),
                    dominantColor.opacity(opacity * 0.5),
                    Theme.Colors.backgroundPrimary
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: opacity)
    }
}
