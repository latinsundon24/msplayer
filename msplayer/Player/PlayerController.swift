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
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?

    private var openToken = UUID()
    private var wantsPlayback = true
    private var rate: Float = 1
    private var proxyAttempted = false
    private var vlcFallbackTried = false
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
            Task { @MainActor in
                self?.handleSystemTick(time)
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

    // MARK: - 打开频道

    func open(channel: Channel, lineIndex: Int = 0) {
        stopCurrent()
        currentChannel = channel
        self.lineIndex = lineIndex
        proxyAttempted = false
        vlcFallbackTried = false
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
        case .idle:
            break
        }
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
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
    }

    func stopCurrent() {
        openToken = UUID()
        dash?.stop()
        dash = nil
        proxy?.stop()
        proxy = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        #if canImport(MobileVLCKit)
        (vlcPlayer as? VLCMediaPlayer)?.stop()
        #endif
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
            return onlyVLC && canUseVLC
        }
    }

    private func start(url: URL, headers: [String: String], channel: Channel) {
        if shouldUseVLC(url: url, channel: channel) {
            startVLC(url: url, headers: headers)
        } else {
            startSystem(url: url, headers: headers, channel: channel)
        }
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
            Task { @MainActor in
                guard let self, item === self.avPlayer.currentItem else { return }
                if item.status == .failed { self.reportSystemError(item) }
                if item.status == .readyToPlay { self.onPlaybackStarted?() }
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportSystemError(item)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onEnded?()
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        if wantsPlayback {
            avPlayer.playImmediately(atRate: rate)
            isPlaying = true
        }
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
        if canUseVLC, !vlcFallbackTried, Store.shared.settings.decoder != .system,
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
            switch key.lowercased() {
            case "user-agent":
                media.addOption(":http-user-agent=\(value)")
            case "referer":
                media.addOption(":http-referrer=\(value)")
            default:
                media.addOption(":http-\(key.lowercased())=\(value)")
            }
        }
        media.addOption(":network-caching=1200")
        media.addOption(":live-caching=1200")
        media.addOption(":clock-jitter=0")

        if let drawable = vlcDrawable {
            player.drawable = drawable
        }
        player.media = media
        player.play()
        isPlaying = true
        onPlaybackStarted?()
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
        lines.append("解码：\(backend == .vlc ? "VLC" : backend == .system ? "AVPlayer" : "—")")
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
                self.errorMessage = "VLC 播放失败：格式或网络不可用"
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
            let length = Double(player.media.length.intValue) / 1000
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
            self.errorMessage = "VLC 无法播放该流"
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
