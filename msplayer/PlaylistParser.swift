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
///   #EXTHTTP:{"User-Agent":"…","Referer":"…"}（也吃 {"headers":{…}} 嵌套与 Referer=…&UA=… 退化写法）
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
            if let source = firstValue(["catchup-source", "catchup_source", "catchupsource"], in: attrs),
               !source.isEmpty {
                pendingCatchUpSource = source
            }
            if let days = firstValue(["catchup-days", "catchup_days", "catchupdays", "timeshift"], in: attrs),
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
                if let comma = extinfSeparator(in: line) {
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

            if line.uppercased().hasPrefix("#EXTHTTP:") {
                let body = String(line.dropFirst("#EXTHTTP:".count))
                applyExtHTTP(body, headers: &headers)
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
            // 地址行里的 |头=值 优先级最高，覆盖 #EXTHTTP / #EXTVLCOPT / #KODIPROP 的同名头
            for (k, v) in pipeHeaders {
                setHeader(k, value: v, into: &mergedHeaders)
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
            setHeader("User-Agent", value: value, into: &headers)
        case "http-referrer", "http-referer":
            setHeader("Referer", value: value, into: &headers)
        case "http-origin":
            setHeader("Origin", value: value, into: &headers)
        case "http-cookie":
            setHeader("Cookie", value: value, into: &headers)
        default:
            if key.hasPrefix("http-") {
                setHeader(String(key.dropFirst(5)), value: value, into: &headers)
            }
        }
    }

    // MARK: - #EXTHTTP

    /// `#EXTHTTP:{"User-Agent":"Chrome","Referer":"https://x/"}`（OTT Navigator / OMG 等工具的写法）。
    /// 键就是 HTTP 头名，可放任意自定义头。
    ///
    /// 兼容三种写法：
    ///   1. JSON 对象：{"Referer":"…","X-Token":"…"}
    ///   2. 嵌套：{"headers":{"Referer":"…"}}
    ///   3. 退化：Referer=…&User-Agent=…（少数列表没写成 JSON）
    /// 也容忍整段被 URL 编码过的 JSON。
    private static func applyExtHTTP(_ body: String, headers: inout [String: String]) {
        var text = body.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        // 少数列表会对 JSON 做 URL 编码
        if !text.hasPrefix("{"), text.contains("%"),
           let decoded = text.removingPercentEncoding, decoded.contains("{") {
            text = decoded.trimmingCharacters(in: .whitespaces)
        }

        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            collectHTTPHeaders(from: dict, headers: &headers)
            return
        }

        // 退化写法
        applyHeaderPairs(text, headers: &headers)
    }

    private static func collectHTTPHeaders(from dict: [String: Any], headers: inout [String: String]) {
        for (rawKey, rawValue) in dict {
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            // {"headers":{…}} / {"header":{…}} 这类嵌套包装
            if let nested = rawValue as? [String: Any] {
                collectHTTPHeaders(from: nested, headers: &headers)
                continue
            }
            if let list = rawValue as? [[String: Any]] {
                for item in list { collectHTTPHeaders(from: item, headers: &headers) }
                continue
            }

            let value = headerValue(rawValue)
            guard !value.isEmpty else { continue }
            setHeader(key, value: value, into: &headers)
        }
    }

    /// JSON 里的值可能是字符串、数字或布尔，统一转成头值文本。
    private static func headerValue(_ value: Any) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            // 布尔和整数在 JSON 里都是 NSNumber，只能用 objCType 区分：
            // 'c' / 'B' 是布尔，否则按数字输出（否则 true 会变成 "1"）
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return ""
    }

    // MARK: - 头名规范化

    /// 统一 HTTP 头名写法。
    /// 不同来源（#EXTHTTP / #EXTVLCOPT / |Referer= / stream_headers）大小写与别名各异，
    /// 若不收敛会出现 "Referer" 与 "referer" 两个键——VLC 会下发两个 :http-* 选项，
    /// AVPlayer 也会当成两个不同的头，源站反而可能拒绝。
    static func canonicalHeaderKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "user-agent", "useragent", "ua": return "User-Agent"
        case "referer", "referrer":          return "Referer"
        case "origin":                       return "Origin"
        case "cookie":                       return "Cookie"
        case "host":                         return "Host"
        case "accept":                       return "Accept"
        case "accept-language":              return "Accept-Language"
        case "accept-encoding":              return "Accept-Encoding"
        case "authorization":                return "Authorization"
        case "connection":                   return "Connection"
        case "x-forwarded-for":              return "X-Forwarded-For"
        default:
            return trimmed
                .split(separator: "-", omittingEmptySubsequences: false)
                .map { part in
                    guard let first = part.first else { return "" }
                    return String(first).uppercased() + part.dropFirst().lowercased()
                }
                .joined(separator: "-")
        }
    }

    /// 写入头：先删掉同义的旧键再写，避免重复。
    static func setHeader(_ key: String, value: String, into headers: inout [String: String]) {
        let canonical = canonicalHeaderKey(key)
        // HTTP 头名不允许空白，脏数据直接丢弃，否则会在发出请求时炸掉（NSInvalidArgumentException）
        guard !canonical.isEmpty,
              canonical.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return }
        // 先收集再删除：不能一边遍历字典的 keys 一边 removeValue（未定义行为）
        let duplicates = headers.keys.filter { canonicalHeaderKey($0) == canonical }
        for existing in duplicates { headers.removeValue(forKey: existing) }
        headers[canonical] = value
    }

    /// "User-Agent=xxx&Referer=yyy" 形式
    private static func applyHeaderPairs(_ raw: String, headers: inout [String: String]) {
        let decoded = raw.removingPercentEncoding ?? raw
        for pair in decoded.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            let canonical = canonicalHeaderKey(key)
            // KODIPROP stream_headers 既有语义：同一头已存在时不覆盖
            guard !headers.keys.contains(where: { canonicalHeaderKey($0) == canonical }) else { continue }
            headers[canonical] = value
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
                setHeader("User-Agent", value: value, into: &headers)
            case "referer", "referrer":
                setHeader("Referer", value: value, into: &headers)
            case "origin":
                setHeader("Origin", value: value, into: &headers)
            case "cookie":
                setHeader("Cookie", value: value, into: &headers)
            default:
                setHeader(key, value: value, into: &headers)
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

    /// 取属性值，如 group-title="xxx"（兼容单引号与无引号写法）
    static func value(of key: String, in line: String) -> String? {
        for pattern in [key + "=\"([^\"]*)\"", key + "='([^']*)'", key + "=([^\\s,]+)"] {
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

    static func firstValue(_ keys: [String], in line: String) -> String? {
        for key in keys {
            if let value = value(of: key, in: line), !value.isEmpty { return value }
        }
        return nil
    }

    /// `#EXTINF:…,频道名` 的分隔逗号；忽略引号里的逗号。
    static func extinfSeparator(in line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
            } else if character == ",", quote == nil {
                return index
            }
            index = line.index(after: index)
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
