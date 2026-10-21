import Foundation
import Network

/// 极简回环 HTTP 服务器：给 AVPlayer 提供本地 HLS
final class LocalHTTPServer {

    typealias Handler = (String, String?) -> (status: Int, mime: String, body: Data)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "msplayer.localhttp")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "MSPlayerHTTP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "本地服务器启动失败"])
        }
        self.port = port.rawValue
        listener.stateUpdateHandler = nil
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }

    deinit { listener.cancel() }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard connections.count < 16 else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let self, let connection {
                self.lock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                self.lock.unlock()
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 90) { [weak connection] in
            connection?.cancel()
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var data = buffer
            if let bytes { data.append(bytes) }
            guard data.count <= 32 * 1024 else {
                connection.cancel()
                return
            }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.respond(connection, request: data)
                }
            } else if complete {
                connection.cancel()
            } else {
                self.read(connection, buffer: data)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, ["GET", "HEAD"].contains(String(first[0])) else {
            connection.cancel()
            return
        }
        var path = String(first[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }

        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        let (status, mime, body) = handler(path, rangeHeader)

        var response = Data()
        var extra = ""
        var payload = body
        var finalStatus = status

        if status == 200, let rangeHeader, !body.isEmpty {
            let field = rangeHeader.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let pieces = field.hasPrefix("bytes=") ? field.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
            let total = body.count
            if pieces.count == 2, total > 0 {
                let startPart = pieces[0].isEmpty ? nil : Int(pieces[0])
                let endPart = pieces[1].isEmpty ? nil : Int(pieces[1])
                let start: Int
                let end: Int
                if let startPart {
                    start = max(0, startPart)
                    end = endPart ?? (total - 1)
                } else if let suffix = endPart {
                    start = max(0, total - suffix)
                    end = total - 1
                } else {
                    start = 0
                    end = total - 1
                }
                if start < total, end >= start {
                    let last = min(end, total - 1)
                    payload = body.subdata(in: start..<(last + 1))
                    extra = "Content-Range: bytes \(start)-\(last)/\(total)\r\n"
                    finalStatus = 206
                } else {
                    payload = Data()
                    finalStatus = 416
                    extra = "Content-Range: bytes */\(total)\r\n"
                }
            }
        }

        let phrase: String
        switch finalStatus {
        case 200: phrase = "OK"
        case 206: phrase = "Partial Content"
        case 404: phrase = "Not Found"
        case 410: phrase = "Gone"
        case 416: phrase = "Range Not Satisfiable"
        case 503: phrase = "Service Unavailable"
        default: phrase = "Error"
        }

        var head = "HTTP/1.1 \(finalStatus) \(phrase)\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-store\r\n"
        head += extra
        head += "Connection: close\r\n\r\n"
        response.append(Data(head.utf8))
        if String(first[0]) != "HEAD" { response.append(payload) }

        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
