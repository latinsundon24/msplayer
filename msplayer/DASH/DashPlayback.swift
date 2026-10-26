import Foundation

/// DASH（含 ClearKey CENC）→ 本地 HLS 的播放会话。
///
/// 管线：
///   MPD 解析 → 选码流 → 下载 init/分片 → ClearKey 解密 → 内存 HLS → AVPlayer
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

    let channel: Channel
    private var manifestURL: URL

    private(set) var document: MPDDocument?
    private(set) var videoStream: DASHStream?
    private(set) var audioStream: DASHStream?

    private var initVideo: Data?
    private var initAudio: Data?
    private var infoVideo = MP4Crypto.InitInfo()
    private var infoAudio = MP4Crypto.InitInfo()
    private var encryptedVideo = false
    private var encryptedAudio = false

    private var keys: [String: String] = [:]

    private var windowVideo: [DASHStream.Segment] = []
    private var windowAudio: [DASHStream.Segment] = []
    private var mapVideo: [String: DASHStream.Segment] = [:]
    private var mapAudio: [String: DASHStream.Segment] = [:]
    private var droppedVideo = 0
    private var droppedAudio = 0
    private var lastNumberVideo = -1
    private var lastNumberAudio = -1
    private var lastTimeVideo: Double = -1
    private var lastTimeAudio: Double = -1

    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 48 * 1024 * 1024

    private var server: LocalHTTPServer?
    private var liveTask: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    init(channel: Channel) throws {
        self.channel = channel
        guard let url = URL(string: channel.url) else {
            throw Failure.manifest("无效地址")
        }
        self.manifestURL = url
        self.keys = channel.keys
    }

    var isLive: Bool { document?.isDynamic ?? false }
    var isEncrypted: Bool { encryptedVideo || encryptedAudio }

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

        let (video, audio) = try selectStreams(doc: doc, period: period)
        videoStream = video
        audioStream = audio
        guard video != nil || audio != nil else { throw Failure.noStream }

        // 有些 MPD 只在 <MPD> 上声明总时长
        if period.duration == nil, let total = doc.mediaPresentationDuration {
            period.duration = max(0, total - (period.start ?? 0))
        }

        if keys.isEmpty, let license = channel.licenseURL {
            await loadRemoteKeys(license)
        }

        if let video {
            let (data, info) = try await fetchInit(for: video)
            if let data {
                initVideo = MP4Crypto.stripEncryption(from: data)
                infoVideo = info
                encryptedVideo = info.isProtected
            }
        }
        if let audio {
            let (data, info) = try await fetchInit(for: audio)
            if let data {
                initAudio = MP4Crypto.stripEncryption(from: data)
                infoAudio = info
                encryptedAudio = info.isProtected
            }
        }

        if (encryptedVideo || encryptedAudio) && keys.isEmpty {
            throw Failure.unsupported("该 DASH 流已加密，但播放列表没有提供 ClearKey（license_key）")
        }

        if doc.isDynamic {
            refreshWindow(doc: doc, period: period, initial: true)
            // 等直播窗口里至少有 2 个分片，避免 AVPlayer 拿到空清单
            var waited = 0
            while waited < 20, currentWindowCount() < 2 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
                if let fresh = try? await fetchDocument() {
                    document = fresh
                    if let freshPeriod = fresh.periods.first {
                        refreshWindow(doc: fresh, period: freshPeriod, initial: false)
                    }
                }
            }
            startLiveLoop()
        } else {
            loadStaticSegments(period: period)
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
        NSLog("[msplayer] DASH ready: %@ (live=%@, videoEnc=%@, audioEnc=%@, keys=%d)",
              url.absoluteString,
              doc.isDynamic ? "yes" : "no",
              encryptedVideo ? "yes" : "no",
              encryptedAudio ? "yes" : "no",
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

    // MARK: - 选择码流

    private func selectStreams(doc: MPDDocument, period: MPDPeriod) throws -> (DASHStream?, DASHStream?) {
        var videoCandidates: [(MPDAdaptation, MPDRepresentation)] = []
        var audioCandidates: [(MPDAdaptation, MPDRepresentation)] = []

        for adaptation in period.adaptations {
            let isVideo = adaptation.isVideo || adaptation.representations.contains {
                ($0.mimeType ?? "").contains("video") || ($0.codecs ?? "").lowercased().hasPrefix("avc")
                    || ($0.codecs ?? "").lowercased().hasPrefix("hvc") || ($0.codecs ?? "").lowercased().hasPrefix("hev")
            }
            let isAudio = adaptation.isAudio || adaptation.representations.contains {
                ($0.mimeType ?? "").contains("audio") || ($0.codecs ?? "").lowercased().hasPrefix("mp4a")
            }
            guard !adaptation.representations.isEmpty else { continue }

            if isVideo, !isAudio {
                if let best = adaptation.representations.max(by: { $0.bandwidth < $1.bandwidth }) {
                    videoCandidates.append((adaptation, best))
                }
            } else if isAudio, !isVideo {
                if let best = adaptation.representations.max(by: { $0.bandwidth < $1.bandwidth }) {
                    audioCandidates.append((adaptation, best))
                }
            }
        }

        // 常见：video 带宽最高者
        let videoPick = videoCandidates.max { $0.1.bandwidth < $1.1.bandwidth }
        let audioPick = audioCandidates.max { $0.1.bandwidth < $1.1.bandwidth }

        var video: DASHStream?
        var audio: DASHStream?

        if let (adaptation, rep) = videoPick {
            video = makeStream(kind: .video, doc: doc, period: period, adaptation: adaptation, rep: rep)
        }
        if let (adaptation, rep) = audioPick {
            audio = makeStream(kind: .audio, doc: doc, period: period, adaptation: adaptation, rep: rep)
        }

        if video == nil, let first = period.adaptations.first, let rep = first.representations.first {
            video = makeStream(kind: .video, doc: doc, period: period, adaptation: first, rep: rep)
        }
        return (video, audio)
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

    private func fetchInit(for stream: DASHStream) async throws -> (Data?, MP4Crypto.InitInfo) {
        guard let url = stream.initURL else { return (nil, MP4Crypto.InitInfo()) }
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

    private func loadStaticSegments(period: MPDPeriod) {
        lock.lock()
        defer { lock.unlock() }
        if let video = videoStream {
            windowVideo = video.staticSegments()
            mapVideo = Dictionary(uniqueKeysWithValues: windowVideo.map { ("v\($0.key).m4s", $0) })
            lastNumberVideo = windowVideo.last?.number ?? -1
            lastTimeVideo = windowVideo.last?.time ?? -1
        }
        if let audio = audioStream {
            windowAudio = audio.staticSegments()
            mapAudio = Dictionary(uniqueKeysWithValues: windowAudio.map { ("a\($0.key).m4s", $0) })
            lastNumberAudio = windowAudio.last?.number ?? -1
            lastTimeAudio = windowAudio.last?.time ?? -1
        }
    }

    private func refreshWindow(doc: MPDDocument, period: MPDPeriod, initial: Bool) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if let video = videoStream {
            // 直播时间线随服务端前移，先用本次清单刷新模板再算窗口
            video.syncTemplate(from: doc)
            let segments = video.liveSegments(now: now,
                                              availabilityStart: doc.availabilityStartTime,
                                              timeShiftBuffer: doc.timeShiftBufferDepth)
            append(segments, to: &windowVideo, map: &mapVideo,
                   lastTime: &lastTimeVideo, dropped: &droppedVideo, kind: "v", initial: initial)
        }
        if let audio = audioStream {
            audio.syncTemplate(from: doc)
            let segments = audio.liveSegments(now: now,
                                              availabilityStart: doc.availabilityStartTime,
                                              timeShiftBuffer: doc.timeShiftBufferDepth)
            append(segments, to: &windowAudio, map: &mapAudio,
                   lastTime: &lastTimeAudio, dropped: &droppedAudio, kind: "a", initial: initial)
        }
    }

    private func append(_ segments: [DASHStream.Segment],
                        to window: inout [DASHStream.Segment],
                        map: inout [String: DASHStream.Segment],
                        lastTime: inout Double,
                        dropped: inout Int,
                        kind: String,
                        initial: Bool) {
        // 以“呈现时间”去重：时间线滑动时 number 可能整体平移，time 不会
        let keep = 12
        var merged = window
        if initial || merged.isEmpty {
            merged = segments
        } else {
            for segment in segments where segment.time > lastTime + 0.001 {
                merged.append(segment)
            }
        }
        if let last = merged.last { lastTime = max(lastTime, last.time) }

        // 去重（同一 time 只留一个）
        var seen = Set<String>()
        merged = merged.filter { seen.insert($0.key).inserted }

        if merged.count > keep {
            let removeCount = merged.count - keep
            dropped += removeCount
            merged.removeFirst(removeCount)
        }
        for segment in merged {
            map["\(kind)\(segment.key).m4s"] = segment
        }
        // 只保留最近的映射，避免无界增长
        if map.count > 96 {
            let sorted = map.sorted { $0.value.time < $1.value.time }
            for item in sorted.prefix(map.count - 96) { map.removeValue(forKey: item.key) }
        }
        window = merged
    }

    private func currentWindowCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return max(windowVideo.count, windowAudio.count)
    }

    private func prefetchLatest() {
        lock.lock()
        let videoSegment = windowVideo.last
        let audioSegment = windowAudio.last
        lock.unlock()

        if let videoSegment, cachedSegment("v\(videoSegment.key).m4s") == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.loadSegment(videoSegment, kind: "v", prefetch: false)
            }
        }
        if let audioSegment, cachedSegment("a\(audioSegment.key).m4s") == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.loadSegment(audioSegment, kind: "a", prefetch: false)
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
                    self.videoStream?.updateBaseURL(manifest: manifest, doc: fresh, period: freshPeriod)
                    self.audioStream?.updateBaseURL(manifest: manifest, doc: fresh, period: freshPeriod)
                    self.refreshWindow(doc: fresh, period: freshPeriod, initial: false)
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

        switch name {
        case "master.m3u8":
            return (200, "application/vnd.apple.mpegurl", Data(masterPlaylist().utf8))
        case "v.m3u8":
            guard videoStream != nil else { return (404, "text/plain", Data()) }
            return (200, "application/vnd.apple.mpegurl", Data(mediaPlaylist(kind: "v").utf8))
        case "a.m3u8":
            guard audioStream != nil else { return (404, "text/plain", Data()) }
            return (200, "application/vnd.apple.mpegurl", Data(mediaPlaylist(kind: "a").utf8))
        case "v-init.mp4":
            guard let data = initVideo else { return (404, "text/plain", Data()) }
            return (200, "video/mp4", data)
        case "a-init.mp4":
            guard let data = initAudio else { return (404, "text/plain", Data()) }
            return (200, "video/mp4", data)
        default:
            guard name.hasSuffix(".m4s"), let first = name.first else {
                return (404, "text/plain", Data())
            }
            let kind = first == "a" ? "a" : "v"
            if let cached = cachedSegment(name) {
                return (200, "video/iso.segment", cached)
            }
            guard let segment = segment(named: name) else {
                return (404, "text/plain", Data())
            }
            guard let data = loadSegment(segment, kind: kind) else {
                return (503, "text/plain", Data())
            }
            return (200, "video/iso.segment", data)
        }
    }

    private func segment(named name: String) -> DASHStream.Segment? {
        lock.lock()
        defer { lock.unlock() }
        return mapVideo[name] ?? mapAudio[name]
    }

    // MARK: - 播放列表

    private func masterPlaylist() -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"

        let hasAudio = audioStream != nil
        let hasVideo = videoStream != nil
        if !hasVideo, hasAudio {
            text += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(audioStream?.bandwidth ?? 128000, 64000))\n"
            text += "a.m3u8\n"
            return text
        }

        if hasAudio {
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\"\n"
        }

        var attributes: [String] = []
        let videoBandwidth = videoStream?.bandwidth ?? 2_000_000
        let audioBandwidth = audioStream?.bandwidth ?? 0
        attributes.append("BANDWIDTH=\(videoBandwidth + audioBandwidth)")

        var codecs: [String] = []
        if let videoCodec = videoStream?.representation.codecs, !videoCodec.isEmpty { codecs.append(videoCodec) }
        if let audioCodec = audioStream?.representation.codecs, !audioCodec.isEmpty { codecs.append(audioCodec) }
        if !codecs.isEmpty {
            attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
        }
        if let width = videoStream?.width, let height = videoStream?.height, width > 0, height > 0 {
            attributes.append("RESOLUTION=\(width)x\(height)")
        }
        if hasAudio { attributes.append("AUDIO=\"aud\"") }

        text += "#EXT-X-STREAM-INF:" + attributes.joined(separator: ",") + "\n"
        text += "v.m3u8\n"
        return text
    }

    private func mediaPlaylist(kind: String) -> String {
        lock.lock()
        let window = kind == "a" ? windowAudio : windowVideo
        let dropped = kind == "a" ? droppedAudio : droppedVideo
        let initName = kind == "a" ? "a-init.mp4" : "v-init.mp4"
        let live = isLive
        lock.unlock()

        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        let maxDuration = window.map { $0.duration }.max() ?? 2
        text += "#EXT-X-TARGETDURATION:\(max(1, Int(ceil(maxDuration))))\n"
        text += "#EXT-X-MEDIA-SEQUENCE:\(dropped)\n"
        if !live {
            text += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        }
        text += "#EXT-X-MAP:URI=\"\(initName)\"\n"
        for segment in window {
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            text += "\(kind)\(segment.key).m4s\n"
        }
        if !live {
            text += "#EXT-X-ENDLIST\n"
        }
        return text
    }

    // MARK: - 分片下载 / 解密

    private func loadSegment(_ segment: DASHStream.Segment, kind: String, prefetch: Bool = true) -> Data? {
        let name = "\(kind)\(segment.key).m4s"
        if let cached = cachedSegment(name) { return cached }
        if stopped { return nil }

        guard let raw = syncFetch(segment.url, attempts: 2) else { return nil }

        let isAudio = kind == "a"
        let encrypted = isAudio ? encryptedAudio : encryptedVideo
        var output = raw

        if encrypted, !keys.isEmpty {
            let info = isAudio ? infoAudio : infoVideo
            do {
                let track = MP4Fragment.parse(raw, defaults: info)
                let decrypted = try CENC.decrypt(fragment: raw, track: track, info: info, keys: keys)
                output = MP4Fragment.stripAuxiliaryBoxes(decrypted)
            } catch {
                NSLog("[msplayer] decrypt failed %@: %@", name, String(describing: error))
                return nil
            }
        }

        store(name: name, data: output)
        if prefetch { prefetchNext(after: segment, kind: kind) }
        return output
    }

    /// 预取后面 2 个分片，减少起播/连续播放卡顿
    private func prefetchNext(after segment: DASHStream.Segment, kind: String) {
        lock.lock()
        let window = kind == "a" ? windowAudio : windowVideo
        lock.unlock()
        guard let index = window.firstIndex(where: { $0.key == segment.key }) else { return }
        for next in window.dropFirst(index + 1).prefix(2) {
            let name = "\(kind)\(next.key).m4s"
            if cachedSegment(name) != nil { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.loadSegment(next, kind: kind, prefetch: false)
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
