import Foundation

// MARK: - 清单类型

enum ManifestType: String, Codable, Hashable {
    case auto
    case hls
    case dash
    case smooth
}

// MARK: - 单条线路（m3u 中的一行）

/// 一条可播放地址。同名频道会被 `ChannelGrouping` 合并成一个频道、多条线路。
struct Channel: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var group: String = "默认"
    var logo: String? = nil
    var tvgID: String? = nil

    /// 来自 #KODIPROP:inputstream.adaptive.manifest_type
    var manifestType: ManifestType = .auto

    /// 来自 #KODIPROP:inputstream.adaptive.license_type
    var licenseType: String? = nil

    /// ClearKey：kid(hex) -> key(hex)
    var keys: [String: String] = [:]

    /// license_key 是 URL 的情况（远程取 key）
    var licenseURL: String? = nil

    /// 来自 #EXTVLCOPT / stream_headers
    var headers: [String: String] = [:]

    /// m3u 回看标签：catchup="default" / "append" / "shift" …
    var catchUpMode: String? = nil

    /// catchup-source 模板（可能是完整地址，也可能只是 ?playseek=… 后缀）
    var catchUpSource: String? = nil

    /// catchup-days / timeshift：可回看天数
    var catchUpDays: Int? = nil

    var isDASH: Bool {
        if manifestType == .dash { return true }
        if manifestType == .hls { return false }
        let lower = url.lowercased()
        if lower.hasPrefix("file://") { return lower.hasSuffix(".mpd") }
        if lower.contains(".mpd") { return true }
        if lower.contains(".m3u8") || lower.contains("m3u8?") { return false }
        return false
    }

    var hasClearKey: Bool { !keys.isEmpty }

    /// 界面展示：协议 / 封装
    var formatLabel: String {
        let lower = url.lowercased()
        if isDASH { return "DASH" }
        if lower.hasPrefix("rtmp") { return "RTMP" }
        if lower.hasPrefix("rtsp") { return "RTSP" }
        if lower.hasPrefix("udp") { return "UDP" }
        if lower.hasSuffix(".flv") { return "FLV" }
        if lower.hasSuffix(".ts") { return "TS" }
        if lower.contains(".m3u8") { return "HLS" }
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") { return "MP4" }
        return "直连"
    }

    var hostLabel: String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "本地/内置" }
        return host
    }
}

// MARK: - 频道（同名线路聚合）

struct ChannelGroup: Identifiable, Hashable {
    var name: String
    var logo: String?
    var tvgID: String?
    var lines: [Channel]

    var id: String { name }
    var lineCount: Int { lines.count }
    var primary: Channel { lines.first ?? Channel(name: name, url: "") }
}

enum ChannelGrouping {
    /// 按频道名称聚合：同名 → 多条线路，列表中只出现一次。
    static func groups(from channels: [Channel], keepOrder: Bool = true) -> [ChannelGroup] {
        var order: [String] = []
        var buckets: [String: [Channel]] = [:]
        for channel in channels {
            let key = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(channel)
        }
        let names = keepOrder ? order : order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.compactMap { name in
            guard let lines = buckets[name], !lines.isEmpty else { return nil }
            return ChannelGroup(name: name,
                                logo: lines.first?.logo,
                                tvgID: lines.first?.tvgID,
                                lines: lines)
        }
    }
}

// MARK: - 订阅源

enum SourceKind: String, Codable {
    case remote
    case local
    case builtin
}

struct Source: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    var location: String
    var count: Int = 0
    var updatedAt: Date = Date()
    /// 本地导入时保留原始列表内容，升级后可自动重新解析。
    var content: String? = nil

    var kindLabel: String {
        switch kind {
        case .remote: return "在线"
        case .local: return "本地"
        case .builtin: return "内置"
        }
    }
}

// MARK: - EPG

enum EPGFormat: String, Codable, CaseIterable, Identifiable {
    case xmltv
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xmltv: return "XMLTV (xml)"
        case .json: return "JSON (http://domain/epg/)"
        }
    }

    var hint: String {
        switch self {
        case .xmltv: return "XMLTV / epg.xml 完整节目单地址"
        case .json: return "JSON 基地址，例如 http://domain/epg/"
        }
    }
}

struct EPGSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    /// EPG 数据格式。默认 xmltv，向后兼容已保存的订阅。
    var format: EPGFormat = .xmltv
    var updatedAt: Date? = nil
    var programCount: Int = 0
}

struct EPGProgram: Codable, Identifiable, Hashable {
    var channelID: String
    var title: String
    var subtitle: String? = nil
    var desc: String? = nil
    var start: Date
    var stop: Date

    var id: String { "\(channelID)|\(start.timeIntervalSince1970)|\(title)" }
    var timeRange: String {
        "\(EPGProgram.timeFormatter.string(from: start))-\(EPGProgram.timeFormatter.string(from: stop))"
    }

    func isCurrent(at date: Date = Date()) -> Bool {
        start <= date && date < stop
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// XMLTV 解析结果
struct EPGDatabase: Codable {
    /// XMLTV channel id -> display names
    var channelNames: [String: [String]] = [:]
    /// XMLTV channel id -> programmes (sorted by start)
    var programs: [String: [EPGProgram]] = [:]

    var totalPrograms: Int { programs.values.reduce(0) { $0 + $1.count } }
}

// MARK: - 解码 / 设置

enum DecoderKind: String, Codable, CaseIterable, Identifiable {
    case auto
    case system
    case vlc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .system: return "系统解码 AVPlayer"
        case .vlc: return "VLC 兼容解码"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "HLS 用系统解码；FLV/RTMP/RTSP 等交给 VLC"
        case .system: return "系统原生硬解，省电、首帧快"
        case .vlc: return "libVLC 软解，兼容性最好，费电"
        }
    }
}

enum VideoAspect: String, Codable, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "自适应（完整画面）"
        case .fill: return "全屏填充（裁边）"
        case .stretch: return "拉伸铺满"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var aspect: VideoAspect = .fit
    var autoHideSidebars: Bool = true
    var autoHideDelay: Double = 4
    var showBottomBar: Bool = true
    var autoPlay: Bool = true
    var decoder: DecoderKind = .auto

    static let `default` = AppSettings()
}
