import Foundation
import Network

enum GGNetworkError: LocalizedError {
    case invalidProxy(String)
    case noProxyConfigured
    case outOfBandwidth
    case httpStatus(Int)
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .invalidProxy(let value): return "Invalid proxy URL: \(value)"
        case .noProxyConfigured: return "Proxy mode is enabled, but no proxy is configured."
        case .outOfBandwidth: return "MEGA returned HTTP 509 (bandwidth limit). The transfer was paused."
        case .httpStatus(let code): return "The server returned HTTP \(code)."
        case .missingDownloadURL: return "MEGA did not return a download URL."
        }
    }
}

struct ProxyEndpoint: Hashable {
    let scheme: String
    let host: String
    let port: Int
    let username: String?
    let password: String?

    var normalized: String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port
        c.user = username
        c.password = password
        return c.string ?? "\(scheme)://\(host):\(port)"
    }

    static func parse(_ raw: String) -> ProxyEndpoint? {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = c.host, !host.isEmpty else { return nil }
        let defaultPort = (scheme == "socks5" || scheme == "socks5h") ? 1080 : 8080
        let port = c.port ?? defaultPort
        guard (1...65535).contains(port) else { return nil }
        return ProxyEndpoint(scheme: scheme, host: host, port: port,
                             username: c.user, password: c.password)
    }

    var networkConfiguration: ProxyConfiguration {
        let proxyPort = NWEndpoint.Port(rawValue: UInt16(port))!
        let endpoint = NWEndpoint.hostPort(host: .name(host, nil), port: proxyPort)
        var configuration: ProxyConfiguration
        switch scheme {
        case "http":
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case "https":
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint,
                                                tlsOptions: NWProtocolTLS.Options())
        default:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if let username {
            configuration.applyCredential(username: username, password: password ?? "")
        }
        // Never fall back to a direct connection if the selected proxy fails.
        configuration.allowFailover = false
        return configuration
    }

    var credential: URLCredential? {
        guard let username else { return nil }
        return URLCredential(user: username, password: password ?? "", persistence: .forSession)
    }
}

private final class ProxyAuthenticationDelegate: NSObject, URLSessionTaskDelegate {
    let endpoint: ProxyEndpoint?
    init(endpoint: ProxyEndpoint?) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), let credential = endpoint?.credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class ProxyHTTPClient {
    private let settings: GGSettings

    init(settings: GGSettings) { self.settings = settings }

    private func selectedProxy() throws -> ProxyEndpoint? {
        switch settings.proxyMode {
        case .none:
            return nil
        case .single:
            guard let raw = settings.proxies.first, let proxy = ProxyEndpoint.parse(raw) else {
                throw GGNetworkError.noProxyConfigured
            }
            return proxy
        case .random:
            guard !settings.proxies.isEmpty else { throw GGNetworkError.noProxyConfigured }
            let raw = settings.proxies[Int.random(in: 0..<settings.proxies.count)]
            guard let proxy = ProxyEndpoint.parse(raw) else { throw GGNetworkError.invalidProxy(raw) }
            return proxy
        }
    }

    private func configuration(for endpoint: ProxyEndpoint?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = settings.timeoutSeconds
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let endpoint { configuration.proxyConfigurations = [endpoint.networkConfiguration] }
        return configuration
    }

    func data(for request: URLRequest) async throws -> Data {
        // Select independently for every API request. Random mode therefore rotates
        // across metadata calls and subsequent retry attempts.
        let endpoint = try selectedProxy()
        let delegate = ProxyAuthenticationDelegate(endpoint: endpoint)
        let session = URLSession(configuration: configuration(for: endpoint),
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 509 { throw GGNetworkError.outOfBandwidth }
        guard (200..<300).contains(http.statusCode) else { throw GGNetworkError.httpStatus(http.statusCode) }
        return data
    }

    func download(request: URLRequest, encryptedPartialURL: URL, remoteSize: UInt64,
                  resumeOffset: UInt64,
                  progress: @escaping @Sendable (UInt64, Double) -> Void) async throws {
        // One proxy is pinned for the lifetime of this HTTP response. The next
        // transfer or retry selects again, as in Giga Grabber's random mode.
        let endpoint = try selectedProxy()
        let delegate = StreamingFileDelegate(endpoint: endpoint,
                                             destination: encryptedPartialURL,
                                             expectedSize: remoteSize,
                                             resumeOffset: resumeOffset,
                                             progress: progress)
        let session = URLSession(configuration: configuration(for: endpoint),
                                 delegate: delegate, delegateQueue: nil)
        delegate.session = session
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.begin(request: request, continuation: continuation)
            }
        }, onCancel: {
            delegate.cancel()
        })
    }
}

private final class StreamingFileDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: ProxyEndpoint?
    private let destination: URL
    private let expectedSize: UInt64
    private let resumeOffset: UInt64
    private let progress: @Sendable (UInt64, Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received: UInt64 = 0
    private var startTime = Date()
    private var terminalError: Error?
    private var acceptedResponse = false
    weak var session: URLSession?

    init(endpoint: ProxyEndpoint?, destination: URL, expectedSize: UInt64, resumeOffset: UInt64,
         progress: @escaping @Sendable (UInt64, Double) -> Void) {
        self.endpoint = endpoint
        self.destination = destination
        self.expectedSize = expectedSize
        self.resumeOffset = resumeOffset
        self.progress = progress
    }

    func begin(request: URLRequest, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        startTime = Date()
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), let credential = endpoint?.credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            terminalError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 509 {
            terminalError = GGNetworkError.outOfBandwidth
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            terminalError = GGNetworkError.httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            // If the origin ignored Range and returned 200, discard the old partial.
            if http.statusCode == 200 && resumeOffset > 0 {
                try handle.truncate(atOffset: 0)
                received = 0
            } else if http.statusCode == 206 {
                try handle.seekToEnd()
                received = resumeOffset
            } else {
                try handle.truncate(atOffset: 0)
                received = 0
            }
            file = handle
            acceptedResponse = true
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard acceptedResponse, let file else { return }
        do {
            try file.write(contentsOf: data)
            received += UInt64(data.count)
            let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
            progress(min(received, expectedSize), Double(received >= resumeOffset ? received - resumeOffset : received) / elapsed)
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        try? file?.synchronize()
        try? file?.close()
        let resultError = terminalError ?? error
        lock.lock()
        let callback = continuation
        continuation = nil
        lock.unlock()
        if let resultError {
            callback?.resume(throwing: resultError)
        } else if acceptedResponse {
            callback?.resume()
        } else {
            callback?.resume(throwing: URLError(.badServerResponse))
        }
        session.finishTasksAndInvalidate()
    }
}
