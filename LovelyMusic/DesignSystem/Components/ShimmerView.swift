import SwiftUI

struct ShimmerView: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var cornerRadius: CGFloat = Theme.CornerRadius.small

    @State private var phase: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(light: Color(hex: "#C5BEE3"), dark: Color.white.opacity(0.04)))
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(light: Color.white.opacity(0.65), dark: Color.white.opacity(0.06)),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: geo.size.width * phase)
                }
            )
            .drawingGroup()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1.5
                }
            }
    }
}
