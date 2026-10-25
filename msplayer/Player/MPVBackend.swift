import Foundation
import UIKit
#if canImport(Libmpv)
import Libmpv
#endif

// MARK: - 画面承载层

/// MoltenVK 在结束/重置播放时会把 drawableSize 设成 1x1 来强制完成 presentation，
/// 这会造成闪屏，甚至尺寸再也回不来（mpv PR #13651）。小于 2px 的赋值直接忽略。
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue }
        }
    }
}

/// mpv 通过 wid 直接往这个 layer 上画，不走任何 SwiftUI 绘制。
final class MPVSurfaceView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        contentMode = .scaleToFill
        metalLayer.framebufferOnly = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.nativeScale
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
    }
}

/// MPVKit 是否真的链进了 App（SPM 依赖没接上时这里是 false）
enum MPVAvailability {
    static var available: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - libmpv 内核

/// MPVKit（libmpv）播放内核。
///
/// 渲染方式沿用官方 iOS Demo：`vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk`，
/// 把 CAMetalLayer 的指针当 `wid` 交给 mpv，由 mpv 自己画（无需我们写 Metal 渲染循环）。
/// 硬解走 VideoToolbox。
///
/// ⚠️ 若 MPVKit 没链进来（canImport 失败），下面的空壳实现会让 App 照常编译、只是 MPV 选项不可用。
final class MPVCore {

    var onEnded: (() -> Void)?
    var onLog: ((String) -> Void)?

#if canImport(Libmpv)

    private var mpv: OpaquePointer?
    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "msplayer.mpv", qos: .userInitiated)
    private var closed = false
    /// 主动 stop 也会收到 END_FILE，别把它当成「播完了」去切下一频道
    private var stoppedByUs = false

    var isAvailable: Bool { true }

    init(layer: CAMetalLayer) {
        self.layer = layer
        setup()
    }

    /// 内核已经在用这个 layer 了吗（SwiftUI 每次刷新都会重新 attach 同一个 view）
    func uses(layer: CAMetalLayer) -> Bool { self.layer === layer }

    deinit {
        shutdown()
    }

    // MARK: 初始化

    private func setup() {
        guard let handle = mpv_create() else {
            onLog?("mpv 内核创建失败")
            return
        }
        mpv = handle

        mpv_request_log_messages(handle, "no")

        setString("vo", "gpu-next")
        setString("gpu-api", "vulkan")
        setString("gpu-context", "moltenvk")
        setString("hwdec", "videotoolbox")
        setString("hwdec-codecs", "all")
        setString("video-rotate", "no")
        setString("subs-match-os-language", "yes")
        setString("subs-fallback", "yes")
        // 直播源大量自签/过期证书，不放行会直接握手失败
        setString("tls-verify", "no")
        // 与 VLC 那侧同理：跨分片重新拉流时的空档靠预读盖住，否则会一顿一顿
        setString("demuxer-readahead-secs", "20")
        setString("demuxer-max-bytes", "200MiB")

        // wid 必须在 mpv_initialize 之前给：mpv 会把它当成 CAMetalLayer* 直接渲染。
        // 这里传的是「存放对象指针的那个变量的地址」，mpv 按 int64 读出对象地址。
        var wid: CAMetalLayer = layer
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))

        let status = mpv_initialize(handle)
        if status < 0 {
            onLog?("mpv 初始化失败：\(Self.errorText(status))")
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, context)
    }

    // MARK: 播放

    func load(_ urlString: String, headers: [String: String]) {
        guard mpv != nil, !closed else { return }
        let fields = Self.headerFields(headers)
        if !fields.isEmpty {
            setString("http-header-fields", fields)
        }
        if let ua = headers["User-Agent"], !ua.isEmpty {
            setString("user-agent", ua)
        }
        stoppedByUs = false
        command("loadfile", args: [urlString, "replace"])
    }

    func setPaused(_ paused: Bool) {
        guard let handle = mpv else { return }
        var value: Int32 = paused ? 1 : 0
        check(mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &value))
    }

    func stop() {
        stoppedByUs = true
        command("stop")
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func setRate(_ value: Float) {
        guard let handle = mpv else { return }
        var rate = Double(value)
        check(mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &rate))
    }

    func shutdown() {
        guard !closed, mpv != nil else { return }
        closed = true
        command("quit")   // SHUTDOWN 事件到达时由事件线程执行 terminate_destroy
    }

    // MARK: 状态

    var currentTime: Double { double("time-pos") }
    var duration: Double { double("duration") }
    var isPaused: Bool { flag("pause") }
    var isBuffering: Bool { flag("paused-for-cache") }

    var videoSize: CGSize {
        CGSize(width: CGFloat(int64("dwidth")), height: CGFloat(int64("dheight")))
    }

    // MARK: 事件

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self, let handle = self.mpv else { return }
            // 注意：这里不能拿 closed 当循环条件——shutdown 之后正需要靠 SHUTDOWN 事件来真正销毁内核
            while true {
                guard let event = mpv_wait_event(handle, 0) else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_NONE:
                    return
                case MPV_EVENT_SHUTDOWN:
                    mpv_terminate_destroy(handle)
                    self.mpv = nil
                    return
                case MPV_EVENT_END_FILE:
                    let skip = self.stoppedByUs
                    self.stoppedByUs = false
                    if !skip {
                        DispatchQueue.main.async { [weak self] in self?.onEnded?() }
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: 底层工具

    private func command(_ name: String, args: [String] = []) {
        guard let handle = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutableRawPointer(mutating: pointer!))
            }
        }
        let status = mpv_command(handle, &cargs)
        if status < 0 {
            onLog?("mpv 命令 \(name) 失败：\(Self.errorText(status))")
        }
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        check(mpv_set_option_string(handle, name, value))
    }

    private func double(_ name: String) -> Double {
        guard let handle = mpv, !closed else { return 0 }
        var value = Double()
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    private func int64(_ name: String) -> Int64 {
        guard let handle = mpv, !closed else { return 0 }
        var value = Int64()
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return value
    }

    private func flag(_ name: String) -> Bool {
        guard let handle = mpv, !closed else { return true }
        var value: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
        return value != 0
    }

    private func check(_ status: CInt) {
        if status < 0 {
            onLog?("mpv：\(Self.errorText(status))")
        }
    }

    private static func errorText(_ status: CInt) -> String {
        String(cString: mpv_error_string(status))
    }

    /// mpv 的 http-header-fields 是「逗号分隔的 Name: value」列表，值里带逗号会破坏结构，直接丢掉。
    private static func headerFields(_ headers: [String: String]) -> String {
        headers.compactMap { key, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !trimmed.isEmpty, !trimmed.contains(",") else { return nil }
            return "\(key): \(trimmed)"
        }
        .joined(separator: ",")
    }

#else

    // MPVKit 未链入时的空壳：保证工程仍能编译，MPV 选项在设置里点了也不会崩。
    var isAvailable: Bool { false }

    init(layer: CAMetalLayer) {}

    func uses(layer: CAMetalLayer) -> Bool { false }

    func load(_ urlString: String, headers: [String: String]) {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
    func seek(to seconds: Double) {}
    func setRate(_ value: Float) {}
    func shutdown() {}

    var currentTime: Double { 0 }
    var duration: Double { 0 }
    var isPaused: Bool { true }
    var isBuffering: Bool { false }
    var videoSize: CGSize { .zero }

#endif
}
