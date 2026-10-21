import SwiftUI
import AVFoundation
import UIKit

extension VideoAspect {
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

struct PlayerSurface: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        ZStack {
            Color.black
            if controller.backend == .vlc {
                VLCVideoView(aspect: controller.aspect, videoSize: controller.videoSize) { view in
                    controller.attach(drawable: view)
                }
            } else {
                SystemVideoView(player: controller.avPlayer, gravity: controller.aspect.gravity)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 系统解码画面

final class SystemPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct SystemVideoView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> SystemPlayerLayerView {
        let view = SystemPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: SystemPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = gravity
    }
}

// MARK: - VLC 画面

final class VLCContainerView: UIView {
    var aspect: VideoAspect = .fit { didSet { applyTransform() } }
    var videoSize: CGSize = .zero { didSet { applyTransform() } }
    private var attached = false

    override func layoutSubviews() {
        super.layoutSubviews()
        applyTransform()
    }

    private func applyTransform() {
        guard videoSize.width > 1, videoSize.height > 1,
              bounds.width > 1, bounds.height > 1 else {
            transform = .identity
            return
        }
        let videoRatio = videoSize.width / videoSize.height
        let viewRatio = bounds.width / bounds.height
        switch aspect {
        case .fit:
            transform = .identity
        case .fill:
            let scale = videoRatio > viewRatio ? videoRatio / viewRatio : viewRatio / videoRatio
            transform = CGAffineTransform(scaleX: scale, y: scale)
        case .stretch:
            if videoRatio > viewRatio {
                transform = CGAffineTransform(scaleX: 1, y: videoRatio / viewRatio)
            } else {
                transform = CGAffineTransform(scaleX: viewRatio / videoRatio, y: 1)
            }
        }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let aspect: VideoAspect
    let videoSize: CGSize
    let attach: (UIView) -> Void

    func makeUIView(context: Context) -> VLCContainerView {
        let view = VLCContainerView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.aspect = aspect
        view.videoSize = videoSize
        attach(view)
        return view
    }

    func updateUIView(_ uiView: VLCContainerView, context: Context) {
        uiView.aspect = aspect
        uiView.videoSize = videoSize
        attach(uiView)
    }
}
