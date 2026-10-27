import Foundation

/// 一条 DASH 码流（视频或音频）的选择结果与分片计算
final class DASHStream {

    enum Kind: String {
        case video
        case audio
        case subtitle
    }

    let kind: Kind
    let representation: MPDRepresentation
    let adaptation: MPDAdaptation
    let period: MPDPeriod
    var template: MPDSegmentTemplate?
    let segmentList: MPDSegmentList?
    let initURL: URL?
    var baseURL: URL

    init(kind: Kind,
         representation: MPDRepresentation,
         adaptation: MPDAdaptation,
         period: MPDPeriod,
         template: MPDSegmentTemplate?,
         segmentList: MPDSegmentList?,
         initURL: URL?,
         baseURL: URL) {
        self.kind = kind
        self.representation = representation
        self.adaptation = adaptation
        self.period = period
        self.template = template
        self.segmentList = segmentList
        self.initURL = initURL
        self.baseURL = baseURL
    }

    var bandwidth: Int { representation.bandwidth }
    var codecs: String? { representation.codecs ?? adaptation.mimeType }
    var width: Int? { representation.width ?? adaptation.width }
    var height: Int? { representation.height ?? adaptation.height }

    var mimeType: String? { representation.mimeType ?? adaptation.mimeType }

    var language: String? { adaptation.lang }

    /// `@presentationTimeOffset`（秒）。
    ///
    /// 清单里的 `$Time$` 是 presentation 时间轴，减掉 PTO 才是 Period 内的相对时间；
    /// `liveSegments` 里算的 `startSeconds` 已经做过这个修正，要还原墙钟时刻得把它加回去。
    var presentationTimeOffset: Double {
        guard let template else { return 0 }
        let ts = template.timescale > 0 ? template.timescale : 1
        return template.pto / ts
    }

    // MARK: - 分片

    struct Segment {
        let url: URL
        let duration: Double
        let time: Double
        let number: Int
        /// 稳定标识：直播时间线滑动时命名不会变
        let key: String
    }

    /// 计算静态（点播）清单的全部分片
    func staticSegments() -> [Segment] {
        if let list = segmentList {
            let ts = list.timescale > 0 ? list.timescale : 1
            let dur = (list.duration ?? 0) / ts
            return list.urls.enumerated().map { index, media in
                let url = resolve(media) ?? baseURL
                return Segment(url: url,
                               duration: dur,
                               time: Double(index) * dur,
                               number: index + 1,
                               key: "i\(index)")
            }
        }
        guard let template = template else { return [] }

        let duration = period.duration ?? 0
        let ts = template.timescale > 0 ? template.timescale : 1

        if !template.timeline.isEmpty {
            var out: [Segment] = []
            for (position, entry) in expandedTimeline().enumerated() {
                let number = template.startNumber + position
                let urlString = expand(template.media ?? "", number: number, time: entry.t)
                guard let url = resolve(urlString) else { continue }
                out.append(Segment(url: url, duration: entry.d/ts, time: entry.t/ts, number: number,
                                   key: "t\(Int64(entry.t))"))
            }
            return out
        }

        guard let segDuration = template.duration, segDuration > 0 else { return [] }
        let segSeconds = segDuration / ts
        let total = duration > 0 ? Int(ceil(duration / segSeconds)) : 0
        var out: [Segment] = []
        for i in 0..<max(0, total) {
            let number = template.startNumber + i
            let urlString = expand(template.media ?? "", number: number, time: (template.pto + Double(i) * segDuration))
            guard let url = resolve(urlString) else { continue }
            // 最后一片常常是残片，按总时长收敛，避免清单总长虚高
            var actual = segSeconds
            if duration > 0, i == total - 1 {
                actual = max(0.001, duration - Double(i) * segSeconds)
            }
            out.append(Segment(url: url, duration: actual, time: Double(i) * segSeconds, number: number,
                               key: "n\(number)"))
        }
        return out
    }

    /// 动态（直播）清单：返回当前可播窗口内、已经发布的分片
    func liveSegments(now: Date,
                      availabilityStart: Date?,
                      timeShiftBuffer: Double?,
                      maxCount: Int = 24) -> [Segment] {
        guard let template = template else {
            return Array(staticSegments().suffix(maxCount))
        }
        let ts = template.timescale > 0 ? template.timescale : 1
        let periodStart = period.start ?? 0
        let ptoSeconds = template.pto / ts

        var mediaElapsed: Double?
        if let ast = availabilityStart {
            let value = now.timeIntervalSince(ast) - periodStart - ptoSeconds
            if value > 0 { mediaElapsed = value }
        }

        func make(_ number: Int, _ rawTime: Double, _ rawDuration: Double, _ timeSeconds: Double) -> Segment? {
            let urlString = expand(template.media ?? "", number: number, time: rawTime)
            guard let url = resolve(urlString) else { return nil }
            return Segment(url: url,
                           duration: rawDuration / ts,
                           time: timeSeconds,
                           number: number,
                           key: "t\(Int64(rawTime))")
        }

        var candidates: [Segment] = []

        if !template.timeline.isEmpty {
            // 7 天时移的时间线可能有几十万条分片，逐条展开会把每次刷新都拖慢。
            // 这里只从「需要的最后 maxCount 片」附近开始展开，序号照样正确对齐。
            let estSeg = template.timeline.last.map { $0.d / ts } ?? 2
            let fromSeconds = mediaElapsed.map { edge -> Double in
                max(0, edge - Double(maxCount + 16) * max(estSeg, 0.5) - 30)
            }
            let expanded = expandedTimeline(fromSeconds: fromSeconds, maxItems: maxCount + 16)
            for (position, entry) in expanded.items.enumerated() {
                let startSeconds = entry.t / ts - ptoSeconds
                let endSeconds = startSeconds + entry.d / ts
                let number = template.startNumber + expanded.firstIndex + position
                if let edge = mediaElapsed {
                    guard endSeconds <= edge + 0.5 else { continue }
                    if let tsb = timeShiftBuffer, startSeconds < edge - tsb { continue }
                }
                if let segment = make(number, entry.t, entry.d, startSeconds) {
                    candidates.append(segment)
                }
            }
        } else if let segDuration = template.duration, segDuration > 0 {
            guard let edge = mediaElapsed else { return [] }
            let segSeconds = segDuration / ts
            let lastIndex = Int(floor(edge / segSeconds)) - 1
            guard lastIndex >= 0 else { return [] }
            var firstIndex = 0
            if let tsb = timeShiftBuffer {
                firstIndex = max(0, lastIndex - Int(ceil(tsb / segSeconds)))
            }
            firstIndex = max(firstIndex, lastIndex - maxCount + 1)
            for i in firstIndex...lastIndex {
                let number = template.startNumber + i
                if let segment = make(number,
                                      template.pto + Double(i) * segDuration,
                                      segDuration,
                                      Double(i) * segSeconds) {
                    candidates.append(segment)
                }
            }
        }

        return Array(candidates.suffix(maxCount))
    }

    /// 展开 SegmentTimeline。
    ///
    /// 直播清单常用 `r=-1`（一直重复下去），若从第一条开始逐条展开，7 天时移就是几十万条，
    /// 每秒刷新都跑一遍会把主线程拖死。这里直接按时间跳到大致的起点，只展开需要的那些。
    ///
    /// - Parameters:
    ///   - fromSeconds: 只需要这个呈现时刻（秒，已扣除 pto）之后的分片；nil 表示从头展开
    ///   - maxItems: `r=-1` 段最多展开多少条
    /// - Returns: 展开出来的条目，以及第一条在整条时间线里的下标（算 media number 用）
    private func expandedTimeline(fromSeconds: Double? = nil,
                                  maxItems: Int? = nil) -> (items: [(t: Double, d: Double)], firstIndex: Int) {
        guard let template else { return ([], 0) }
        var out: [(t: Double, d: Double)] = []
        var current: Double = 0
        var index = 0
        var firstIndex = -1
        let ts = template.timescale > 0 ? template.timescale : 1
        let periodEnd = (period.duration ?? 0) * ts

        // 需要的最早原始时间戳（timeline 里的 t 含 pto，换算回 raw 才好比较）
        let needRaw = fromSeconds.map { ($0 + template.pto / ts) * ts }

        func take(_ t: Double, _ d: Double) {
            if firstIndex < 0 { firstIndex = index }
            out.append((t, d))
            index += 1
        }

        for entry in template.timeline {
            if entry.t > 0 { current = entry.t }
            if entry.r < 0 {
                // r = -1：一直重复到 Period 结束；直播清单没有总时长时，先展开一段足够长的窗口
                var t = current
                var guardCount = 0
                if let needRaw, entry.d > 0, needRaw > t {
                    // 起点之前的分片整段跳过；序号要同步累加，否则 media number 会错位
                    let skip = Int(floor((needRaw - t) / entry.d))
                    if skip > 0 {
                        t += Double(skip) * entry.d
                        index += skip
                        current = t
                    }
                }
                let cap = periodEnd > 0 ? 20000 : (maxItems ?? 600)
                while guardCount < cap {
                    if periodEnd > 0 && t + entry.d > periodEnd { break }
                    take(t, entry.d)
                    t += entry.d
                    guardCount += 1
                }
                current = t
            } else {
                for _ in 0..<(entry.r + 1) {
                    take(current, entry.d)
                    current += entry.d
                }
            }
        }
        return (out, max(firstIndex, 0))
    }

    // MARK: - 直播刷新

    /// 直播清单刷新后同步 SegmentTemplate。
    ///
    /// SegmentTimeline 型直播的时间线 `t` 是绝对时间戳，服务端每次刷新都会整体前移；
    /// 若一直使用起播那帧的时间线，可播窗口的尽头会停在起播时刻，
    /// 播完 `keep` 个分片后就再没有新分片可用（表现为“播几十秒就停”）。
    /// 因此每次刷新都要按 Representation id 匹配，把最新的 media / timescale / timeline 等覆盖过来。
    ///
    /// - Parameter doc: 本次重新拉取并解析得到的 MPD。
    func syncTemplate(from doc: MPDDocument) {
        guard let freshPeriod = doc.periods.first else { return }
        for adaptation in freshPeriod.adaptations {
            for rep in adaptation.representations where rep.id == representation.id {
                let source = rep.segmentTemplate ?? adaptation.segmentTemplate
                guard let fresh = source else { continue }
                let merged = MPDSegmentTemplate()
                merged.media = fresh.media ?? template?.media
                merged.initialization = fresh.initialization ?? template?.initialization
                merged.timescale = fresh.timescale > 0 ? fresh.timescale : (template?.timescale ?? 1)
                merged.startNumber = fresh.startNumber > 0 ? fresh.startNumber : (template?.startNumber ?? 1)
                merged.duration = fresh.duration ?? template?.duration
                merged.pto = fresh.pto
                merged.timeline = fresh.timeline
                template = merged
            }
        }
    }

    /// 用本次清单的最终地址重解分片基址。
    ///
    /// 边缘节点常把 session / token 写在重定向后的 URL 上（清单里的 BaseURL 仍是相对路径），
    /// 每次刷新拿到的最终地址可能带着新的 token；不刷新基址会让新分片沿用过期 token 而拉不动。
    ///
    /// - Parameters:
    ///   - manifest: 本次清单的最终 URL。
    ///   - doc: 本次解析得到的 MPD。
    ///   - period: doc 里对应的 Period。
    func updateBaseURL(manifest: URL, doc: MPDDocument, period: MPDPeriod) {
        var base = manifest
        for component in [doc.baseURL, period.baseURL, adaptation.baseURL, representation.baseURL] {
            guard let text = component, !text.isEmpty else { continue }
            if let url = URL(string: text, relativeTo: base) { base = url.absoluteURL }
        }
        baseURL = base
    }

    // MARK: - URL 模板

    private func expand(_ template: String, number: Int, time: Double) -> String {
        guard !template.isEmpty else { return "" }
        var result = template
        result = result.replacingOccurrences(of: "$RepresentationID$", with: representation.id)
        result = result.replacingOccurrences(of: "$Bandwidth$", with: String(bandwidth))

        // $Number%05d$
        let pattern = "\\$(Number|Time)(%0(\\d+)d)?\\$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            var replacement: String
            if token == "Number" {
                replacement = String(number)
                if match.range(at: 3).location != NSNotFound, let width = Int(ns.substring(with: match.range(at: 3))) {
                    replacement = String(format: "%0\(width)d", number)
                }
            } else {
                replacement = String(Int64(time.rounded()))
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private func resolve(_ relative: String) -> URL? {
        guard !relative.isEmpty else { return baseURL }
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}
