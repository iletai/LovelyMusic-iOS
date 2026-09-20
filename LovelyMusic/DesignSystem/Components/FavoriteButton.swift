import SwiftUI

struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    @State private var animateBounce = false

    var body: some View {
        Button {
            animateBounce.toggle()
            action()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? Theme.Colors.error : Theme.Colors.textTertiary)
                .symbolEffect(.bounce, value: animateBounce)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .sensoryFeedback(.impact(weight: .light), trigger: isFavorite)
    }
}
