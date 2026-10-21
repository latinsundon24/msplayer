import Foundation

// MARK: - 模型

final class MPDDocument {
    var type: String = "static"
    var mediaPresentationDuration: Double?
    var minimumUpdatePeriod: Double = 2
    var availabilityStartTime: Date?
    var timeShiftBufferDepth: Double?
    var suggestedPresentationDelay: Double?
    var baseURL: String?
    var periods: [MPDPeriod] = []

    var isDynamic: Bool { type.lowercased() == "dynamic" }
}

final class MPDPeriod {
    var id: String?
    var start: Double?
    var duration: Double?
    var baseURL: String?
    var adaptations: [MPDAdaptation] = []
}

final class MPDAdaptation {
    var id: String?
    var contentType: String?
    var mimeType: String?
    var lang: String?
    var baseURL: String?
    var width: Int?
    var height: Int?
    var segmentTemplate: MPDSegmentTemplate?
    var segmentList: MPDSegmentList?
    var protection: [MPDProtection] = []
    var representations: [MPDRepresentation] = []

    var isVideo: Bool {
        contentType?.lowercased() == "video" || (mimeType ?? "").lowercased().contains("video")
    }
    var isAudio: Bool {
        contentType?.lowercased() == "audio" || (mimeType ?? "").lowercased().contains("audio")
    }
}

final class MPDRepresentation {
    var id: String = ""
    var bandwidth: Int = 0
    var width: Int?
    var height: Int?
    var codecs: String?
    var mimeType: String?
    var baseURL: String?
    var segmentTemplate: MPDSegmentTemplate?
    var segmentList: MPDSegmentList?
    var protection: [MPDProtection] = []
}

final class MPDSegmentTemplate {
    var media: String?
    var initialization: String?
    var timescale: Double = 1
    var startNumber: Int = 1
    var duration: Double?
    var pto: Double = 0
    var timeline: [MPDTimeline] = []
}

struct MPDTimeline {
    var t: Double
    var d: Double
    var r: Int
}

final class MPDSegmentList {
    var initialization: String?
    var duration: Double?
    var timescale: Double = 1
    var urls: [String] = []
}

struct MPDProtection {
    var schemeIdUri: String?
    var value: String?
    var kid: String?
    var pssh: Data?

    var isClearKey: Bool {
        let scheme = (schemeIdUri ?? "").lowercased()
        let val = (value ?? "").lowercased()
        return scheme.contains("clearkey")
            || scheme.contains("e2719d58-a985-b3c9-781a-b030af78d30e")
            || val == "clearkey"
    }
}

// MARK: - 解析

final class MPDParser: NSObject, XMLParserDelegate {

    private let document = MPDDocument()
    private var elementStack: [String] = []

    private var currentPeriod: MPDPeriod?
    private var currentAdaptation: MPDAdaptation?
    private var currentRepresentation: MPDRepresentation?

    private var currentTemplate: MPDSegmentTemplate?
    private var currentSegmentList: MPDSegmentList?
    private var textBuffer = ""

    static func parse(data: Data) -> MPDDocument? {
        let delegate = MPDParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.document
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        elementStack.append(name)
        textBuffer = ""

        switch name {
        case "MPD":
            if let type = attributeDict["type"] {
                document.type = type.lowercased()
            }
            if let value = attributeDict["mediaPresentationDuration"] {
                document.mediaPresentationDuration = MPDParser.parseDuration(value)
            }
            if let value = attributeDict["minimumUpdatePeriod"] {
                document.minimumUpdatePeriod = MPDParser.parseDuration(value) ?? 2
            }
            if let value = attributeDict["availabilityStartTime"] {
                document.availabilityStartTime = MPDParser.parseDate(value)
            }
            if let value = attributeDict["timeShiftBufferDepth"] {
                document.timeShiftBufferDepth = MPDParser.parseDuration(value)
            }
            if let value = attributeDict["suggestedPresentationDelay"] {
                document.suggestedPresentationDelay = MPDParser.parseDuration(value)
            }

        case "Period":
            let period = MPDPeriod()
            period.id = attributeDict["id"]
            period.start = attributeDict["start"].flatMap { MPDParser.parseDuration($0) }
            period.duration = attributeDict["duration"].flatMap { MPDParser.parseDuration($0) }
            document.periods.append(period)
            currentPeriod = period

        case "AdaptationSet":
            let adaptation = MPDAdaptation()
            adaptation.id = attributeDict["id"]
            adaptation.contentType = attributeDict["contentType"]
            adaptation.mimeType = attributeDict["mimeType"]
            adaptation.lang = attributeDict["lang"]
            adaptation.width = attributeDict["width"].flatMap { Int($0) }
            adaptation.height = attributeDict["height"].flatMap { Int($0) }
            currentPeriod?.adaptations.append(adaptation)
            currentAdaptation = adaptation

        case "Representation":
            let rep = MPDRepresentation()
            rep.id = attributeDict["id"] ?? ""
            rep.bandwidth = attributeDict["bandwidth"].flatMap { Int($0) } ?? 0
            rep.width = attributeDict["width"].flatMap { Int($0) }
            rep.height = attributeDict["height"].flatMap { Int($0) }
            rep.codecs = attributeDict["codecs"]
            rep.mimeType = attributeDict["mimeType"]
            currentAdaptation?.representations.append(rep)
            currentRepresentation = rep

        case "SegmentTemplate":
            let template = MPDSegmentTemplate()
            if let value = attributeDict["media"] { template.media = value }
            if let value = attributeDict["initialization"] { template.initialization = value }
            if let value = attributeDict["timescale"].flatMap({ Double($0) }) { template.timescale = value }
            if let value = attributeDict["startNumber"].flatMap({ Int($0) }) { template.startNumber = value }
            if let value = attributeDict["duration"].flatMap({ Double($0) }) { template.duration = value }
            if let value = attributeDict["presentationTimeOffset"].flatMap({ Double($0) }) { template.pto = value }
            if let rep = currentRepresentation {
                rep.segmentTemplate = template
                currentTemplate = template
            } else if let adaptation = currentAdaptation {
                adaptation.segmentTemplate = template
                currentTemplate = template
            } else {
                currentTemplate = template
            }

        case "S":
            guard let template = currentTemplate else { break }
            let t = attributeDict["t"].flatMap { Double($0) }
            let d = attributeDict["d"].flatMap { Double($0) } ?? 0
            let r = attributeDict["r"].flatMap { Int($0) } ?? 0
            template.timeline.append(MPDTimeline(t: t ?? 0, d: d, r: r))

        case "SegmentList":
            let list = MPDSegmentList()
            if let value = attributeDict["duration"].flatMap({ Double($0) }) { list.duration = value }
            if let value = attributeDict["timescale"].flatMap({ Double($0) }) { list.timescale = value }
            currentSegmentList = list
            if let rep = currentRepresentation { rep.segmentList = list }
            else if let adaptation = currentAdaptation { adaptation.segmentList = list }

        case "Initialization":
            if let source = attributeDict["sourceURL"] {
                currentSegmentList?.initialization = source
            }

        case "SegmentURL":
            if let media = attributeDict["media"] {
                currentSegmentList?.urls.append(media)
            }

        case "ContentProtection":
            let protection = MPDProtection(schemeIdUri: attributeDict["schemeIdUri"],
                                           value: attributeDict["value"],
                                           kid: attributeDict.first { $0.key.lowercased().hasSuffix("default_kid") }?.value,
                                           pssh: nil)
            if let rep = currentRepresentation { rep.protection.append(protection) }
            else if let adaptation = currentAdaptation { adaptation.protection.append(protection) }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
            textBuffer = ""
        }

        switch name {
        case "BaseURL":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return }
            if currentRepresentation != nil {
                currentRepresentation?.baseURL = value
            } else if currentAdaptation != nil {
                currentAdaptation?.baseURL = value
            } else if currentPeriod != nil {
                currentPeriod?.baseURL = value
            } else {
                document.baseURL = value
            }

        case "pssh":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else { return }
            if let rep = currentRepresentation, !rep.protection.isEmpty {
                rep.protection[rep.protection.count - 1].pssh = data
            } else if let adaptation = currentAdaptation, !adaptation.protection.isEmpty {
                adaptation.protection[adaptation.protection.count - 1].pssh = data
            }

        case "Period":
            currentPeriod = nil

        case "AdaptationSet":
            // ContentProtection 可以写在 AdaptationSet 上，对组内所有 Representation 生效
            if let adaptation = currentAdaptation {
                for rep in adaptation.representations where rep.protection.isEmpty {
                    rep.protection = adaptation.protection
                }
            }
            currentAdaptation = nil
            currentRepresentation = nil

        case "Representation":
            currentRepresentation = nil

        case "SegmentTemplate":
            currentTemplate = nil

        case "SegmentTimeline":
            currentTemplate = nil

        case "SegmentList":
            currentSegmentList = nil

        default:
            break
        }
    }

    // MARK: Helpers

    private func localName(_ name: String) -> String {
        if let index = name.lastIndex(of: ":") {
            return String(name[name.index(after: index)...])
        }
        return name
    }

    /// ISO8601 duration -> seconds
    static func parseDuration(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var negative = false
        if value.hasPrefix("-") { negative = true; value.removeFirst() }
        if value.hasPrefix("+") { value.removeFirst() }
        guard value.hasPrefix("P") else {
            return Double(value)
        }
        value.removeFirst()

        var total: Double = 0
        var number = ""
        var inTime = false
        for ch in value {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "Y": total += n * 365 * 86400
            case "M": total += n * (inTime ? 60 : 30 * 86400)
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "S": total += n
            default: break
            }
        }
        return negative ? -total : total
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
