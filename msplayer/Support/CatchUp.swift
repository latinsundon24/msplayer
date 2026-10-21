import Foundation

/// 回看 / 时移地址处理。
///
/// 支持两类来源：
/// 1. 频道地址自带模板：
///    `&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}`
/// 2. m3u 回看标签（Kodi / IPTV Simple 风格）：
///    `catchup="default|append|shift"`、`catchup-source="…"`、`catchup-days="7"`、`timeshift="7"`
///
/// 模板占位符：
/// - `${(b)yyyyMMddHHmmss}` / `${(e)yyyyMMddHHmmss}`（括号内可写任意日期格式）
/// - `${(b)}` / `${(e)}`（默认 yyyyMMddHHmmss）
/// - `${start}` / `${end}`、`{start}` / `{end}`、`{utc}` / `{utcend}`（Unix 时间戳）
enum CatchUp {

    static let defaultFormat = "yyyyMMddHHmmss"

    // MARK: - 能力判断

    static func supports(_ channel: Channel) -> Bool {
        if isEnabled(channel.catchUpMode) { return true }
        if let days = channel.catchUpDays, days > 0 { return true }
        if let source = channel.catchUpSource, !source.isEmpty { return true }
        return supports(url: channel.url)
    }

    static func supports(url: String) -> Bool {
        let url = normalized(url)
        if url.contains("${(b)") || url.contains("${(e)") { return true }
        if url.contains("{utc}") || url.contains("{utcend}") { return true }
        guard url.contains("playseek=") else { return false }
        return url.contains("{start}") || url.contains("${start}")
    }

    private static func isEnabled(_ mode: String?) -> Bool {
        guard let mode = mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return false }
        return !["0", "false", "no", "off"].contains(mode)
    }

    // MARK: - 生成回看地址

    /// 生成某段节目的回看地址；不支持回看时返回 nil。
    static func url(for channel: Channel, from: Date, to: Date) -> String? {
        let begin = timeString(from)
        let end = timeString(to)

        if let source = channel.catchUpSource?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            let expanded = expand(source, from: from, to: to)
            if expanded.contains("://") {
                return expanded
            }
            return append(expanded, to: channel.url)
        }

        if supports(url: channel.url) {
            return expand(channel.url, from: from, to: to)
        }

        if isEnabled(channel.catchUpMode) || (channel.catchUpDays ?? 0) > 0 {
            return append("?playseek=\(begin)-\(end)", to: channel.url)
        }

        return nil
    }

    /// 直接对地址模板生成回看地址（兼容只拿到字符串的场景）。
    static func url(for rawURL: String, from: Date, to: Date) -> String? {
        guard supports(url: rawURL) else { return nil }
        return expand(rawURL, from: from, to: to)
    }

    /// 展开模板中的时间占位符。
    static func expand(_ template: String, from: Date, to: Date) -> String {
        var result = normalized(template)
        result = replaceDateTokens(result, date: from, marker: "b")
        result = replaceDateTokens(result, date: to, marker: "e")

        let beginUnix = String(Int(from.timeIntervalSince1970))
        let endUnix = String(Int(to.timeIntervalSince1970))
        result = result.replacingOccurrences(of: "${start}", with: beginUnix)
        result = result.replacingOccurrences(of: "${end}", with: endUnix)
        result = result.replacingOccurrences(of: "{start}", with: beginUnix)
        result = result.replacingOccurrences(of: "{end}", with: endUnix)
        result = result.replacingOccurrences(of: "{utc}", with: beginUnix)
        result = result.replacingOccurrences(of: "{utcend}", with: endUnix)
        return result
    }

    /// 把后缀拼到直播地址上，自动处理 `?` / `&`。
    static func append(_ suffix: String, to baseURL: String) -> String {
        let base = normalized(baseURL)
        var suffix = normalized(suffix)
        guard !suffix.isEmpty else { return base }

        if suffix.hasPrefix("?") || suffix.hasPrefix("&") {
            suffix.removeFirst()
        }
        guard !suffix.isEmpty else { return base }
        if base.hasSuffix("?") || base.hasSuffix("&") {
            return base + suffix
        }
        return base + (base.contains("?") ? "&" : "?") + suffix
    }

    /// 直播地址：去掉 playseek 模板参数。
    static func liveURL(for channel: Channel) -> String {
        liveURL(from: channel.url)
    }

    static func liveURL(from rawURL: String) -> String {
        let url = normalized(rawURL)
        guard let range = url.range(of: "playseek=") else { return url }

        let head = url[..<range.lowerBound]
        let rest = url[range.lowerBound...]
        let tail: Substring
        if let amp = rest.firstIndex(of: "&") {
            tail = rest[amp...]
        } else {
            tail = ""
        }

        var result = String(head) + String(tail)
        while result.contains("&&") {
            result = result.replacingOccurrences(of: "&&", with: "&")
        }
        result = result.replacingOccurrences(of: "?&", with: "?")
        if result.hasSuffix("?") || result.hasSuffix("&") {
            result.removeLast()
        }
        return result
    }

    // MARK: - 时间格式

    /// 本地时区的 `yyyyMMddHHmmss`。
    static func timeString(_ date: Date) -> String {
        formatDate(date, format: defaultFormat)
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func replaceDateTokens(_ text: String, date: Date, marker: String) -> String {
        let pattern = "\\$\\{\\(\(marker)\\)([^}]*)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let format = ns.substring(with: match.range(at: 1))
            let value = formatDate(date, format: format.isEmpty ? defaultFormat : format)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }

    /// 有些列表会把 `&` 写成 `&amp;`，统一还原。
    static func normalized(_ url: String) -> String {
        url.replacingOccurrences(of: "&amp;", with: "&")
    }
}
