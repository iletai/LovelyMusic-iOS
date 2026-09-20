import AVFoundation
import SwiftUI
import UIKit

/// A lightweight `AVPlayerLayer`-backed video surface that renders the video
/// frames with **no system playback controls**. The custom full-screen video
/// UI owns its own control overlay, so it must not use SwiftUI's `VideoPlayer`
/// (which always draws AVKit's default chrome).
///
/// Important: this view only *attaches* the shared `AVPlayer` to its layer. It
/// never pauses, seeks, or replaces the player item — that pipeline is owned by
/// `AudioEngine`, which keeps the audio and video tracks in sync.
struct VideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerUIView, coordinator: Coordinator) {
        // Detach only — never tear down the shared player.
        uiView.playerLayer.player = nil
    }

    /// A `UIView` whose backing layer is an `AVPlayerLayer`.
    final class PlayerLayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // Safe: `layerClass` guarantees the backing layer type.
            layer as! AVPlayerLayer
        }
    }
}
