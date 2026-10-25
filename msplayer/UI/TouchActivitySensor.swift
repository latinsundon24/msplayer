import SwiftUI
import UIKit

/// 感知「用户是否正在操作」的透明传感器，用于驱动侧栏的「有操作就一直显示、空闲才隐藏」。
///
/// ## 为什么不用 SwiftUI 的容器级手势
/// 上一版在容器上直接加 `.onTapGesture` + `.simultaneousGesture(DragGesture)`，
/// 结果抢占了 `Picker(.segmented)` 与内部 Button 的触摸，导致左栏 tab 完全切不动。
///
/// ## 本实现的要点
/// - 自身 `isUserInteractionEnabled = false`：完全不参与命中测试，**绝不抢走**
///   下层 ScrollView / Button / Picker 的触摸。
/// - 把手势识别器挂到 **window** 上：UIWindow 会先把 touches 交给自己的手势识别器，
///   因此能感知到区域内的所有触摸，而不需要在内容层加任何 SwiftUI 手势。
/// - `cancelsTouchesInView = false`：识别后不吞事件，触摸仍正常下发到真正的控件。
/// - `shouldRecognizeSimultaneouslyWith` 返回 true：与其它所有手势共存，互不阻塞。
/// - `shouldReceive` 把范围限定在传感器自身的矩形内（即左栏面板区域），
///   避免把播放器区域的触摸误判成左栏操作。
struct TouchActivitySensor: UIViewRepresentable {
    let onActivity: () -> Void

    func makeUIView(context: Context) -> SensorView {
        let view = SensorView()
        view.onActivity = onActivity
        view.installIfNeeded()
        return view
    }

    func updateUIView(_ uiView: SensorView, context: Context) {
        uiView.onActivity = onActivity
        uiView.installIfNeeded()
    }

    static func dismantleUIView(_ uiView: SensorView, coordinator: ()) {
        uiView.teardown()
    }

    final class SensorView: UIView {
        var onActivity: (() -> Void)?

        private var recognizer: UILongPressGestureRecognizer?
        private weak var hostWindow: UIWindow?
        private var lastFire = Date.distantPast

        override init(frame: CGRect) {
            super.init(frame: frame)
            // 关键：自身不接收触摸，避免命中测试拦截下层控件。
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard recognizer == nil, let window = self.window else { return }
            // 用「零延迟长按」来感知任意触摸：按下即 began，移动时持续 changed。
            // 相比自定义 recognizer 子类手搓 state 机，系统识别器的状态流转完全合规。
            let rec = UILongPressGestureRecognizer(target: self, action: #selector(handleActivity))
            rec.minimumPressDuration = 0
            // 允许任意距离的移动，否则滚动 / 拖拽时会因位移超限而 failed。
            rec.allowableMovement = 1_000_000
            rec.cancelsTouchesInView = false
            rec.delegate = self
            window.addGestureRecognizer(rec)
            recognizer = rec
            hostWindow = window
        }

        func teardown() {
            if let rec = recognizer {
                rec.view?.removeGestureRecognizer(rec)
            }
            recognizer = nil
            hostWindow = nil
        }

        @objc private func handleActivity() {
            let now = Date()
            guard now.timeIntervalSince(lastFire) > 0.25 else { return }
            lastFire = now
            onActivity?()
        }

        /// 只把落在左栏区域内的触摸算作左栏操作。
        /// 布局尚未就绪（bounds 过小）时不限制，避免开局失灵。
        fileprivate func isTouchInside(_ touch: UITouch) -> Bool {
            guard let window = hostWindow, bounds.width > 1, bounds.height > 1 else { return true }
            let point = touch.location(in: window)
            return convert(bounds, to: window).contains(point)
        }
    }
}

extension TouchActivitySensor.SensorView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isTouchInside(touch)
    }
}
