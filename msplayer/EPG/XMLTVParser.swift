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
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "：", with: ":")
        // "20261021120000+0800" -> "20261021120000 +0800"
        if let plus = text.lastIndex(of: "+"), plus > text.index(text.startIndex, offsetBy: 12) {
            let before = text[..<plus]
            if !before.hasSuffix(" ") {
                text.insert(" ", at: plus)
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyyMMddHHmmss Z",
            "yyyyMMddHHmmss",
            "yyyyMMddHHmm Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
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
