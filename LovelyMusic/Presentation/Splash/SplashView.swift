import SwiftUI

struct SplashView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var glowOpacity: Double = 0
    @State private var isFinished = false

    var onFinished: () -> Void

    var body: some View {
        ZStack {
            Theme.Colors.backgroundPrimary
                .ignoresSafeArea()

            // Brand gradient glow behind logo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.brandGradientStart.opacity(0.3),
                            Theme.Colors.brandGradientEnd.opacity(0.1),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .opacity(glowOpacity)

            // App logo
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.extraLarge))
                .scaleEffect(logoScale)
                .opacity(logoOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                logoOpacity = 1
                logoScale = 1
            }
            withAnimation(.easeInOut(duration: 0.8).delay(0.3)) {
                glowOpacity = 1
            }
            // Auto-dismiss after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(Theme.AnimationPresets.smooth) {
                    isFinished = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    onFinished()
                }
            }
        }
        .opacity(isFinished ? 0 : 1)
        .scaleEffect(isFinished ? 1.1 : 1)
        .animation(Theme.AnimationPresets.smooth, value: isFinished)
    }
}
