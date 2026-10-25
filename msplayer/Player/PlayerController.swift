import Foundation
import AVFoundation
import Combine
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// 统一播放控制器：系统 AVPlayer 主路，VLC 兼容兜底。
/// DASH + ClearKey 仍然走「下载 → 解密 → 去信令 → 本地 HLS」，再交给选中的解码器。
@MainActor
final class PlayerController: NSObject, ObservableObject {

    enum Backend {
        case idle
        case system
        case vlc
        case mpv
    }

    // MARK: - 对外状态

    @Published private(set) var backend: Backend = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLive = false
    @Published private(set) var resolution: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var statusText: String?
    @Published private(set) var playbackMode: String = "—"
    @Published private(set) var playbackURL: String = ""
    @Published private(set) var currentChannel: Channel?
    @Published private(set) var lineIndex: Int = 0
    @Published var aspect: VideoAspect = .fit {
        didSet { applyAspectToVLC() }
    }

    let avPlayer = AVPlayer()
    private(set) var vlcPlayer: AnyObject?

    var onEnded: (() -> Void)?
    var onPlaybackStarted: (() -> Void)?

    // MARK: - 私有状态

    private var dash: DashPlayback?
    private var proxy: HLSProxy?
    private var mpvCore: MPVCore?
    private var mpvPendingURL: URL?
    private var mpvPendingHeaders: [String: String] = [:]
    private var mpvTickTimer: Timer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?

    private var openToken = UUID()
    private var wantsPlayback = true
    private var rate: Float = 1
    private var proxyAttempted = false
    private var vlcFallbackTried = false
    private var systemFallbackTried = false
    private var startupWatchdog: Task<Void, Never>?
    private weak var vlcDrawable: UIView?
    @Published private(set) var videoSize: CGSize = .zero

    override init() {
        super.init()
        avPlayer.actionAtItemEnd = .pause
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.allowsExternalPlayback = true

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.handleSystemTick(time)
            }
        }

        #if canImport(MobileVLCKit)
        let player = VLCMediaPlayer()
        player.delegate = self
        vlcPlayer = player
        #endif
    }

    deinit {
        if let timeObserver {
            avPlayer.removeTimeObserver(timeObserver)
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func handleSystemTick(_ time: CMTime) {
        guard backend == .system else { return }
        currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
        isPlaying = avPlayer.rate > 0
        guard let item = avPlayer.currentItem else { return }

        let seconds = item.duration.seconds
        if seconds.isFinite && seconds > 0 {
            duration = seconds
            isLive = false
        } else if item.status == .readyToPlay {
            isLive = true
            duration = 0
        }

        let size = item.presentationSize
        if size.width > 1, size.height > 1, size != videoSize {
            videoSize = size
            resolution = ResolutionLabel.text(for: size) ?? ""
        }

        if item.status == .failed {
            reportSystemError(item)
        }
    }

    var canUseVLC: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    /// MPVKit（libmpv）是否链入本包
    var canUseMPV: Bool { MPVAvailability.available }

    // MARK: - 打开频道

    func open(channel: Channel, lineIndex: Int = 0) {
        stopCurrent()
        currentChannel = channel
        self.lineIndex = lineIndex
        proxyAttempted = false
        vlcFallbackTried = false
        systemFallbackTried = false
        wantsPlayback = true
        errorMessage = nil
        resolution = ""
        currentTime = 0
        duration = 0
        isLive = false
        isPreparing = false
        statusText = nil
        playbackURL = ""
        let token = UUID()
        openToken = token

        if channel.isDASH {
            isPreparing = true
            statusText = "正在解析 DASH 流…"
            playbackMode = "DASH · 本地解密"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let playback = try DashPlayback(channel: channel)
                    let url = try await playback.start()
                    guard self.openToken == token else {
                        playback.stop()
                        return
                    }
                    self.dash = playback
                    self.isLive = playback.isLive
                    self.isPreparing = false
                    self.statusText = nil
                    self.start(url: url, headers: [:], channel: channel)
                } catch {
                    guard self.openToken == token else { return }
                    self.isPreparing = false
                    self.statusText = nil
                    self.errorMessage = error.localizedDescription
                }
            }
            return
        }

        guard let url = URL(string: channel.url) else {
            errorMessage = "地址无效"
            return
        }
        start(url: url, headers: channel.headers, channel: channel)
    }

    func play() {
        wantsPlayback = true
        switch backend {
        case .system:
            avPlayer.playImmediately(atRate: rate)
            isPlaying = true
        case .vlc:
            #if canImport(MobileVLCKit)
            (vlcPlayer as? VLCMediaPlayer)?.play()
            isPlaying = true
            #endif
        case .mpv:
            mpvCore?.setPaused(false)
            isPlaying = true
        case .idle:
            break
        }
    }

    func pause() {
        wantsPlayback = false
        switch backend {
        case .system:
            avPlayer.pause()
        case .vlc:
            #if canImport(MobileVLCKit)
            (vlcPlayer as? VLCMediaPlayer)?.pause()
            #endif
        case .mpv:
            mpvCore?.setPaused(true)
        case .idle:
            break
        }
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// 时移：在当前播放位置前后跳转，用于支持回看的频道。
    func skip(by seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(max(currentTime + seconds, 0), max(0, duration - 1))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, !isLive else { return }
        currentTime = seconds
        switch backend {
        case .system:
            avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        case .vlc:
            #if canImport(MobileVLCKit)
            (vlcPlayer as? VLCMediaPlayer)?.time = VLCTime(int: Int32(seconds * 1000))
            #endif
        case .mpv:
            mpvCore?.seek(to: seconds)
        case .idle:
            break
        }
    }

    func setRate(_ value: Float) {
        rate = value
        if backend == .system, avPlayer.rate > 0 {
            avPlayer.rate = value
        }
        #if canImport(MobileVLCKit)
        if backend == .vlc, let player = vlcPlayer as? VLCMediaPlayer {
            player.rate = value
        }
        #endif
        if backend == .mpv {
            mpvCore?.setRate(value)
        }
    }

    func stopCurrent() {
        openToken = UUID()
        startupWatchdog?.cancel()
        startupWatchdog = nil
        dash?.stop()
        dash = nil
        proxy?.stop()
        proxy = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        #if canImport(MobileVLCKit)
        (vlcPlayer as? VLCMediaPlayer)?.stop()
        #endif
        mpvCore?.stop()
        mpvPendingURL = nil
        stopMPVTick()
        backend = .idle
        isPlaying = false
        currentTime = 0
    }

    // MARK: - 选择解码器

    private func shouldUseVLC(url: URL, channel: Channel) -> Bool {
        let lower = url.absoluteString.lowercased()
        let onlyVLC = lower.hasPrefix("rtmp") || lower.hasPrefix("rtsp")
            || lower.hasPrefix("udp") || lower.hasPrefix("mms") || lower.hasSuffix(".flv")

        switch Store.shared.settings.decoder {
        case .system:
            return false
        case .vlc:
            return canUseVLC
        case .auto:
            // 回看（playseek）优先 VLC：运营商时移流的封装/编码更杂，VLC 兼容性更好；
            // 失败或 15 秒无画面仍会自动回退到 AVPlayer。
            if lower.contains("playseek="), canUseVLC { return true }
            return onlyVLC && canUseVLC
        }
    }

    private func start(url: URL, headers: [String: String], channel: Channel) {
        if shouldUseMPV(url: url, channel: channel) {
            startMPV(url: url, headers: headers, channel: channel)
            return
        }
        if shouldUseVLC(url: url, channel: channel) {
            // VLC 只真正认 User-Agent / Referer 两个选项，Cookie 这类自定义头在 VLC 侧没有可靠选项，
            // 与其赌它生效（表现为源站 403 或一直转圈），不如同样交给本地代理：
            // 代理由 URLSession 取流，Cookie 一定随清单和分片一起发出。
            if let proxy = makeProxyIfNeeded(url: url, headers: headers, channel: channel) {
                self.proxy = proxy
                playbackMode = "VLC · 本地代理（自定义请求头）"
                startVLC(url: proxy.entryURL, headers: [:])
                return
            }
            startVLC(url: url, headers: headers)
            return
        }
        // AVPlayer 的 AVURLAssetHTTPHeaderFieldsKey 只作用于「首次清单请求」，HLS 的子清单与分片请求不会继承。
        // 而 #EXTHTTP / #EXTVLCOPT / |Referer=… 指定的头，往往是源站用来校验分片的（防盗链、鉴权），
        // 分片缺头会 403 或一直转圈，且不一定让 AVPlayerItem 变成 failed —— 现有失败兜底等不到。
        // 所以带自定义头时改走本地代理：代理由 URLSession 取数，清单和分片都会带上这些头。
        if let proxy = makeProxyIfNeeded(url: url, headers: headers, channel: channel) {
            self.proxy = proxy
            playbackMode = "HLS · 本地代理（自定义请求头）"
            startSystem(url: proxy.entryURL, headers: [:], channel: channel)
            return
        }
        startSystem(url: url, headers: headers, channel: channel)
    }

    /// 只有用户在设置里显式选了 MPV 才用。auto / system / vlc 三条原有路径一字不动。
    private func shouldUseMPV(url: URL, channel: Channel) -> Bool {
        Store.shared.settings.decoder == .mpv && canUseMPV
    }

    // MARK: - MPV 解码

    private func startMPV(url: URL, headers: [String: String], channel: Channel) {
        backend = .mpv
        playbackURL = url.absoluteString
        playbackMode = "MPV · 兼容解码"
        errorMessage = nil
        statusText = nil
        videoSize = .zero
        resolution = ""
        currentTime = 0
        duration = 0
        isLive = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        #if canImport(MobileVLCKit)
        (vlcPlayer as? VLCMediaPlayer)?.stop()
        #endif

        var target = url
        var targetHeaders = headers
        // 与 VLC 侧同一套保障：带自定义头（Cookie / Referer…）时走本地代理，清单和分片都带得上；
        // 直连时 mpv 自己也会按 http-header-fields 发头，双保险。
        if let proxy = makeProxyIfNeeded(url: url, headers: headers, channel: channel) {
            self.proxy = proxy
            target = proxy.entryURL
            targetHeaders = [:]
            playbackMode = "MPV · 本地代理（自定义请求头）"
        }

        mpvPendingURL = target
        mpvPendingHeaders = targetHeaders
        mpvCore?.load(target.absoluteString, headers: targetHeaders)
        startMPVTick()
        armStartupWatchdog(expecting: .mpv)
        isPlaying = true
    }

    /// MPV 画面出现时把 Metal layer 交给内核。wid 在创建后改不了，换 layer 就得重建内核。
    func attachMPV(layer: CAMetalLayer) {
        guard canUseMPV else { return }
        if let core = mpvCore {
            if core.uses(layer: layer) {
                flushMPVPending(core)
                return
            }
            core.shutdown()
        }
        let core = MPVCore(layer: layer)
        core.onEnded = { [weak self] in self?.onEnded?() }
        core.onLog = { message in NSLog("[msplayer] mpv: %@", message) }
        mpvCore = core
        if let pending = mpvPendingURL {
            mpvPendingURL = nil
            core.load(pending.absoluteString, headers: mpvPendingHeaders)
            return
        }
        // 换了 layer 就得重建内核，此时要接着播当前这个频道，不能空着
        guard backend == .mpv else { return }
        if let proxy {
            core.load(proxy.entryURL.absoluteString, headers: [:])
        } else if !playbackURL.isEmpty {
            core.load(playbackURL, headers: currentChannel?.headers ?? [:])
        }
    }

    private func flushMPVPending(_ core: MPVCore) {
        guard let pending = mpvPendingURL else { return }
        mpvPendingURL = nil
        core.load(pending.absoluteString, headers: mpvPendingHeaders)
    }

    /// mpv 没有 AVPlayer 那样的周期回调，用主线程定时器读属性更新进度条与分辨率。
    private func startMPVTick() {
        mpvTickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleMPVTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mpvTickTimer = timer
    }

    private func stopMPVTick() {
        mpvTickTimer?.invalidate()
        mpvTickTimer = nil
    }

    private func handleMPVTick() {
        guard backend == .mpv, let core = mpvCore else { return }
        currentTime = max(0, core.currentTime)
        let length = core.duration
        if length.isFinite, length > 0 {
            duration = length
            isLive = false
        } else {
            duration = 0
            isLive = true
        }
        let size = core.videoSize
        if size.width > 1, size.height > 1, size != videoSize {
            videoSize = size
            resolution = ResolutionLabel.text(for: size) ?? ""
        }
        isPlaying = !core.isPaused
        if core.isBuffering {
            statusText = "缓冲中…"
        } else if statusText == "缓冲中…" {
            statusText = nil
        }
    }

    /// 需要代理时就地启动并返回；条件不满足或启动失败返回 nil（调用方按原路径直连）。
    private func makeProxyIfNeeded(url: URL,
                                   headers: [String: String],
                                   channel: Channel) -> HLSProxy? {
        guard shouldProxyForCustomHeaders(url: url, headers: headers, channel: channel) else { return nil }
        do {
            let proxy = try HLSProxy(channel: channel)
            proxyAttempted = true
            NSLog("[msplayer] custom headers -> local proxy: %@", headers.description)
            return proxy
        } catch {
            NSLog("[msplayer] custom-header proxy start failed: %@", String(describing: error))
            return nil
        }
    }

    /// 只有「确实带了自定义头」且是 HTTP(S) 流式清单时才走代理。
    /// 没有头的频道播放路径完全不变，避免引入回归。
    private func shouldProxyForCustomHeaders(url: URL,
                                             headers: [String: String],
                                             channel: Channel) -> Bool {
        guard !headers.isEmpty, !proxyAttempted, !channel.isDASH else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }

        let lower = url.absoluteString.lowercased()
        // RTMP/RTSP/UDP/MMS 不走 HTTP，代理没有意义
        if lower.hasPrefix("rtmp") || lower.hasPrefix("rtsp")
            || lower.hasPrefix("udp") || lower.hasPrefix("mms") { return false }
        // FLV / TS 是「一条持续不断的连接」，MP4 是点播文件：
        // 本地代理是按「取回整个响应」的方式转发的，用在这些格式上反而播不了（会一直等或无法拖动），保持直连。
        if lower.hasSuffix(".flv") || lower.hasSuffix(".ts")
            || lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") { return false }
        return true
    }

    // MARK: - 回看解码兜底

    private var isCatchUpPlayback: Bool {
        // 走代理时 playbackURL 是本机地址（目标被 base64 过），只能拿原始频道地址判断
        let original = currentChannel?.url.lowercased() ?? ""
        return playbackURL.lowercased().contains("playseek=") || original.contains("playseek=")
    }

    /// 回看流启动 15 秒仍无画面时，自动换另一个解码器重试一次。
    private func armStartupWatchdog(expecting backend: Backend) {
        startupWatchdog?.cancel()
        guard isCatchUpPlayback else { return }
        let token = openToken
        startupWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.openToken == token, self.wantsPlayback else { return }
            switch backend {
            case .system:
                guard self.backend == .system, let item = self.avPlayer.currentItem else { return }
                let stuck = item.status != .readyToPlay
                    || (self.avPlayer.rate == 0 && self.currentTime < 1)
                if stuck { self.retryCatchUpWithVLC() }
            case .vlc:
                #if canImport(MobileVLCKit)
                guard self.backend == .vlc,
                      let player = self.vlcPlayer as? VLCMediaPlayer else { return }
                if player.state != .playing && player.state != .buffering {
                    self.retryCatchUpWithSystem()
                }
                #endif
            case .mpv:
                guard self.backend == .mpv else { return }
                if self.videoSize.width <= 1 {
                    self.retryCatchUpWithSystem()
                }
            case .idle:
                break
            }
        }
    }

    private func retryCatchUpWithVLC() {
        guard canUseVLC, !vlcFallbackTried,
              let channel = currentChannel,
              let url = URL(string: playbackURL) else { return }
        vlcFallbackTried = true
        NSLog("[msplayer] catch-up: switch to VLC")
        startVLC(url: url, headers: channel.headers)
    }

    @discardableResult
    private func retryCatchUpWithSystem() -> Bool {
        guard !systemFallbackTried, !vlcFallbackTried,
              let channel = currentChannel,
              let url = URL(string: playbackURL) else { return false }
        systemFallbackTried = true
        vlcFallbackTried = true
        NSLog("[msplayer] catch-up: switch to AVPlayer")
        startSystem(url: url, headers: channel.headers, channel: channel)
        return true
    }

    // MARK: - 系统解码

    private func startSystem(url: URL, headers: [String: String], channel: Channel) {
        backend = .system
        playbackURL = url.absoluteString
        playbackMode = channel.isDASH ? "DASH · 系统解码" : "HLS · 系统解码"
        videoSize = .zero
        #if canImport(MobileVLCKit)
        (vlcPlayer as? VLCMediaPlayer)?.stop()
        #endif

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = options.map { AVURLAsset(url: url, options: $0) } ?? AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard item === self.avPlayer.currentItem else { return }
                if item.status == .failed { self.reportSystemError(item) }
                if item.status == .readyToPlay { self.onPlaybackStarted?() }
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.reportSystemError(item)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.onEnded?()
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        if wantsPlayback {
            avPlayer.playImmediately(atRate: rate)
            isPlaying = true
        }
        armStartupWatchdog(expecting: .system)
    }

    private func reportSystemError(_ item: AVPlayerItem) {
        guard item === avPlayer.currentItem, backend == .system else { return }
        let ns = item.error as NSError?
        var detail = ns?.localizedDescription ?? "无法播放该流"
        if let ns {
            detail += "（\(ns.domain) \(ns.code)）"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += "\n\(underlying.domain) \(underlying.code)"
            }
        }
        NSLog("[msplayer] AVPlayer failed: %@", String(describing: ns))

        // 1) 证书/网络问题：先走本地代理（URLSession 可放行异常证书）
        if !proxyAttempted,
           let channel = currentChannel,
           !channel.isDASH,
           ns != nil,
           shouldRetryWithProxy(ns!) {
            proxyAttempted = true
            do {
                let proxy = try HLSProxy(channel: channel)
                self.proxy = proxy
                playbackMode = "HLS · 本地代理"
                errorMessage = nil
                startSystem(url: proxy.entryURL, headers: [:], channel: channel)
                return
            } catch {
                NSLog("[msplayer] proxy start failed: %@", String(describing: error))
            }
        }

        // 2) 系统解码失败：交给 VLC
        if canUseVLC, !vlcFallbackTried,
           (Store.shared.settings.decoder != .system || isCatchUpPlayback),
           let channel = currentChannel, let url = URL(string: playbackURL) {
            vlcFallbackTried = true
            NSLog("[msplayer] fallback to VLC: %@", playbackURL)
            startVLC(url: url, headers: channel.headers)
            return
        }

        errorMessage = detail
        isPlaying = false
    }

    private func shouldRetryWithProxy(_ error: NSError) -> Bool {
        if HTTPService.isCertificateError(error) { return true }
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorSecureConnectionFailed:
            return false
        default:
            return true
        }
    }

    // MARK: - VLC 解码

    private func startVLC(url: URL, headers: [String: String]) {
        #if canImport(MobileVLCKit)
        guard let player = vlcPlayer as? VLCMediaPlayer else { return }
        backend = .vlc
        playbackURL = url.absoluteString
        playbackMode = "VLC · 兼容解码"
        errorMessage = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)

        let media = VLCMedia(url: url)
        for (key, value) in headers {
            let name = key.lowercased()
            let headerValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !headerValue.isEmpty else { continue }
            // 换行会被 VLC 当成「下一个选项」，脏数据直接跳过，别让它污染播放参数
            if name.rangeOfCharacter(from: .newlines) != nil { continue }
            if headerValue.rangeOfCharacter(from: .newlines) != nil { continue }
            // 注：VLC 只认 User-Agent / Referrer 这两个标准项；其余任意头它未必生效，
            // 真正需要自定义头时由上面的本地代理路径保障（URLSession 会如实发出所有头）。
            switch name {
            case "user-agent":
                media.addOption(":http-user-agent=\(headerValue)")
            case "referer":
                media.addOption(":http-referrer=\(headerValue)")
            default:
                media.addOption(":http-\(name)=\(headerValue)")
            }
        }
        // 缓冲大小直接决定 HLS / DASH 分片交界处会不会顿一下：
        // 每跨一个分片都要重新发起 HTTP 请求（走本地解密链路时，还要等整段下载 + 解密完成才吐数据），
        // 原来 1200ms 的缓冲根本盖不住这段间隙，于是表现为「播完一段停一下再接着播」。
        // 统一放大到 5 秒后，播放器会在缓冲窗口内提前把下一段拉到手，从而连续播放。
        media.addOption(":network-caching=5000")
        media.addOption(":live-caching=5000")
        media.addOption(":file-caching=5000")
        // 时钟抖动容错：避免 PCR 抖动导致的顿挫。
        media.addOption(":clock-jitter=0")
        // 连接被服务器断开时自动重连，避免直播推流侧断连后直接卡死。
        media.addOption(":http-reconnect=true")

        if let drawable = vlcDrawable {
            player.drawable = drawable
        }
        player.media = media
        player.play()
        isPlaying = true
        onPlaybackStarted?()
        armStartupWatchdog(expecting: .vlc)
        #else
        errorMessage = "当前版本未集成 VLC 解码器"
        #endif
    }

    func attach(drawable: UIView) {
        vlcDrawable = drawable
        #if canImport(MobileVLCKit)
        (vlcPlayer as? VLCMediaPlayer)?.drawable = drawable
        #endif
        applyAspectToVLC(in: drawable)
    }

    func updateVideoSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        videoSize = size
        resolution = ResolutionLabel.text(for: size) ?? ""
        if let drawable = vlcDrawable {
            applyAspectToVLC(in: drawable)
        }
    }

    private func applyAspectToVLC() {
        if let drawable = vlcDrawable {
            applyAspectToVLC(in: drawable)
        }
    }

    func applyAspectToVLC(in view: UIView) {
        guard backend == .vlc, videoSize.width > 1, videoSize.height > 1,
              view.bounds.width > 1, view.bounds.height > 1 else {
            view.transform = .identity
            return
        }
        let videoRatio = videoSize.width / videoSize.height
        let viewRatio = view.bounds.width / view.bounds.height

        switch aspect {
        case .fit:
            view.transform = .identity
        case .fill:
            if videoRatio > viewRatio {
                view.transform = CGAffineTransform(scaleX: videoRatio / viewRatio, y: videoRatio / viewRatio)
            } else {
                view.transform = CGAffineTransform(scaleX: viewRatio / videoRatio, y: viewRatio / videoRatio)
            }
        case .stretch:
            if videoRatio > viewRatio {
                view.transform = CGAffineTransform(scaleX: 1, y: videoRatio / viewRatio)
            } else {
                view.transform = CGAffineTransform(scaleX: viewRatio / videoRatio, y: 1)
            }
        }
    }

    // MARK: - 诊断

    var diagnosticsText: String {
        var lines: [String] = []
        lines.append("频道：\(currentChannel?.name ?? "—")")
        lines.append("地址：\(currentChannel?.url ?? "—")")
        lines.append("模式：\(playbackMode)")
        lines.append("播放地址：\(playbackURL.isEmpty ? "—" : playbackURL)")
        let decoderName = backend == .vlc ? "VLC" : backend == .mpv ? "MPV" : backend == .system ? "AVPlayer" : "—"
        lines.append("解码：\(decoderName)")
        lines.append("MPV 内核：\(canUseMPV ? "已集成" : "未集成")")
        lines.append("回看：\(isCatchUpPlayback ? "是" : "否")")
        if backend == .system, let item = avPlayer.currentItem {
            lines.append("Item：status=\(item.status.rawValue) 轨道=\(item.tracks.count)")
        }
        if isLive {
            lines.append("时间：直播")
        } else if duration > 0 {
            lines.append("时长：\(Int(duration))s / 当前 \(Int(currentTime))s")
        }
        if let errorMessage { lines.append("错误：\(errorMessage)") }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("版本：\(version) (\(build))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - VLC delegate

#if canImport(MobileVLCKit)
extension PlayerController: VLCMediaPlayerDelegate {

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            guard let self, self.backend == .vlc,
                  let player = self.vlcPlayer as? VLCMediaPlayer else { return }
            switch player.state {
            case .playing:
                self.isPlaying = true
            case .paused, .stopped:
                self.isPlaying = false
            case .error:
                self.isPlaying = false
                if !(self.isCatchUpPlayback && self.retryCatchUpWithSystem()) {
                    self.errorMessage = "VLC 播放失败：格式或网络不可用"
                }
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            guard let self, self.backend == .vlc,
                  let player = self.vlcPlayer as? VLCMediaPlayer else { return }
            self.currentTime = max(0, Double(player.time.intValue) / 1000)
            let length = player.media.map { Double($0.length.intValue) / 1000 } ?? 0
            if length > 0 {
                self.duration = length
                self.isLive = false
            } else {
                self.duration = 0
                self.isLive = true
            }
            self.updateVideoSize(player.videoSize)
        }
    }

    nonisolated func mediaPlayerEncounteredError(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            guard let self, self.backend == .vlc else { return }
            if !(self.isCatchUpPlayback && self.retryCatchUpWithSystem()) {
                self.errorMessage = "VLC 无法播放该流"
            }
            self.isPlaying = false
        }
    }

    nonisolated func mediaPlayerEndReached(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            self?.onEnded?()
        }
    }
}
#endif
