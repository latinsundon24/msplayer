import Foundation

/// DASH 字幕（`stpp`：ISOBMFF 里装着 TTML）→ HLS WebVTT 的转换。
///
/// 这类源（如 TVB）的每一个字幕分片是一小段 mp4 盒子堆：`styp / moof / mdat`，
/// `mdat` 里是一份**完整**的 TTML 文档。文档虽然声明 `ttp:timeBase="media"`，
/// 但 `<p>` 的 `begin/end` 给的是**绝对媒体时间**，形如 `498062:02:48.000`
/// ——小时位会一直累积到十几万。这个值恰好等于该分片的起始呈现时间（Unix 秒），
/// 所以要**减掉分片自身的起始时间**，才能换算成分片内的相对时间。
///
/// HLS 的 WebVTT 分片默认按"分片内相对时间"记时（未给 `EXT-X-TIMESTAMP-MAP` 时），
/// 因此这里的换算正好匹配。
enum TTMLSubtitle {

    /// 把一个字幕分片转换成 WebVTT 文本。
    ///
    /// - Parameters:
    ///   - segment: 分片原始数据。
    ///   - startTime: 该分片的起始呈现时间（秒）。
    ///   - duration: 该分片时长（秒）；越界的字幕会被收敛进分片区间。
    /// - Returns: WebVTT 文本。取不到 `mdat` 时返回 nil；
    ///   解析失败或该片无字幕时返回**合法的空 WebVTT**，避免播放列表被判为损坏。
    /// - Parameters:
    ///   - mpegts: 本分片起点在 HLS 程序时间轴上的 90kHz 值。Apple 的 HLS 规范要求
    ///     每个供 AVPlayer 使用的 WebVTT 分片都必须带 `X-TIMESTAMP-MAP` 头，
    ///     缺了字幕会不同步甚至不显示。
    static func webVTT(from segment: Data, startTime: Double, duration: Double, mpegts: Int64 = 0) -> String? {
        guard let payload = Box.parse(segment).first(where: { $0.type == "mdat" })?.payload,
              !payload.isEmpty else { return nil }

        let parser = XMLParser(data: payload)
        let collector = CueCollector(startTime: startTime, duration: duration)
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.parse()

        // cue 时间是相对分片起点的（LOCAL 00:00:00.000），映射到程序时间轴的 MPEGTS
        var text = "WEBVTT\n"
        text += "X-TIMESTAMP-MAP:LOCAL:00:00:00.000,MPEGTS:\(max(0, mpegts))\n\n"
        for cue in collector.cues {
            text += "\(timestamp(cue.begin)) --> \(timestamp(cue.end))\n"
            text += cue.text + "\n\n"
        }
        return text
    }

    // MARK: - 时间

    /// 解析 TTML 时间：`hh:mm:ss.mmm`（小时可无限累加）/ `mm:ss.mmm` / 纯秒。
    ///
    /// 用"每位乘 60 累加"的方式，天然支持小时位不受 24 限制：
    /// `498062:02:48` = ((498062 × 60) + 2) × 60 + 48 。
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var pieces: [Double] = []
        for part in trimmed.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            pieces.append(value)
        }
        guard pieces.count <= 3 else { return nil }

        var total: Double = 0
        for value in pieces { total = total * 60 + value }
        return total
    }

    /// 秒 → WebVTT 时间戳（`HH:MM:SS.mmm`）
    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, seconds)
        let total = Int((value * 1000).rounded())
        let hour = total / 3_600_000
        let minute = (total % 3_600_000) / 60_000
        let second = (total % 60_000) / 1000
        let milli = total % 1000
        return String(format: "%02d:%02d:%02d.%03d", hour, minute, second, milli)
    }

    // MARK: - XML

    /// 去掉可能的命名空间前缀（`tts:span` → `span`）。
    /// 用 fileprivate 以便内部嵌套的解析器能够访问。
    fileprivate static func localName(_ name: String) -> String {
        if let index = name.lastIndex(of: ":") {
            return String(name[name.index(after: index)...])
        }
        return name
    }

    /// 收集 `<p begin end>` 及其子节点（`<span>` / `<br>`）内的文本。
    private final class CueCollector: NSObject, XMLParserDelegate {

        struct Cue {
            let begin: Double
            let end: Double
            let text: String
        }

        private let startTime: Double
        private let duration: Double
        private(set) var cues: [Cue] = []

        private var inParagraph = false
        private var depth = 0
        private var buffer = ""
        private var begin: Double?
        private var end: Double?

        init(startTime: Double, duration: Double) {
            self.startTime = startTime
            self.duration = duration
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = TTMLSubtitle.localName(elementName)

            if name == "p" {
                if !inParagraph {
                    inParagraph = true
                    depth = 0
                    buffer = ""
                    begin = attributeDict["begin"].flatMap { TTMLSubtitle.seconds($0) }
                    end = attributeDict["end"].flatMap { TTMLSubtitle.seconds($0) }
                }
                depth += 1
            } else if inParagraph {
                if name == "br" { buffer += "\n" }
                depth += 1
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inParagraph else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = TTMLSubtitle.localName(elementName)
            guard inParagraph else { return }

            depth -= 1
            if name == "p", depth <= 0 {
                finish()
                inParagraph = false
                depth = 0
            }
        }

        /// 收尾：换算成分片内相对时间，收敛越界，丢弃非法 cue。
        private func finish() {
            guard let rawBegin = begin, let rawEnd = end, rawEnd > rawBegin else { return }
            let limit = max(0, duration)
            let relativeBegin = min(max(0, rawBegin - startTime), limit)
            let relativeEnd = min(max(0, rawEnd - startTime), limit)
            guard relativeEnd > relativeBegin else { return }

            // TTML 默认折叠空白：逐行去两端空格，丢掉纯缩进空行
            let text = buffer
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            cues.append(Cue(begin: relativeBegin, end: relativeEnd, text: text))
        }
    }
}
