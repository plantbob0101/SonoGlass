import Foundation
import Network
import os

private let eventLog = Logger(subsystem: "com.sonoglass", category: "events")

/// Minimal HTTP server that accepts UPnP GENA NOTIFY callbacks.
public final class EventHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ sid: String, _ body: String) -> Void

    private let handler: Handler
    private var listener: NWListener?
    private var pendingStartup: StartupCompletion?
    private let listenerLock = NSLock()
    private let queue = DispatchQueue(label: "com.sonoglass.events")
    private var activeConnections = 0
    private static let maxConnections = 32
    private static let requestTimeout: TimeInterval = 10

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on an ephemeral port; returns the port.
    public func start() async throws -> UInt16 {
        try Task.checkCancellation()
        let listener = try NWListener(using: .tcp, on: .any)
        let startup = StartupCompletion()
        let alreadyStarted = listenerLock.withLock {
            guard self.listener == nil else { return true }
            self.listener = listener
            pendingStartup = startup
            return false
        }
        guard !alreadyStarted else { throw SonosError(message: "Event server is already running") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Cancellation can happen before this closure runs. Installing
                // into shared state immediately delivers any stored result.
                startup.install(cont)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue, port > 0 {
                            startup.complete(.success(port))
                        } else {
                            if let listener {
                                self?.clearListener(listener)
                                listener.cancel()
                            }
                            startup.complete(.failure(SonosError(message: "Event server has no listening port")))
                        }
                    case .failed(let error):
                        if let listener {
                            self?.clearListener(listener)
                            listener.cancel()
                        }
                        startup.complete(.failure(error))
                    case .cancelled:
                        if let listener { self?.clearListener(listener) }
                        startup.complete(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection: connection)
                }
                if !startup.isCompleted { listener.start(queue: queue) }
            }
        } onCancel: {
            // NWListener need not deliver a state callback when it is cancelled
            // before start/handler installation; resume independently of it.
            self.clearListener(listener)
            listener.cancel()
            startup.complete(.failure(CancellationError()))
        }
    }

    public func stop() {
        let (current, startup) = listenerLock.withLock {
            let current = listener
            let startup = pendingStartup
            listener = nil
            pendingStartup = nil
            return (current, startup)
        }
        current?.cancel()
        startup?.complete(.failure(CancellationError()))
    }

    private func clearListener(_ listener: NWListener) {
        listenerLock.withLock {
            if self.listener === listener {
                self.listener = nil
                pendingStartup = nil
            }
        }
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

    /// Stores completion even if cancellation wins the race to install the
    /// continuation. Completion and installation each resume outside the lock.
    private final class StartupCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<UInt16, Error>?
        private var continuation: CheckedContinuation<UInt16, Error>?

        var isCompleted: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<UInt16, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func complete(_ result: Result<UInt16, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
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
        var request = URLRequest(url: try subscriptionURL(ip: ip, path: path))
        guard let callback = URLComponents(string: callbackURL), callback.scheme == "http",
              let host = callback.host, SonosAddress.privateIPv4(host) != nil,
              callback.user == nil, callback.password == nil, callback.fragment == nil else {
            throw SonosError(message: "Event callback must be a private IPv4 HTTP address")
        }
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
        eventLog.info("Subscribed \(path, privacy: .public) on \(ip, privacy: .public) sid=\(sid, privacy: .private(mask: .hash)) timeout=\(granted)")
        return Subscription(sid: sid, timeoutSeconds: granted, ip: ip, path: path)
    }

    public static func renew(_ sub: Subscription, timeout: Int = 3600) async throws -> Subscription {
        var request = URLRequest(url: try subscriptionURL(ip: sub.ip, path: sub.path))
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
        guard let url = try? subscriptionURL(ip: sub.ip, path: sub.path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(sub.sid, forHTTPHeaderField: "SID")
        _ = try? await session.data(for: request)
    }

    static func subscriptionURL(ip: String, path: String) throws -> URL {
        guard let ip = SonosAddress.privateIPv4(ip), path.hasPrefix("/"),
              !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SonosError(message: "Invalid Sonos event subscription address")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = 1400
        components.path = path
        guard let url = components.url else { throw SonosError(message: "Invalid Sonos event path") }
        return url
    }

    static func parseTimeout(_ header: String?) -> Int? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("second-"),
              let seconds = Int(header.dropFirst(7)), seconds > 0 else { return nil }
        // Limit untrusted server values before scheduling or converting units.
        return min(seconds, 86_400)
    }

    static func renewalDelay(timeoutSeconds: Int) -> TimeInterval {
        // Renew short grants before expiry, and periodically renew "infinite"
        // grants as well so a player restart cannot strand the subscription.
        max(0.5, min(Double(timeoutSeconds) / 2, 1800))
    }
}
