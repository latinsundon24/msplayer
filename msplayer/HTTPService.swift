import Foundation
import CoreFoundation

enum HTTPService {

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// 直播源大量使用自签 / 过期 / 域名不匹配的证书。这里统一放行，
    /// 否则 URLSession（MPD、分片、列表）会直接失败；AVPlayer 的直连由 HLSProxy 兜底。
    final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            NSLog("[msplayer] TLS: 放行证书 %@", challenge.protectionSpace.host)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// 跨线程传递一次结果（Task 内写入，等待后读取）
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Response, Error>?

        func set(_ value: Result<Response, Error>) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Result<Response, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    struct Response {
        let data: Data
        let status: Int
        let headers: [String: String]
        let finalURL: URL?
    }

    enum Failure: LocalizedError {
        case badURL
        case transport(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "地址无效"
            case .transport(let message): return "网络错误：\(message)"
            case .http(let code): return "HTTP \(code)"
            }
        }
    }

    private static let trustDelegate = InsecureTrustDelegate()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
    }()

    /// 证书 / TLS 类错误（用于触发本地代理重试）
    static func isCertificateError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired,
                 -9802, -9813, -9814:
                return true
            default:
                break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isCertificateError(underlying)
        }
        return false
    }

    static func isCertificateError(_ error: Error?) -> Bool {
        guard let error else { return false }
        return isCertificateError(error)
    }

    /// 同步拉数据（在后台线程调用）
    static func fetchSyncData(_ urlString: String, headers: [String: String] = [:]) throws -> Response {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task {
            do {
                let response = try await fetch(urlString, headers: headers)
                box.set(.success(response))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.value else {
            throw Failure.transport("请求未完成")
        }
        return try result.get()
    }

    /// 同步拉文本（在后台线程调用）
    static func fetchSync(_ urlString: String, headers: [String: String] = [:]) throws -> String {
        try decode(fetchSyncData(urlString, headers: headers).data)
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        let response = try await fetch(urlString, headers: headers)
        return decode(response.data)
    }

    /// 内置资源：file:// 直接读磁盘，msplayer-bundle://xxx/yyy 读 App 包内 demo-dash 等目录。
    /// 这样内置演示流完全离线，不依赖任何域名是否可达。
    private static func localResponse(for url: URL) throws -> Response? {
        switch url.scheme?.lowercased() {
        case "file":
            guard let data = try? Data(contentsOf: url) else {
                throw Failure.transport("无法读取本地文件")
            }
            return Response(data: data, status: 200, headers: [:], finalURL: url)
        case "msplayer-bundle":
            guard let base = Bundle.main.resourceURL else {
                throw Failure.transport("App 资源目录不可用")
            }
            let relative = (url.host ?? "") + url.path
            let fileURL = base.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: fileURL) else {
                throw Failure.transport("内置资源缺失：\(relative)")
            }
            return Response(data: data, status: 200, headers: [:], finalURL: url)
        default:
            return nil
        }
    }

    static func fetch(_ urlString: String,
                      headers: [String: String] = [:],
                      range: (Int, Int)? = nil) async throws -> Response {
        guard let url = URL(string: urlString) else { throw Failure.badURL }
        if let local = try localResponse(for: url) { return local }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // 列表显式给了 Cookie 时关掉 URLSession 的自动 Cookie 管理：
        // 否则它自己的 cookie jar 会参与处理，可能把源站校验用的那一份挤掉。
        if headers.keys.contains(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }) {
            request.httpShouldHandleCookies = false
        }
        if let (start, end) = range {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("无 HTTP 响应")
            }
            guard (200..<400).contains(http.statusCode) else {
                throw Failure.http(http.statusCode)
            }
            var headerFields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headerFields[String(describing: key)] = String(describing: value)
            }
            return Response(data: data,
                            status: http.statusCode,
                            headers: headerFields,
                            finalURL: http.url)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// UTF-8 优先，失败回退 GB18030（兼容中文列表）
    static func decode(_ data: Data) -> String {
        TextDecoding.decode(data)
    }
}
