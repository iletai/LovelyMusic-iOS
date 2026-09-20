import SwiftUI

struct VinylDiscView: View {
    let thumbnailURL: String?
    let size: CGFloat
    let isPlaying: Bool
    let dominantColor: Color

    /// Accumulated angle from previous play sessions.
    @State private var baseAngle: Double = 0
    /// Date when the current play session started; nil when paused.
    @State private var playStartDate: Date?

    private var artworkSize: CGFloat { size * 0.52 }
    private var discSize: CGFloat { size }

    /// One full revolution every 8 seconds → 45°/s.
    static let degreesPerSecond: Double = 45

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { timeline in
            let rotation = currentRotation(at: timeline.date)
            ZStack {
                vinylDisc

                AsyncThumbnail(
                    url: thumbnailURL,
                    size: artworkSize,
                    cornerRadius: artworkSize / 2
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.3), lineWidth: 2)
                )
                .overlay(centerHole)
            }
            .drawingGroup()
            .rotationEffect(.degrees(rotation))
        }
        .frame(width: discSize, height: discSize)
        .onAppear {
            if isPlaying && playStartDate == nil {
                playStartDate = Date()
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                playStartDate = Date()
            } else {
                if let start = playStartDate {
                    baseAngle += Date().timeIntervalSince(start) * Self.degreesPerSecond
                }
                playStartDate = nil
            }
        }
        .shadow(color: dominantColor.opacity(0.25), radius: 24, y: 12)
    }

    // MARK: - Rotation

    /// Pure function — no state mutation, safe to call every frame.
    private func currentRotation(at date: Date) -> Double {
        guard let start = playStartDate else { return baseAngle }
        return baseAngle + date.timeIntervalSince(start) * Self.degreesPerSecond
    }

    // MARK: - Vinyl Disc

    private var vinylDisc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(white: 0.15),
                        Color(white: 0.08),
                        Color(white: 0.12),
                        Color(white: 0.05),
                        Color(white: 0.10),
                        Color(white: 0.03),
                    ],
                    center: .center,
                    startRadius: artworkSize / 2,
                    endRadius: discSize / 2
                )
            )
            .overlay(grooves)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - Grooves

    private var grooves: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let radius = artworkSize / 2 + CGFloat(i + 1) * ((discSize - artworkSize) / 14)
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                    .frame(width: radius * 2, height: radius * 2)
            }
        }
    }

    // MARK: - Center Hole

    private var centerHole: some View {
        Circle()
            .fill(Color.black.opacity(0.7))
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    .frame(width: 14, height: 14)
            )
    }
}
