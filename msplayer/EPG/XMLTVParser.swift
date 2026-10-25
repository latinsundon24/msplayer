import Foundation

/// XMLTV (EPG) 解析器。
/// 只保留节目单需要的字段：频道名、标题、副标题、描述、开始/结束时间。
final class XMLTVParser: NSObject, XMLParserDelegate {

    static func parse(data: Data) -> EPGDatabase {
        let handler = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return handler.build()
    }

    private struct PendingProgramme {
        var channelID: String
        var title: String = ""
        var subtitle: String?
        var desc: String?
        var start: Date
        var stop: Date
    }

    private var currentChannelID: String?
    private var displayNameChannelID: String?
    private var currentElement = ""
    private var currentText = ""
    private var pending: PendingProgramme?

    private var channelNames: [String: [String]] = [:]
    private var programmes: [String: [EPGProgram]] = [:]

    private func build() -> EPGDatabase {
        var sorted: [String: [EPGProgram]] = [:]
        for (key, list) in programmes {
            sorted[key] = list.sorted { $0.start < $1.start }
        }
        return EPGDatabase(channelNames: channelNames, programs: sorted)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""

        switch currentElement {
        case "channel":
            currentChannelID = attributeDict["id"]
        case "display-name":
            displayNameChannelID = currentChannelID
        case "programme":
            guard let channel = attributeDict["channel"],
                  let start = XMLTVDate.parse(attributeDict["start"]) else {
                pending = nil
                return
            }
            let stop = XMLTVDate.parse(attributeDict["stop"]) ?? start.addingTimeInterval(3600)
            pending = PendingProgramme(channelID: channel, start: start, stop: stop)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "display-name":
            if let id = displayNameChannelID, !text.isEmpty {
                var names = channelNames[id] ?? []
                if !names.contains(text) { names.append(text) }
                channelNames[id] = names
            }
            displayNameChannelID = nil
        case "title":
            if pending != nil, !text.isEmpty { pending?.title = text }
        case "sub-title", "subtitle":
            if pending != nil, !text.isEmpty { pending?.subtitle = text }
        case "desc":
            if pending != nil, !text.isEmpty { pending?.desc = text }
        case "programme":
            if let item = pending {
                let program = EPGProgram(channelID: item.channelID,
                                         title: item.title.isEmpty ? "未命名节目" : item.title,
                                         subtitle: item.subtitle,
                                         desc: item.desc,
                                         start: item.start,
                                         stop: item.stop)
                programmes[item.channelID, default: []].append(program)
            }
            pending = nil
        case "channel":
            currentChannelID = nil
        default:
            break
        }
        currentText = ""
    }
}

enum XMLTVDate {
    /// 可选的锚定日期（用于仅有「时分」或「日期」的节目时间，按调用方传入的当天补全）。
    /// - Parameter timeZone: 把无时区偏移的时间字符串解释为哪个时区。默认 UTC（兼容 XMLTV 原行为）；
    ///   JSON EPG 的节目时间通常是服务器本地时间，调用方应传入 `TimeZone.current` 以免差 8 小时。
    static func parse(_ raw: String?, anchor day: Date? = nil, timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Date? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "：", with: ":")

        // Unix 时间戳：纯数字（秒 10 位 / 毫秒 13 位）
        if let num = Double(text), text.allSatisfy({ $0.isNumber || $0 == "." }) {
            if text.contains(".") {
                return Date(timeIntervalSince1970: num)
            }
            if text.count == 13 {
                return Date(timeIntervalSince1970: num / 1000)
            }
            return Date(timeIntervalSince1970: num)
        }

        // "20261021120000+0800" -> "20261021120000 +0800"
        if let plus = text.lastIndex(of: "+"), plus > text.index(text.startIndex, offsetBy: 12) {
            let before = text[..<plus]
            if !before.hasSuffix(" ") {
                text.insert(" ", at: plus)
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let formats = [
            "yyyyMMddHHmmss Z",
            "yyyyMMddHHmmss",
            "yyyyMMddHHmm Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy.MM.dd HH:mm:ss",
            "HH:mm:ss",
            "HH:mm"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                // 仅有「时分」的时间，用锚定日期补全到当天
                if (format == "HH:mm:ss" || format == "HH:mm"), let day {
                    let cal = Calendar.current
                    let h = cal.component(.hour, from: date)
                    let m = cal.component(.minute, from: date)
                    let s = cal.component(.second, from: date)
                    if let anchored = cal.date(bySettingHour: h, minute: m, second: s, of: day) {
                        return anchored
                    }
                }
                return date
            }
        }

        // ISO8601 兜底：仅在 UTC 模式处理。本地时区模式下，无偏移的 ISO 时间（如
        // "2026-10-25T19:00:00"）已由上方 formatter 以本地时区解析；若这里再用 UTC 解析
        // 会被当成 UTC，导致差 8 小时。带明确偏移（Z / +08:00）的字符串上方 formatter 也已覆盖。
        if timeZone == TimeZone(secondsFromGMT: 0) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: text)
        }
        return nil
    }
}

enum EPGMatching {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "cctv-", with: "cctv")
            .replacingOccurrences(of: "cctv ", with: "cctv")
            .replacingOccurrences(of: "高清", with: "")
            .replacingOccurrences(of: "标清", with: "")
            .replacingOccurrences(of: "超清", with: "")
            .replacingOccurrences(of: "蓝光", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// 找到一个频道对应的 XMLTV channel id。
    static func match(channel: Channel, in database: EPGDatabase) -> String? {
        if let tvgID = channel.tvgID, database.programs[tvgID] != nil {
            return tvgID
        }
        let target = normalize(channel.name)
        guard !target.isEmpty else { return nil }

        for id in database.programs.keys where normalize(id) == target {
            return id
        }
        for (id, names) in database.channelNames {
            if names.contains(where: { normalize($0) == target }) {
                return id
            }
        }
        for (id, names) in database.channelNames where normalize(id) == target {
            if database.programs[id] != nil {
                _ = names
                return id
            }
        }
        return nil
    }
}

extension EPGDatabase {
    func nowNext(channelID id: String, at date: Date) -> (now: EPGProgram?, next: EPGProgram?) {
        guard let list = programs[id] else { return (nil, nil) }
        let current = list.first { $0.start <= date && date < $0.stop }
        let nextStart = current?.stop ?? date
        let next = list.first { $0.start >= nextStart }
        return (current, next)
    }
}
