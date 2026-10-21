import Foundation

/// 回看 / 时移地址处理。
///
/// 频道地址可以带如下模板参数（`&` 可能被写成 `&amp;`）：
/// `&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}`
///
/// - `supports`：地址是否带回看模板。
/// - `url(for:from:to:)`：把 `${(b)yyyyMMddHHmmss}` / `${(e)yyyyMMddHHmmss}`
///   替换成节目起止时间（本地时区），生成回看地址。
/// - `liveURL(for:)`：去掉 playseek 参数，用于普通直播播放。
enum CatchUp {

    static let beginToken = "${(b)yyyyMMddHHmmss}"
    static let endToken = "${(e)yyyyMMddHHmmss}"
    static let beginShortToken = "${(b)}"
    static let endShortToken = "${(e)}"

    /// 有些列表会把 `&` 写成 `&amp;`，统一还原。
    static func normalized(_ url: String) -> String {
        url.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 地址是否支持回看（带 playseek 模板）。
    static func supports(_ channel: Channel) -> Bool {
        supports(url: channel.url)
    }

    static func supports(url: String) -> Bool {
        let url = normalized(url)
        guard url.contains("playseek=") else { return false }
        return url.contains(beginToken) || url.contains(beginShortToken)
    }

    /// 本地时区的 `yyyyMMddHHmmss`。
    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    /// 生成某段节目的回看地址；不支持回看时返回 nil。
    static func url(for channel: Channel, from: Date, to: Date) -> String? {
        url(for: channel.url, from: from, to: to)
    }

    static func url(for rawURL: String, from: Date, to: Date) -> String? {
        guard supports(url: rawURL) else { return nil }
        let begin = timeString(from)
        let end = timeString(to)

        var result = normalized(rawURL)
        result = result.replacingOccurrences(of: beginToken, with: begin)
        result = result.replacingOccurrences(of: endToken, with: end)
        result = result.replacingOccurrences(of: beginShortToken, with: begin)
        result = result.replacingOccurrences(of: endShortToken, with: end)
        return result
    }

    /// 直播地址：去掉 playseek 参数。
    static func liveURL(for channel: Channel) -> String {
        liveURL(from: channel.url)
    }

    static func liveURL(from rawURL: String) -> String {
        var url = normalized(rawURL)
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
}
