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
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, accumulated: Data())
    }

    private func receive(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }

            if let request = Self.completeRequest(from: buf) {
                self.respond(connection: connection)
                self.handler(request.sid, request.body)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection: connection, accumulated: buf)
        }
    }

    private func respond(connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func completeRequest(from data: Data) -> (sid: String, body: String)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var sid = ""
        var contentLength = 0
        for line in headerText.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "sid" { sid = value }
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        let bodyStart = headerEnd.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        guard available >= contentLength else { return nil }
        let bodyData = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
        return (sid, String(data: bodyData, encoding: .utf8) ?? "")
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
