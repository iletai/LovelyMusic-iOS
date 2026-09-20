import SwiftUI
import UIKit

struct TactileCardPressStyle: ButtonStyle {
    let haptic: Bool

    init(haptic: Bool = true) {
        self.haptic = haptic
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && haptic {
                    let impact = UIImpactFeedbackGenerator(style: .soft)
                    impact.impactOccurred()
                }
            }
    }
}

extension ButtonStyle where Self == TactileCardPressStyle {
    static var tactileCard: TactileCardPressStyle { TactileCardPressStyle(haptic: true) }
    static var tactileCardSilent: TactileCardPressStyle { TactileCardPressStyle(haptic: false) }
}
