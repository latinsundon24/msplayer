import Foundation

/// DASH（含 ClearKey CENC）→ 本地 HLS 的播放会话。
///
/// 管线：
///   MPD 解析 → 选码流（多档清晰度 / 多音轨 / 多字幕）→ 下载 init/分片 → ClearKey 解密 → 内存 HLS → AVPlayer
///
/// 本地 HLS 用**前缀**区分同类里的不同轨道：`v0 / v1`（清晰度）、`a0 / a1`（语言）、`s0 / s1`（字幕）。
/// 生成的主清单把它们写成多个 `#EXT-X-STREAM-INF` 与两条 media group，
/// 之后由 AVFoundation 自己做码率自适应，并在 `AVPlayerItem` 上把音轨 / 字幕暴露成可选项。
final class DashPlayback {

    enum Failure: LocalizedError {
        case manifest(String)
        case noStream
        case initFailed
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .manifest(let message): return "MPD 解析失败：\(message)"
            case .noStream: return "MPD 里没有可播放的音视频流"
            case .initFailed: return "初始化分片下载失败"
            case .unsupported(let what): return "暂不支持：\(what)"
            }
        }
    }

    // MARK: - 轨道

    /// 一条可播轨道：视频的一档清晰度 / 一条语言音轨 / 一条字幕轨。
    ///
    /// 每条轨道各自持有 init、解密信息、可播窗口与分片映射，互不干扰。
    final class Track {
        let index: Int
        /// 本地 HLS 的文件前缀（`v0` / `a1` / `s0`…），用来区分不同轨道
        let prefix: String
        let stream: DASHStream
        let lang: String?
        /// 展示名，写进 `#EXT-X-MEDIA` 的 NAME
        let title: String

        var initData: Data?
        var info = MP4Crypto.InitInfo()
        var encrypted = false

        var window: [DASHStream.Segment] = []
        var map: [String: DASHStream.Segment] = [:]
        var dropped = 0
        var lastTime: Double = -1
        var lastNumber = -1

        init(index: Int, prefix: String, stream: DASHStream, lang: String?, title: String) {
            self.index = index
            self.prefix = prefix
            self.stream = stream
            self.lang = lang
            self.title = title
        }

        var isSubtitle: Bool { stream.kind == .subtitle }
        var playlistName: String { "\(prefix).m3u8" }
        var initName: String { "\(prefix)-init.mp4" }

        /// 该轨道某个分片在本地 HLS 里的文件名（字幕对外是 .vtt，音视频是 .m4s）
        func segmentName(key: String) -> String {
            "\(prefix)\(key)" + (isSubtitle ? ".vtt" : ".m4s")
        }
    }

    /// 同类轨道保留上限，避免清单与内存无谓膨胀
    private static let maxVideoTracks = 6
    private static let maxAudioTracks = 4
    private static let maxSubtitleTracks = 4

    let channel: Channel
    private var manifestURL: URL

    private(set) var document: MPDDocument?

    private var videoTracks: [Track] = []
    private var audioTracks: [Track] = []
    private var subtitleTracks: [Track] = []

    private var keys: [String: String] = [:]

    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 48 * 1024 * 1024

    private var server: LocalHTTPServer?
    private var liveTask: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// 全部轨道
    private var everyTrack: [Track] { videoTracks + audioTracks + subtitleTracks }

    init(channel: Channel) throws {
        self.channel = channel
        guard let url = URL(string: channel.url) else {
            throw Failure.manifest("无效地址")
        }
        self.manifestURL = url
        self.keys = channel.keys
    }

    var isLive: Bool { document?.isDynamic ?? false }
    var isEncrypted: Bool { everyTrack.contains { $0.encrypted } }

    // MARK: - 生命周期

    func start() async throws -> URL {
        NSLog("[msplayer] DASH manifest: %@", channel.url)
        let response = try await HTTPService.fetch(channel.url, headers: channel.headers)
        // 跟随重定向后，相对地址要以最终 URL 为基准
        if let finalURL = response.finalURL {
            manifestURL = finalURL
        }
        guard let doc = MPDParser.parse(data: response.data) else {
            throw Failure.manifest("XML 解析失败")
        }
        document = doc
        guard let period = doc.periods.first else { throw Failure.noStream }

        buildTracks(doc: doc, period: period)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw Failure.noStream }

        // 有些 MPD 只在 <MPD> 上声明总时长
        if period.duration == nil, let total = doc.mediaPresentationDuration {
            period.duration = max(0, total - (period.start ?? 0))
        }

        if keys.isEmpty, let license = channel.licenseURL {
            await loadRemoteKeys(license)
        }

        for track in videoTracks + audioTracks {
            guard let url = track.stream.initURL else { continue }
            let (data, info) = try await fetchInit(url)
            if let data {
                track.initData = MP4Crypto.stripEncryption(from: data)
                track.info = info
                track.encrypted = info.isProtected
            }
        }

        if isEncrypted && keys.isEmpty {
            throw Failure.unsupported("该 DASH 流已加密，但播放列表没有提供 ClearKey（license_key）")
        }

        if doc.isDynamic {
            refreshWindow(doc: doc, initial: true)
            // 等直播窗口里至少有 2 个分片，避免 AVPlayer 拿到空清单
            var waited = 0
            while waited < 20, currentWindowCount() < 2 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
                if let fresh = try? await fetchDocument() {
                    document = fresh
                    refreshWindow(doc: fresh, initial: false)
                }
            }
            startLiveLoop()
        } else {
            for track in everyTrack { loadStaticSegments(track) }
        }
        prefetchLatest()

        let server = try LocalHTTPServer { [weak self] path, range in
            guard let self else { return (404, "text/plain", Data()) }
            return self.handle(path: path, range: range)
        }
        self.server = server
        guard let url = URL(string: "http://127.0.0.1:\(server.port)/\(token)/master.m3u8") else {
            throw Failure.manifest("本地地址生成失败")
        }
        NSLog("[msplayer] DASH ready: %@ (live=%@, video=%d, audio=%d, subtitle=%d, encrypted=%@, keys=%d)",
              url.absoluteString,
              doc.isDynamic ? "yes" : "no",
              videoTracks.count,
              audioTracks.count,
              subtitleTracks.count,
              isEncrypted ? "yes" : "no",
              keys.count)
        return url
    }

    func stop() {
        stopped = true
        liveTask?.cancel()
        liveTask = nil
        server?.stop()
        server = nil
        lock.lock()
        cache.removeAll()
        cacheOrder.removeAll()
        lock.unlock()
    }

    // MARK: - 选码流

    /// 挑出全部可播轨道：多档视频（各成一档）、多语言音轨、多字幕轨。
    private func buildTracks(doc: MPDDocument, period: MPDPeriod) {
        videoTracks = []
        audioTracks = []
        subtitleTracks = []

        var videoPicks: [(MPDAdaptation, MPDRepresentation)] = []
        var audioPicks: [(MPDAdaptation, MPDRepresentation)] = []
        var subtitlePicks: [(MPDAdaptation, MPDRepresentation)] = []

        for adaptation in period.adaptations {
            guard !adaptation.representations.isEmpty else { continue }

            let isVideo = adaptation.isVideo || adaptation.representations.contains {
                ($0.mimeType ?? "").contains("video")
                    || ($0.codecs ?? "").lowercased().hasPrefix("avc")
                    || ($0.codecs ?? "").lowercased().hasPrefix("hvc")
                    || ($0.codecs ?? "").lowercased().hasPrefix("hev")
            }
            let isAudio = adaptation.isAudio || adaptation.representations.contains {
                ($0.mimeType ?? "").contains("audio")
                    || ($0.codecs ?? "").lowercased().hasPrefix("mp4a")
            }
            let isSubtitle = (adaptation.contentType?.lowercased() == "text")
                || adaptation.representations.contains {
                    ["stpp", "wvtt"].contains(($0.codecs ?? "").lowercased())
                }

            if isVideo, !isAudio {
                // 快进预览（TrickMode）不是完整帧序列，不能拿来正常播放
                guard !Self.isTrickMode(adaptation) else { continue }
                // 同一 AdaptationSet 内的多个 Representation 就是多档清晰度
                let sorted = adaptation.representations.sorted { $0.bandwidth > $1.bandwidth }
                videoPicks.append(contentsOf: sorted.map { (adaptation, $0) })
            } else if isAudio, !isVideo {
                guard !Self.isTrickMode(adaptation) else { continue }
                // 一个 AdaptationSet 通常就是一条语言，组内取码率最高的一档
                guard let best = adaptation.representations.max(by: { $0.bandwidth < $1.bandwidth }) else { continue }
                audioPicks.append((adaptation, best))
            } else if isSubtitle, !isVideo, !isAudio {
                guard let first = adaptation.representations.first else { continue }
                subtitlePicks.append((adaptation, first))
            }
        }

        videoTracks = Array(videoPicks.prefix(Self.maxVideoTracks)).enumerated().map { offset, pick in
            Track(index: offset,
                  prefix: "v\(offset)",
                  stream: makeStream(kind: .video, doc: doc, period: period,
                                     adaptation: pick.0, rep: pick.1),
                  lang: pick.0.lang,
                  title: Self.displayName(for: pick.0.lang, kind: .video, index: offset))
        }
        audioTracks = Array(audioPicks.prefix(Self.maxAudioTracks)).enumerated().map { offset, pick in
            Track(index: offset,
                  prefix: "a\(offset)",
                  stream: makeStream(kind: .audio, doc: doc, period: period,
                                     adaptation: pick.0, rep: pick.1),
                  lang: pick.0.lang,
                  title: Self.displayName(for: pick.0.lang, kind: .audio, index: offset))
        }
        subtitleTracks = Array(subtitlePicks.prefix(Self.maxSubtitleTracks)).enumerated().map { offset, pick in
            Track(index: offset,
                  prefix: "s\(offset)",
                  stream: makeStream(kind: .subtitle, doc: doc, period: period,
                                     adaptation: pick.0, rep: pick.1),
                  lang: pick.0.lang,
                  title: Self.displayName(for: pick.0.lang, kind: .subtitle, index: offset))
        }
    }

    /// 快进预览流的判定：Representation id 带 TrickMode，或分片模板用了 i 帧专用的 .cmfi
    private static func isTrickMode(_ adaptation: MPDAdaptation) -> Bool {
        if let media = adaptation.segmentTemplate?.media, media.contains("cmfi") { return true }
        return adaptation.representations.contains { rep in
            if rep.id.localizedCaseInsensitiveContains("trickmode") { return true }
            if let media = rep.segmentTemplate?.media, media.contains("cmfi") { return true }
            return false
        }
    }

    private static let languageNames: [String: String] = [
        "zho": "中文", "zh": "中文", "chi": "中文", "chs": "简体中文", "cht": "繁体中文",
        "zh-tw": "繁体中文", "zh-cn": "简体中文", "zh-hk": "繁体中文",
        "eng": "英文", "en": "英文",
        "jpn": "日文", "ja": "日文",
        "kor": "韩文", "ko": "韩文",
        "yue": "粤语", "cmn": "普通话",
        "fra": "法文", "fr": "法文",
        "deu": "德文", "de": "德文",
        "spa": "西班牙文", "es": "西班牙文",
        "rus": "俄文", "ru": "俄文",
        "tha": "泰文", "th": "泰文",
        "vie": "越南文", "vi": "越南文"
    ]

    private static func displayName(for lang: String?, kind: DASHStream.Kind, index: Int) -> String {
        if let lang, !lang.isEmpty, let hit = languageNames[lang.lowercased()] { return hit }
        switch kind {
        case .video: return "清晰度 \(index + 1)"
        case .audio: return "音轨 \(index + 1)"
        case .subtitle: return "字幕 \(index + 1)"
        }
    }

    /// 只有像 `zh` / `chs` / `en-us` 这种才是合法 BCP-47 片段；
    /// TVB 的音轨用 `au1` / `au2` 这种非标准值，写进 LANGUAGE 反而可能被判非法，这里直接跳过该属性。
    private static func isValidLanguageTag(_ lang: String?) -> Bool {
        guard let lang, !lang.isEmpty else { return false }
        return lang.split(separator: "-").allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy { $0.isLetter }
        }
    }

    private func makeStream(kind: DASHStream.Kind,
                            doc: MPDDocument,
                            period: MPDPeriod,
                            adaptation: MPDAdaptation,
                            rep: MPDRepresentation) -> DASHStream {
        let template = mergeTemplate(adaptation: adaptation.segmentTemplate, representation: rep.segmentTemplate)
        var base = manifestURL
        for component in [doc.baseURL, period.baseURL, adaptation.baseURL, rep.baseURL] {
            guard let text = component, !text.isEmpty else { continue }
            if let url = URL(string: text, relativeTo: base) {
                base = url.absoluteURL
            }
        }

        var initURL: URL?
        if let list = rep.segmentList ?? adaptation.segmentList, let source = list.initialization {
            initURL = URL(string: source, relativeTo: base)?.absoluteURL
        } else if let template, let initialization = template.initialization {
            var expanded = initialization
                .replacingOccurrences(of: "$RepresentationID$", with: rep.id)
                .replacingOccurrences(of: "$Bandwidth$", with: String(rep.bandwidth))
            expanded = expandNumberWidth(expanded, number: template.startNumber)
            initURL = URL(string: expanded, relativeTo: base)?.absoluteURL
        }

        return DASHStream(kind: kind,
                          representation: rep,
                          adaptation: adaptation,
                          period: period,
                          template: template,
                          segmentList: rep.segmentList ?? adaptation.segmentList,
                          initURL: initURL,
                          baseURL: base)
    }

    private func mergeTemplate(adaptation: MPDSegmentTemplate?,
                               representation: MPDSegmentTemplate?) -> MPDSegmentTemplate? {
        guard adaptation != nil || representation != nil else { return nil }
        let merged = MPDSegmentTemplate()
        if let a = adaptation {
            merged.media = a.media
            merged.initialization = a.initialization
            merged.timescale = a.timescale
            merged.startNumber = a.startNumber
            merged.duration = a.duration
            merged.pto = a.pto
            merged.timeline = a.timeline
        }
        if let r = representation {
            if let value = r.media { merged.media = value }
            if let value = r.initialization { merged.initialization = value }
            if r.timescale != 1 { merged.timescale = r.timescale }
            if r.startNumber != 1 { merged.startNumber = r.startNumber }
            if let value = r.duration { merged.duration = value }
            if r.pto != 0 { merged.pto = r.pto }
            if !r.timeline.isEmpty { merged.timeline = r.timeline }
        }
        return merged
    }

    private func expandNumberWidth(_ template: String, number: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\$Number(%0(\\d+)d)?\\$") else { return template }
        let ns = template as NSString
        let matches = regex.matches(in: template, options: [], range: NSRange(location: 0, length: ns.length))
        var result = template
        for match in matches.reversed() {
            var replacement = String(number)
            if match.range(at: 2).location != NSNotFound,
               let width = Int(ns.substring(with: match.range(at: 2))) {
                replacement = String(format: "%0\(width)d", number)
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    // MARK: - init / key

    private func fetchInit(_ url: URL) async throws -> (Data?, MP4Crypto.InitInfo) {
        let response = try await HTTPService.fetch(url.absoluteString, headers: channel.headers)
        return (response.data, MP4Crypto.initInfo(from: response.data))
    }

    private func loadRemoteKeys(_ urlString: String) async {
        guard let text = try? await HTTPService.fetchText(urlString, headers: channel.headers) else { return }
        if let parsed = ClearKeyParser.parseInlineJSON(text), !parsed.isEmpty {
            keys = parsed
        }
    }

    // MARK: - 分片窗口

    private func loadStaticSegments(_ track: Track) {
        let segments = track.stream.staticSegments()
        lock.lock()
        defer { lock.unlock() }
        track.window = segments
        track.map = Dictionary(uniqueKeysWithValues: segments.map { (track.segmentName(key: $0.key), $0) })
        track.lastNumber = segments.last?.number ?? -1
        track.lastTime = segments.last?.time ?? -1
    }

    private func refreshWindow(doc: MPDDocument, initial: Bool) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        for track in everyTrack {
            // 直播时间线随服务端前移，先用本次清单刷新模板再算窗口
            track.stream.syncTemplate(from: doc)
            let segments = track.stream.liveSegments(now: now,
                                                     availabilityStart: doc.availabilityStartTime,
                                                     timeShiftBuffer: doc.timeShiftBufferDepth)
            append(segments, to: track, initial: initial)
        }
    }

    private func append(_ segments: [DASHStream.Segment], to track: Track, initial: Bool) {
        // 以“呈现时间”去重：时间线滑动时 number 可能整体平移，time 不会
        let keep = 12
        var merged = track.window
        if initial || merged.isEmpty {
            merged = segments
        } else {
            for segment in segments where segment.time > track.lastTime + 0.001 {
                merged.append(segment)
            }
        }
        if let last = merged.last {
            track.lastTime = max(track.lastTime, last.time)
            track.lastNumber = last.number
        }

        // 去重（同一 time 只留一个）
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.key).inserted }

        if merged.count > keep {
            let removeCount = merged.count - keep
            track.dropped += removeCount
            merged.removeFirst(removeCount)
        }
        for segment in merged {
            track.map[track.segmentName(key: segment.key)] = segment
        }
        // 只保留最近的映射，避免无界增长
        if track.map.count > 96 {
            let sorted = track.map.sorted { $0.value.time < $1.value.time }
            for item in sorted.prefix(track.map.count - 96) { track.map.removeValue(forKey: item.key) }
        }
        track.window = merged
    }

    private func currentWindowCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let video = videoTracks.map { $0.window.count }.max() ?? 0
        let audio = audioTracks.map { $0.window.count }.max() ?? 0
        return max(video, audio)
    }

    /// 只预取每类的第一条轨道：多清晰度 / 多音轨下同一时刻只有一路会被真正下载，
    /// 全都预取等于白搭几倍带宽。正在播的那一档仍会由 `prefetchNext` 顺带预取。
    private func prefetchLatest() {
        lock.lock()
        var targets: [(Track, DASHStream.Segment)] = []
        for track in [videoTracks.first, audioTracks.first].compactMap({ $0 }) {
            if let last = track.window.last { targets.append((track, last)) }
        }
        lock.unlock()

        for (track, segment) in targets {
            if cachedSegment(track.segmentName(key: segment.key)) != nil { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.loadSegment(segment, track: track, prefetch: false)
            }
        }
    }

    private func fetchDocument() async throws -> MPDDocument? {
        let response = try await HTTPService.fetch(channel.url, headers: channel.headers)
        return MPDParser.parse(data: response.data)
    }

    private func startLiveLoop() {
        liveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let interval = max(1.0, min(self.document?.minimumUpdatePeriod ?? 2, 6))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled || self.stopped { return }
                guard self.document != nil else { continue }
                do {
                    let response = try await HTTPService.fetch(self.channel.url, headers: self.channel.headers)
                    guard let fresh = MPDParser.parse(data: response.data),
                          let freshPeriod = fresh.periods.first else { continue }

                    self.document = fresh
                    // 边缘 session / token 写在重定向后的地址上，跟着清单刷新走
                    let manifest = response.finalURL ?? self.manifestURL
                    self.manifestURL = manifest
                    for track in self.everyTrack {
                        track.stream.updateBaseURL(manifest: manifest, doc: fresh, period: freshPeriod)
                    }
                    self.refreshWindow(doc: fresh, initial: false)
                    self.prefetchLatest()
                } catch {
                    // 直播刷新失败不致命，下一轮再试
                }
            }
        }
    }

    // MARK: - HTTP

    private func handle(path: String, range: String?) -> (Int, String, Data) {
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return (404, "text/plain", Data()) }
        let name = String(path.dropFirst(prefix.count))

        if name == "master.m3u8" {
            return (200, "application/vnd.apple.mpegurl", Data(masterPlaylist().utf8))
        }

        for track in everyTrack {
            if name == track.playlistName {
                return (200, "application/vnd.apple.mpegurl", Data(mediaPlaylist(track: track).utf8))
            }
            if name == track.initName {
                guard let data = track.initData else { return (404, "text/plain", Data()) }
                return (200, "video/mp4", data)
            }
        }

        return serveSegment(name: name)
    }

    private func lookupSegment(_ name: String) -> (Track, DASHStream.Segment)? {
        lock.lock()
        defer { lock.unlock() }
        for track in everyTrack {
            if let segment = track.map[name] { return (track, segment) }
        }
        return nil
    }

    private func serveSegment(name: String) -> (Int, String, Data) {
        guard let (track, segment) = lookupSegment(name) else {
            return (404, "text/plain", Data())
        }

        let contentType = track.isSubtitle ? "text/vtt" : "video/iso.segment"
        if let cached = cachedSegment(name) { return (200, contentType, cached) }

        if track.isSubtitle {
            // 字幕是明流的 ISOBMFF（stpp），取 mdat 里的 TTML 转成 WebVTT 再交给 AVPlayer
            guard let raw = syncFetch(segment.url, attempts: 2),
                  let text = TTMLSubtitle.webVTT(from: raw,
                                                 startTime: segment.time,
                                                 duration: segment.duration),
                  let data = text.data(using: .utf8) else {
                return (503, "text/plain", Data())
            }
            store(name: name, data: data)
            return (200, contentType, data)
        }

        guard let data = loadSegment(segment, track: track) else {
            return (503, "text/plain", Data())
        }
        return (200, contentType, data)
    }

    // MARK: - 播放列表

    private func masterPlaylist() -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"

        // 没有视频时（纯音频流），每条音轨各自成一个 variant
        if videoTracks.isEmpty {
            for track in audioTracks {
                var attributes = ["BANDWIDTH=\(max(track.stream.bandwidth, 64000))"]
                if let codec = track.stream.representation.codecs, !codec.isEmpty {
                    attributes.append("CODECS=\"\(codec)\"")
                }
                text += "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",") + "\n"
                text += "\(track.playlistName)\n"
            }
            return text
        }

        if !audioTracks.isEmpty {
            for (offset, track) in audioTracks.enumerated() {
                text += mediaTag("AUDIO", group: "aud", track: track,
                                 defaulted: offset == 0, autoselect: true)
            }
        }
        if !subtitleTracks.isEmpty {
            for track in subtitleTracks {
                // 字幕默认关：避免还没验证过的转换结果一进来就糊在画面上
                text += mediaTag("SUBTITLES", group: "sub", track: track,
                                 defaulted: false, autoselect: false)
            }
        }

        for track in videoTracks {
            var attributes: [String] = []
            let audioBandwidth = audioTracks.first?.stream.bandwidth ?? 0
            attributes.append("BANDWIDTH=\(max(track.stream.bandwidth, 200_000) + audioBandwidth)")

            var codecs: [String] = []
            if let videoCodec = track.stream.representation.codecs, !videoCodec.isEmpty { codecs.append(videoCodec) }
            if let audioCodec = audioTracks.first?.stream.representation.codecs, !audioCodec.isEmpty { codecs.append(audioCodec) }
            if !codecs.isEmpty {
                attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
            }
            if let width = track.stream.width, let height = track.stream.height, width > 0, height > 0 {
                attributes.append("RESOLUTION=\(width)x\(height)")
            }
            if !audioTracks.isEmpty { attributes.append("AUDIO=\"aud\"") }
            if !subtitleTracks.isEmpty { attributes.append("SUBTITLES=\"sub\"") }

            text += "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",") + "\n"
            text += "\(track.playlistName)\n"
        }
        return text
    }

    /// 生成 `#EXT-X-MEDIA`（音轨 / 字幕）
    private func mediaTag(_ type: String,
                          group: String,
                          track: Track,
                          defaulted: Bool,
                          autoselect: Bool) -> String {
        var attributes = ["TYPE=\(type)", "GROUP-ID=\"\(group)\"", "NAME=\"\(track.title)\""]
        if Self.isValidLanguageTag(track.lang) {
            attributes.append("LANGUAGE=\"\(track.lang ?? "")\"")
        }
        attributes.append(defaulted ? "DEFAULT=YES" : "DEFAULT=NO")
        attributes.append(autoselect ? "AUTOSELECT=YES" : "AUTOSELECT=NO")
        attributes.append("URI=\"\(track.playlistName)\"")
        return "#EXT-X-MEDIA:" + attributes.joined(separator: ",") + "\n"
    }

    private func mediaPlaylist(track: Track) -> String {
        lock.lock()
        let window = track.window
        let dropped = track.dropped
        let live = isLive
        lock.unlock()

        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        let maxDuration = window.map { $0.duration }.max() ?? 2
        text += "#EXT-X-TARGETDURATION:\(max(1, Int(ceil(maxDuration))))\n"
        text += "#EXT-X-MEDIA-SEQUENCE:\(dropped)\n"
        if !live {
            text += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        }
        // WebVTT 没有 init 段
        if !track.isSubtitle {
            text += "#EXT-X-MAP:URI=\"\(track.initName)\"\n"
        }
        for segment in window {
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            text += "\(track.segmentName(key: segment.key))\n"
        }
        if !live {
            text += "#EXT-X-ENDLIST\n"
        }
        return text
    }

    // MARK: - 分片下载 / 解密

    private func loadSegment(_ segment: DASHStream.Segment, track: Track, prefetch: Bool = true) -> Data? {
        let name = track.segmentName(key: segment.key)
        if let cached = cachedSegment(name) { return cached }
        if stopped { return nil }

        guard let raw = syncFetch(segment.url, attempts: 2) else { return nil }

        var output = raw
        if track.encrypted, !keys.isEmpty {
            do {
                let parsed = MP4Fragment.parse(raw, defaults: track.info)
                let decrypted = try CENC.decrypt(fragment: raw, track: parsed, info: track.info, keys: keys)
                output = MP4Fragment.stripAuxiliaryBoxes(decrypted)
            } catch {
                NSLog("[msplayer] decrypt failed %@: %@", name, String(describing: error))
                return nil
            }
        }

        store(name: name, data: output)
        if prefetch { prefetchNext(after: segment, track: track) }
        return output
    }

    /// 预取后面 2 个分片，减少起播/连续播放卡顿
    private func prefetchNext(after segment: DASHStream.Segment, track: Track) {
        lock.lock()
        let window = track.window
        lock.unlock()
        guard let index = window.firstIndex(where: { $0.key == segment.key }) else { return }
        for next in window.dropFirst(index + 1).prefix(2) {
            let captured = next
            if cachedSegment(track.segmentName(key: captured.key)) != nil { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.loadSegment(captured, track: track, prefetch: false)
            }
        }
    }

    private func syncFetch(_ url: URL, attempts: Int) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SegmentBox()
        Task {
            for attempt in 0..<max(1, attempts) {
                if self.stopped { break }
                do {
                    let response = try await HTTPService.fetch(url.absoluteString, headers: self.channel.headers)
                    box.set(response.data)
                    break
                } catch {
                    if attempt + 1 < attempts {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 25)
        return box.value
    }

    private func cachedSegment(_ name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cache[name]
    }

    private func store(name: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if cache[name] == nil {
            cacheOrder.append(name)
            cache[name] = data
        }
        var total = cache.reduce(0) { $0 + $1.value.count }
        while total > cacheLimit, cacheOrder.count > 2 {
            let oldest = cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                total -= removed.count
            }
        }
    }
}

/// 跨线程传递一次分片数据
final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func set(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
