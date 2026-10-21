import Foundation

/// 一条 DASH 码流（视频或音频）的选择结果与分片计算
final class DASHStream {

    enum Kind: String {
        case video
        case audio
    }

    let kind: Kind
    let representation: MPDRepresentation
    let adaptation: MPDAdaptation
    let period: MPDPeriod
    let template: MPDSegmentTemplate?
    let segmentList: MPDSegmentList?
    let initURL: URL?
    let baseURL: URL

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
            for (position, entry) in expandedTimeline().enumerated() {
                let startSeconds = entry.t / ts - ptoSeconds
                let endSeconds = startSeconds + entry.d / ts
                let number = template.startNumber + position
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

    private func expandedTimeline() -> [(t: Double, d: Double)] {
        guard let template = template else { return [] }
        var out: [(t: Double, d: Double)] = []
        var current: Double = 0
        let periodEnd = (period.duration ?? 0) * (template.timescale > 0 ? template.timescale : 1)

        for entry in template.timeline {
            if entry.t > 0 { current = entry.t }
            let repeatCount = entry.r >= 0 ? entry.r + 1 : 1
            if entry.r < 0 {
                // r = -1：一直重复到 Period 结束；直播清单没有总时长时，先展开一段足够长的窗口
                var t = current
                var guardCount = 0
                let cap = periodEnd > 0 ? 20000 : 600
                while guardCount < cap {
                    if periodEnd > 0 && t + entry.d > periodEnd { break }
                    out.append((t, entry.d))
                    t += entry.d
                    guardCount += 1
                }
                current = t
            } else {
                for _ in 0..<repeatCount {
                    out.append((current, entry.d))
                    current += entry.d
                }
            }
        }
        return out
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
