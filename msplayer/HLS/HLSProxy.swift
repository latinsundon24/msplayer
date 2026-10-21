import Foundation

/// HLS 本地代理：
///   - 解决 AVPlayer 无法放行自签 / 过期 / 域名不匹配证书的问题
///   - 顺带让分片请求也带上列表里的 UA / Referer
///
/// 播放列表会被重写：所有 URI（子清单、分片、EXT-X-MAP、EXT-X-KEY、EXT-X-MEDIA…）
/// 都指向本机回环地址，由 URLSession（已放行证书）实际取流。
final class HLSProxy {

    let entryURL: URL
    private let server: LocalHTTPServer
    private let core: Core

    init(channel: Channel) throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let core = Core(channel: channel, token: token)
        let server = try LocalHTTPServer { path, _ in
            core.handle(path: path)
        }
        core.port = server.port
        guard let url = URL(string: "http://127.0.0.1:\(server.port)/\(token)/\(Core.encode(channel.url))") else {
            throw NSError(domain: "MSPlayerHLSProxy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "代理地址生成失败"])
        }
        self.core = core
        self.server = server
        self.entryURL = url
        NSLog("[msplayer] HLS 代理已启动: %@ -> %@", url.absoluteString, channel.url)
    }

    func stop() {
        server.stop()
    }

    // MARK: - 核心逻辑

    final class Core {
        private let channel: Channel
        private let token: String
        var port: UInt16 = 0

        init(channel: Channel, token: String) {
            self.channel = channel
            self.token = token
        }

        func handle(path: String) -> (Int, String, Data) {
            let prefix = "/\(token)/"
            guard path.hasPrefix(prefix) else { return (404, "text/plain", Data()) }
            let encoded = String(path.dropFirst(prefix.count))
            guard let targetString = Self.decode(encoded),
                  let target = URL(string: targetString) else {
                return (400, "text/plain", Data("bad url".utf8))
            }

            do {
                let response = try HTTPService.fetchSyncData(target.absoluteString, headers: channel.headers)
                let base = response.finalURL ?? target
                var data = response.data
                var mime = Self.mimeType(for: base, contentType: response.headers["Content-Type"], data: data)

                if Self.isPlaylist(data) {
                    let text = HTTPService.decode(data)
                    let proxyBase = "http://127.0.0.1:\(port)/\(token)/"
                    let rewritten = Self.rewritePlaylist(text, base: base, proxyBase: proxyBase)
                    data = Data(rewritten.utf8)
                    mime = "application/vnd.apple.mpegurl"
                }
                return (200, mime, data)
            } catch {
                NSLog("[msplayer] HLS 代理失败 %@: %@", target.absoluteString, String(describing: error))
                return (502, "text/plain", Data())
            }
        }

        // MARK: 编码

        static func encode(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func decode(_ string: String) -> String? {
            var value = string
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while value.count % 4 != 0 { value += "=" }
            guard let data = Data(base64Encoded: value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // MARK: 播放列表重写

        static func isPlaylist(_ data: Data) -> Bool {
            let head = data.prefix(16)
            guard let text = String(data: head, encoding: .utf8) else { return false }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
        }

        static func rewritePlaylist(_ text: String, base: URL, proxyBase: String) -> String {
            var lines: [String] = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    lines.append(raw)
                } else if line.hasPrefix("#") {
                    lines.append(rewriteTag(line, base: base, proxyBase: proxyBase))
                } else {
                    lines.append(proxyURL(line, base: base, proxyBase: proxyBase) ?? raw)
                }
            }
            return lines.joined(separator: "\n")
        }

        /// 处理 #EXT-X-MAP:URI="…" / #EXT-X-KEY:URI="…" / #EXT-X-MEDIA:URI="…" 等
        private static func rewriteTag(_ line: String, base: URL, proxyBase: String) -> String {
            guard line.contains("URI=\"") else { return line }
            var result = ""
            var rest = Substring(line)
            while let range = rest.range(of: "URI=\"") {
                result += rest[..<range.upperBound]
                rest = rest[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else {
                    result += rest
                    return result
                }
                let uri = String(rest[..<end])
                result += proxyURL(uri, base: base, proxyBase: proxyBase) ?? uri
                rest = rest[end...]
            }
            result += rest
            return result
        }

        static func proxyURL(_ uri: String, base: URL, proxyBase: String) -> String? {
            guard !uri.isEmpty, !uri.hasPrefix("data:") else { return nil }
            guard let absolute = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
            guard let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            return proxyBase + encode(absolute.absoluteString)
        }

        // MARK: MIME

        static func mimeType(for url: URL, contentType: String?, data: Data) -> String {
            switch url.pathExtension.lowercased() {
            case "m3u8", "m3u": return "application/vnd.apple.mpegurl"
            case "ts", "mts", "m2ts": return "video/mp2t"
            case "m4s": return "video/iso.segment"
            case "mp4", "m4v": return "video/mp4"
            case "aac": return "audio/aac"
            case "mp3": return "audio/mpeg"
            case "key": return "application/octet-stream"
            default: break
            }
            if let type = contentType?.lowercased(), !type.isEmpty, !type.contains("text/html") {
                return type
            }
            return "application/octet-stream"
        }
    }
}
