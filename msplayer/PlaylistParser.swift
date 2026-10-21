import Foundation

/// 容错解析 .m3u / .m3u8 / .txt 播放列表。
///
/// 支持：
///   #EXTINF:-1 group-title="…" tvg-id="…" tvg-logo="…",频道名
///   #KODIPROP:inputstream.adaptive.manifest_type=mpd
///   #KODIPROP:inputstream.adaptive.license_type=clearkey
///   #KODIPROP:inputstream.adaptive.license_key=KID:KEY
///   #EXTVLCOPT:http-user-agent=…
///   #EXTVLCOPT:http-referrer=…
///   #EXTVLCOPT:http-…=…
///   http://x/y.m3u8|User-Agent=xx&Referer=yy
///   TXT：频道名,地址 / 频道名|地址 / 纯地址 / 分类,#genre#
enum PlaylistParser {

    static func parse(data: Data) -> [Channel] {
        parse(TextDecoding.decode(data))
    }

    static func parse(_ content: String) -> [Channel] {
        var out: [Channel] = []
        var pendingName: String?
        var pendingGroup: String?
        var sectionGroup: String?
        var pendingLogo: String?
        var pendingTVGID: String?
        var pendingTVGName: String?
        var manifest: ManifestType = .auto
        var licenseType: String?
        var licenseURL: String?
        var keys: [String: String] = [:]
        var headers: [String: String] = [:]
        var pendingCatchUp: String?
        var pendingCatchUpSource: String?
        var pendingCatchUpDays: Int?

        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rawLines = normalized.components(separatedBy: "\n")
        if !rawLines.isEmpty, rawLines[0].hasPrefix("\u{FEFF}") {
            rawLines[0] = String(rawLines[0].dropFirst())
        }

        func resetMeta() {
            manifest = .auto
            licenseType = nil
            licenseURL = nil
            keys = [:]
            headers = [:]
        }

        func applyCatchUpAttrs(_ attrs: String) {
            if let mode = value(of: "catchup", in: attrs), !mode.isEmpty {
                pendingCatchUp = mode
            }
            if let source = value(of: "catchup-source", in: attrs), !source.isEmpty {
                pendingCatchUpSource = source
            }
            if let days = value(of: "catchup-days", in: attrs) ?? value(of: "timeshift", in: attrs),
               let value = Int(days.trimmingCharacters(in: .whitespaces)) {
                pendingCatchUpDays = value
            }
        }

        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.uppercased().hasPrefix("#EXTINF") {
                pendingCatchUp = nil
                pendingCatchUpSource = nil
                pendingCatchUpDays = nil
                if let comma = line.firstIndex(of: ",") {
                    let title = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { pendingName = title }
                    let attrs = String(line[line.startIndex..<comma])
                    if let g = value(of: "group-title", in: attrs), !g.isEmpty { pendingGroup = g }
                    if let l = value(of: "tvg-logo", in: attrs), !l.isEmpty { pendingLogo = l }
                    if let id = value(of: "tvg-id", in: attrs), !id.isEmpty { pendingTVGID = id }
                    if let n = value(of: "tvg-name", in: attrs), !n.isEmpty { pendingTVGName = n }
                    if pendingName == nil { pendingName = pendingTVGName }
                    applyCatchUpAttrs(attrs)
                } else {
                    let attrs = line
                    if let g = value(of: "group-title", in: attrs), !g.isEmpty { pendingGroup = g }
                    if let id = value(of: "tvg-id", in: attrs), !id.isEmpty { pendingTVGID = id }
                    if let n = value(of: "tvg-name", in: attrs), !n.isEmpty { pendingName = n }
                    applyCatchUpAttrs(attrs)
                }
                resetMeta()
                continue
            }

            if line.uppercased().hasPrefix("#EXTGRP") {
                if let colon = line.firstIndex(of: ":") {
                    let g = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !g.isEmpty { pendingGroup = g }
                }
                continue
            }

            if line.uppercased().hasPrefix("#KODIPROP:") {
                let body = String(line.dropFirst("#KODIPROP:".count))
                applyKodiProp(body,
                              manifest: &manifest,
                              licenseType: &licenseType,
                              licenseURL: &licenseURL,
                              keys: &keys,
                              headers: &headers)
                continue
            }

            if line.uppercased().hasPrefix("#EXTVLCOPT:") {
                let body = String(line.dropFirst("#EXTVLCOPT:".count))
                applyVLCOpt(body, headers: &headers)
                continue
            }

            if line.hasPrefix("#") { continue }

            // TXT 分类标记：分类名,#genre#
            if let genre = genreGroup(from: line) {
                sectionGroup = genre
                continue
            }

            var name: String?
            var rawURL: String

            if let pn = pendingName, !pn.isEmpty {
                name = pn
                rawURL = line
            } else if let sep = firstSeparator(line) {
                let a = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
                let b = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                if looksLikeURL(b) {
                    name = a
                    rawURL = b
                } else if looksLikeURL(a) {
                    rawURL = a
                    name = b
                } else {
                    name = a
                    rawURL = b
                }
            } else {
                rawURL = line
            }

            let (url, pipeHeaders) = splitPipeOptions(rawURL)
            var mergedHeaders = headers
            for (k, v) in pipeHeaders where mergedHeaders[k] == nil {
                mergedHeaders[k] = v
            }

            let group = (pendingGroup?.isEmpty == false)
                ? pendingGroup!
                : ((sectionGroup?.isEmpty == false) ? sectionGroup! : "默认")
            let finalName = (name?.isEmpty == false) ? name! : deriveName(url)

            let channel = Channel(name: finalName,
                                  url: url,
                                  group: group,
                                  logo: pendingLogo,
                                  tvgID: pendingTVGID ?? pendingTVGName,
                                  manifestType: manifest,
                                  licenseType: licenseType,
                                  keys: keys,
                                  licenseURL: licenseURL,
                                  headers: mergedHeaders,
                                  catchUpMode: pendingCatchUp,
                                  catchUpSource: pendingCatchUpSource,
                                  catchUpDays: pendingCatchUpDays)
            out.append(channel)

            pendingName = nil
            pendingGroup = nil
            pendingLogo = nil
            pendingTVGID = nil
            pendingTVGName = nil
            pendingCatchUp = nil
            pendingCatchUpSource = nil
            pendingCatchUpDays = nil
            resetMeta()
        }

        return out
    }

    // MARK: - KODIPROP

    private static func applyKodiProp(_ body: String,
                                      manifest: inout ManifestType,
                                      licenseType: inout String?,
                                      licenseURL: inout String?,
                                      keys: inout [String: String],
                                      headers: inout [String: String]) {
        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        switch name {
        case "inputstream.adaptive.manifest_type":
            switch raw.lowercased() {
            case "mpd", "dash": manifest = .dash
            case "hls", "m3u8": manifest = .hls
            case "ism", "smoothstreaming": manifest = .smooth
            default: manifest = .auto
            }

        case "inputstream.adaptive.license_type":
            licenseType = raw.lowercased()

        case "inputstream.adaptive.license_key":
            let parsedKeys = ClearKeyParser.parse(raw)
            if !parsedKeys.isEmpty {
                for (k, v) in parsedKeys { keys[k] = v }
                if licenseType == nil { licenseType = "clearkey" }
            } else if raw.lowercased().hasPrefix("http") {
                licenseURL = raw
                if licenseType == nil { licenseType = "clearkey" }
            } else if raw.lowercased().hasPrefix("data:") || raw.hasPrefix("{") || raw.hasPrefix("[") {
                if let decoded = ClearKeyParser.parseInlineJSON(raw) {
                    for (k, v) in decoded { keys[k] = v }
                    if licenseType == nil { licenseType = "clearkey" }
                }
            }

        case "inputstream.adaptive.stream_headers":
            applyHeaderPairs(raw, headers: &headers)

        case "inputstream.adaptive.manifest_headers":
            applyHeaderPairs(raw, headers: &headers)

        default:
            break
        }
    }

    private static func applyVLCOpt(_ body: String, headers: inout [String: String]) {
        let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "http-user-agent":
            headers["User-Agent"] = value
        case "http-referrer", "http-referer":
            headers["Referer"] = value
        case "http-origin":
            headers["Origin"] = value
        case "http-cookie":
            headers["Cookie"] = value
        default:
            if key.hasPrefix("http-") {
                headers[String(key.dropFirst(5))] = value
            }
        }
    }

    /// "User-Agent=xxx&Referer=yyy" 形式
    private static func applyHeaderPairs(_ raw: String, headers: inout [String: String]) {
        let decoded = raw.removingPercentEncoding ?? raw
        for pair in decoded.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, headers[key] == nil { headers[key] = value }
        }
    }

    // MARK: - TXT / 管道参数

    private static func genreGroup(from line: String) -> String? {
        let lower = line.lowercased()
        guard lower.hasSuffix("#genre#") else { return nil }
        var prefix = String(line.dropLast("#genre#".count))
        prefix = prefix.trimmingCharacters(in: .whitespaces)
        if prefix.hasSuffix(",") || prefix.hasSuffix("|") || prefix.hasSuffix(";") {
            prefix = String(prefix.dropLast())
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 拆出 `url|User-Agent=…&Referer=…`
    static func splitPipeOptions(_ raw: String) -> (String, [String: String]) {
        guard let bar = raw.firstIndex(of: "|") else { return (raw, [:]) }
        let url = String(raw[..<bar]).trimmingCharacters(in: .whitespaces)
        let optionText = String(raw[raw.index(after: bar)...])
        var headers: [String: String] = [:]
        let decoded = optionText.removingPercentEncoding ?? optionText
        for pair in decoded.split(whereSeparator: { $0 == "&" || $0 == "|" }) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            switch key.lowercased() {
            case "user-agent", "useragent", "ua":
                headers["User-Agent"] = value
            case "referer", "referrer":
                headers["Referer"] = value
            case "origin":
                headers["Origin"] = value
            case "cookie":
                headers["Cookie"] = value
            default:
                headers[key] = value
            }
        }
        return (url, headers)
    }

    // MARK: - Helpers

    static func firstSeparator(_ s: String) -> String.Index? {
        for idx in s.indices {
            let c = s[idx]
            if c == "," || c == "|" { return idx }
        }
        return nil
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("://")
            || lower.hasPrefix("file:")
            || lower.hasPrefix("msplayer-bundle:")
            || lower.hasPrefix("rtmp")
            || lower.hasPrefix("rtsp")
            || lower.hasPrefix("udp")
            || lower.hasPrefix("mms")
    }

    static func deriveName(_ url: String) -> String {
        var u = url
        if let q = u.firstIndex(of: "?") { u = String(u[..<q]) }
        if let r = u.range(of: "://") { u = String(u[r.upperBound...]) }
        if let slash = u.lastIndex(of: "/"), slash < u.index(before: u.endIndex) {
            let name = String(u[u.index(after: slash)...])
            return name.isEmpty ? url : name
        }
        return u.isEmpty ? url : u
    }

    /// 取属性值，如 group-title="xxx"（也兼容单引号写法）
    static func value(of key: String, in line: String) -> String? {
        for pattern in [key + "=\"([^\"]*)\"", key + "='([^']*)'"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges > 1 else {
                continue
            }
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }
}

/// ClearKey 各种写法解析
enum ClearKeyParser {

    /// 支持：
    ///   kid:key
    ///   kid:key,kid2:key2
    ///   {"keys":[{"kty":"oct","kid":"…","k":"…"}]}
    ///   data:application/json;base64,…
    static func parse(_ raw: String) -> [String: String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }

        if text.lowercased().hasPrefix("data:") {
            return parseInlineJSON(text) ?? [:]
        }
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return parseInlineJSON(text) ?? [:]
        }

        if let semi = text.firstIndex(of: ";") { text = String(text[..<semi]) }

        var result: [String: String] = [:]
        let pairs = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        for pair in pairs {
            let kv = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let kid = normalizeHex(String(kv[0]))
            let key = normalizeHex(String(kv[1]))
            guard kid.count == 32, key.count == 32 else { continue }
            result[kid] = key
        }
        return result
    }

    static func parseInlineJSON(_ raw: String) -> [String: String]? {
        var jsonText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.lowercased().hasPrefix("data:") {
            guard let comma = jsonText.firstIndex(of: ",") else { return nil }
            let header = jsonText[..<comma].lowercased()
            let payload = String(jsonText[jsonText.index(after: comma)...])
            if header.contains("base64") {
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
                jsonText = String(data: data, encoding: .utf8) ?? ""
            } else {
                jsonText = payload.removingPercentEncoding ?? payload
            }
        }
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var result: [String: String] = [:]
        if let dict = object as? [String: Any] {
            collectJWK(dict, into: &result)
            if let kids = dict["kids"] as? [String], let key = dict["key"] as? String {
                let keyHex = normalizeOrBase64(key)
                for kid in kids {
                    if let kidHex = normalizeOrBase64(kid), let k = keyHex { result[kidHex] = k }
                }
            }
        } else if let array = object as? [[String: Any]] {
            for item in array { collectJWK(item, into: &result) }
        }
        return result.isEmpty ? nil : result
    }

    private static func collectJWK(_ dict: [String: Any], into result: inout [String: String]) {
        if let kid = dict["kid"] as? String, let key = dict["k"] as? String,
           let kidHex = normalizeOrBase64(kid), let keyHex = normalizeOrBase64(key) {
            result[kidHex] = keyHex
        }
        if let keys = dict["keys"] as? [[String: Any]] {
            for item in keys { collectJWK(item, into: &result) }
        }
    }

    /// hex 原样规范化；不是 hex 时按 base64url 解码
    static func normalizeOrBase64(_ value: String) -> String? {
        let hex = normalizeHex(value)
        if hex.count == 32 { return hex }
        var b64 = value.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64), data.count == 16 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizeHex(_ value: String) -> String {
        let cleaned = value
            .lowercased()
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "-", with: "")
            .filter { $0.isHexDigit }
        return cleaned
    }
}
