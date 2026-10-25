import Foundation

/// JSON 格式 EPG 单频道单日节目单解析。
///
/// 设计目标：兼容社区常见、但彼此略有不同的 JSON schema，避免和某一个
/// 特定后端强耦合。已兼容的形状：
///  - 顶层数组：`[{ "title":.., "start":.., "stop"/"end":.. }, ...]`
///  - 顶层对象含 `programs` / `items` / `list` / `epg` / `data` / `result` 等数组字段，
///    或形如 `{ "data": { "list": [...] } }` 的嵌套包装
///  - 顶层对象以「频道名 -> 数组」形式给出（如 `{ "CCTV1": [...] }`）
///
/// 字段名做了中英文多别名兼容；时间支持 ISO8601、`yyyy-MM-dd HH:mm:ss`、
/// Unix 时间戳（秒/毫秒）、常见日期格式，以及仅「时:分」的节目时间（用当天补全）。
final class JSONEPGParser {

    /// 将单频道单日 JSON 解析为节目数组。
    /// - Parameters:
    ///   - data: 接口返回的 JSON 数据
    ///   - channelID: 调用方指定的频道键（通常为频道名 / tvg-id），
    ///                用于后续通过 `EPGMatching` 与 m3u 频道匹配。
    ///   - day: 该日日期，用于把只有「时:分」的节目时间锚定到当天。
    static func parse(data: Data, channelID: String, day: Date? = nil) -> [EPGProgram] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        let rawPrograms = extractPrograms(from: json)
        var result: [EPGProgram] = []
        for raw in rawPrograms {
            guard let dict = raw as? [String: Any] else { continue }
            let title = stringValue(dict, keys: ["title", "name", "program", "programme", "t", "标题", "名称"])?
                .nilIfEmpty
            guard let title, !title.isEmpty else { continue }
            let subtitle = stringValue(dict, keys: ["subtitle", "sub", "subTitle", "副标题"])?.nilIfEmpty
            let desc = stringValue(dict, keys: ["desc", "description", "detail", "synopsis", "info", "简介", "描述"])?.nilIfEmpty
            let startRaw = stringValue(dict, keys: ["start", "begin", "time", "startTime", "starttime", "s", "开始", "起"])
            let stopRaw = stringValue(dict, keys: ["stop", "end", "endTime", "endtime", "e", "结束"])
            guard let startRaw, let start = XMLTVDate.parse(startRaw, anchor: day) else { continue }
            let stop = XMLTVDate.parse(stopRaw, anchor: day) ?? start.addingTimeInterval(3600)
            result.append(EPGProgram(channelID: channelID,
                                     title: title,
                                     subtitle: subtitle,
                                     desc: desc,
                                     start: start,
                                     stop: stop))
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: - 结构兼容

    /// 从各种可能的 JSON 形状中提取出「节目对象数组」。
    private static func extractPrograms(from json: Any) -> [Any] {
        // 顶层就是数组
        if let array = json as? [Any], looksLikePrograms(array) {
            return array
        }
        // 顶层对象
        if let dict = json as? [String: Any] {
            // 形如 { "频道A": [...], "频道B": [...] }：所有 value 都是数组
            let arrayValues = dict.values.compactMap { $0 as? [Any] }
            if !arrayValues.isEmpty, arrayValues.count == dict.count {
                let flat = arrayValues.flatMap { $0 }
                if looksLikePrograms(flat) { return flat }
            }
            // 形如 { "programs": [...] } / { "epg": [...] } 等已知键
            for key in ["programs", "items", "list", "epg", "data", "schedule",
                        "listings", "result", "rows", "节目", "列表", "items"] {
                if let arr = dict[key] as? [Any], looksLikePrograms(arr) { return arr }
                // 嵌套一层：{ "data": { "list": [...] } }
                if let inner = dict[key] as? [String: Any],
                   let arr = findProgramArray(in: inner) { return arr }
            }
            // 兜底：递归搜索第一个看起来像节目的数组
            if let found = findProgramArray(in: dict) { return found }
        }
        return []
    }

    /// 递归在任意嵌套结构中寻找第一个「看起来像节目」的数组。
    private static func findProgramArray(_ value: Any) -> [Any]? {
        if let arr = value as? [Any], looksLikePrograms(arr) { return arr }
        if let dict = value as? [String: Any] {
            for (_, v) in dict {
                if let found = findProgramArray(v) { return found }
            }
        }
        return nil
    }

    /// 判断一个数组是否像「节目列表」：首个元素是带标题/时间字段的对象。
    private static func looksLikePrograms(_ array: [Any]) -> Bool {
        guard let first = array.first as? [String: Any] else { return false }
        let keys = Set(first.keys.map { $0.lowercased() })
        return !keys.intersection(["title", "name", "start", "time", "begin", "节目", "名称"]).isEmpty
    }

    /// 多别名取首个非空字符串值；数字也接受（转为字符串）。
    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let str = value as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let num = value as? NSNumber {
                return num.stringValue
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
