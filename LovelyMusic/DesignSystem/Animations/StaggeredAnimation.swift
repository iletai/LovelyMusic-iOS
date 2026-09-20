import SwiftUI

struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    let delay: Double

    /// Items beyond this index appear immediately without GCD dispatch.
    private static let maxAnimatedIndex = 8

    @State private var isVisible = false

    init(index: Int, delay: Double = 0.05) {
        self.index = index
        self.delay = delay
    }

    func body(content: Content) -> some View {
        if index >= Self.maxAnimatedIndex {
            content
        } else {
            content
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(isVisible ? 1 : 0.95, anchor: .top)
                .animation(Theme.AnimationPresets.smooth, value: isVisible)
                .onAppear {
                    guard !isVisible else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(index)) {
                        isVisible = true
                    }
                }
        }
    }
}

extension View {
    func staggeredAppear(index: Int, delay: Double = 0.05) -> some View {
        modifier(StaggeredAppearModifier(index: index, delay: delay))
    }
}

struct StaggeredListContainer<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    let delay: Double
    let content: (Data.Element) -> Content

    init(_ data: Data, delay: Double = 0.05, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.delay = delay
        self.content = content
    }

    var body: some View {
        ForEach(Array(data.enumerated()), id: \.element.id) { index, item in
            content(item)
                .staggeredAppear(index: index, delay: delay)
        }
    }
}
