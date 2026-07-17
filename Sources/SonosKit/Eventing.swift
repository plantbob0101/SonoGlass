import Foundation
import Network
import os

private let eventLog = Logger(subsystem: "com.sonoglass", category: "events")

/// Minimal HTTP server that accepts UPnP GENA NOTIFY callbacks.
public final class EventHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ sid: String, _ body: String) -> Void

    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.sonoglass.events")
    private var activeConnections = 0
    private static let maxConnections = 32
    private static let requestTimeout: TimeInterval = 10

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on an ephemeral port; returns the port.
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            let resumed = ResumeGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() {
                        cont.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if resumed.claim() {
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection: connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(connection: NWConnection) {
        guard activeConnections < Self.maxConnections else {
            connection.cancel()
            return
        }
        activeConnections += 1
        let slot = ConnectionSlot { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.activeConnections = max(0, self.activeConnections - 1)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                slot.release()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            connection.cancel()
        }
        receive(connection: connection, accumulated: Data())
    }

    private func receive(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = accumulated
            if let data {
                guard buf.count <= EventHTTPRequestParser.maxRequestBytes - data.count else {
                    self.respond(connection: connection, status: "413 Payload Too Large")
                    return
                }
                buf.append(data)
            }

            switch EventHTTPRequestParser.parse(buf) {
            case .complete(let request):
                self.respond(connection: connection)
                self.handler(request.sid, request.body)
            case .invalid:
                self.respond(connection: connection, status: "400 Bad Request")
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection: connection, accumulated: buf)
                }
            }
        }
    }

    private func respond(connection: NWConnection, status: String = "200 OK") {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private final class ConnectionSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            lock.lock()
            guard !released else { lock.unlock(); return }
            released = true
            lock.unlock()
            onRelease()
        }
    }
}

struct EventHTTPRequest: Equatable {
    let sid: String
    let body: String
}

enum EventHTTPRequestParseResult: Equatable {
    case incomplete
    case invalid
    case complete(EventHTTPRequest)
}

enum EventHTTPRequestParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static let maxRequestBytes = maxHeaderBytes + 4 + maxBodyBytes

    static func parse(_ data: Data) -> EventHTTPRequestParseResult {
        guard data.count <= maxRequestBytes else { return .invalid }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        let headerLength = headerEnd.lowerBound - data.startIndex
        guard headerLength <= maxHeaderBytes else { return .invalid }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .invalid }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[0] == "NOTIFY",
              requestParts[1] == "/notify",
              requestParts[2] == "HTTP/1.1" else { return .invalid }

        var sid: String?
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "sid":
                guard sid == nil, !value.isEmpty else { return .invalid }
                sid = value
            case "content-length":
                guard contentLength == nil,
                      let parsed = Int(value),
                      parsed >= 0,
                      parsed <= maxBodyBytes else { return .invalid }
                contentLength = parsed
            default:
                break
            }
        }
        guard let sid, let contentLength else { return .invalid }

        let bodyStart = headerEnd.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        guard available >= contentLength else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let bodyData = data[bodyStart..<bodyEnd]
        guard let body = String(data: bodyData, encoding: .utf8) else { return .invalid }
        return .complete(EventHTTPRequest(sid: sid, body: body))
    }
}

/// GENA SUBSCRIBE / renew / UNSUBSCRIBE over plain URLRequests.
public enum GENA {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    public struct Subscription: Sendable {
        public let sid: String
        public let timeoutSeconds: Int
        public let ip: String
        public let path: String
    }

    public static func subscribe(ip: String, path: String, callbackURL: String,
                                 timeout: Int = 3600) async throws -> Subscription {
        var request = URLRequest(url: URL(string: "http://\(ip):1400\(path)")!)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let sid = http.value(forHTTPHeaderField: "SID") else {
            throw SonosError(message: "SUBSCRIBE failed for \(path) on \(ip)")
        }
        let granted = parseTimeout(http.value(forHTTPHeaderField: "TIMEOUT")) ?? timeout
        eventLog.info("Subscribed \(path, privacy: .public) on \(ip, privacy: .public) sid=\(sid, privacy: .public) timeout=\(granted)")
        return Subscription(sid: sid, timeoutSeconds: granted, ip: ip, path: path)
    }

    public static func renew(_ sub: Subscription, timeout: Int = 3600) async throws -> Subscription {
        var request = URLRequest(url: URL(string: "http://\(sub.ip):1400\(sub.path)")!)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(sub.sid, forHTTPHeaderField: "SID")
        request.setValue("Second-\(timeout)", forHTTPHeaderField: "TIMEOUT")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SonosError(message: "Renewal failed for \(sub.path)")
        }
        let granted = parseTimeout(http.value(forHTTPHeaderField: "TIMEOUT")) ?? timeout
        return Subscription(sid: sub.sid, timeoutSeconds: granted, ip: sub.ip, path: sub.path)
    }

    public static func unsubscribe(_ sub: Subscription) async {
        var request = URLRequest(url: URL(string: "http://\(sub.ip):1400\(sub.path)")!)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(sub.sid, forHTTPHeaderField: "SID")
        _ = try? await session.data(for: request)
    }

    private static func parseTimeout(_ header: String?) -> Int? {
        guard let header else { return nil }
        if let dash = header.firstIndex(of: "-") {
            return Int(header[header.index(after: dash)...])
        }
        return nil
    }
}
