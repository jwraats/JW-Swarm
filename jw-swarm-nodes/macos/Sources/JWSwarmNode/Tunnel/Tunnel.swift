import Foundation
import Security

class Tunnel: NSObject, @unchecked Sendable, URLSessionDelegate, URLSessionWebSocketDelegate {
    private let fleetURL: URL
    private let nodeCertPath: String
    private let caCertPath: String

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var loopTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var onMessage: ((String) -> Void)?
    private var onConnectionStateChanged: ((Bool) -> Void)?
    private var backoff: Double = 1
    private var queue: [String] = []
    private var reconnectingAfterError: Bool = false
    private var connectionAttempt: UInt64 = 0
    private var lastPingRTTms: Double = 0

    private var clientIdentity: SecIdentity?
    private var clientCertChain: [SecCertificate] = []
    private var caCertificates: [SecCertificate] = []

    private let stateQueue = DispatchQueue(label: "com.jw.swarm.tunnel.state")
    private let tlsQueue = DispatchQueue(label: "com.jw.swarm.tunnel.tls")

    init(_ url: URL, nodeCertPath: String, caCertPath: String) {
        self.fleetURL = url
        self.nodeCertPath = nodeCertPath
        self.caCertPath = caCertPath
        super.init()

        loadTLSMaterials()

        let config = URLSessionConfiguration.default
        // Tunnel connections are long-lived; short request/resource timeouts
        // can terminate healthy WebSocket sessions before heartbeats arrive.
        config.timeoutIntervalForRequest = 24 * 60 * 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func startLoop() {
        stateQueue.sync {
            if let existing = loopTask, !existing.isCancelled {
                return
            }
        }

        let task: Task<Void, Never> = Task.detached { [weak self] in
            guard let self else { return }
            await self.run()
        }
        stateQueue.sync {
            loopTask = task
        }
    }

    func stop() {
        let activeTask = stateQueue.sync { () -> Task<Void, Never>? in
            let t = loopTask
            loopTask = nil
            let ka = keepAliveTask
            keepAliveTask = nil
            let s = socket
            socket = nil
            ka?.cancel()
            s?.cancel(with: .goingAway, reason: nil)
            return t
        }
        activeTask?.cancel()

        session?.invalidateAndCancel()
        session = nil
        notifyConnectionState(false)
    }

    deinit {
        stop()
    }

    private func loadTLSMaterials() {
        do {
            let identityAndChain = try loadClientIdentity(from: nodeCertPath)
            tlsQueue.sync {
                clientIdentity = identityAndChain.identity
                clientCertChain = identityAndChain.chain
            }
        } catch {
            tlsQueue.sync {
                clientIdentity = nil
                clientCertChain = []
            }
            NSLog("[Tunnel] Failed to load client identity: \(error.localizedDescription)")
        }

        do {
            let cas = try loadCACertificates(from: caCertPath)
            tlsQueue.sync {
                caCertificates = cas
            }
        } catch {
            tlsQueue.sync {
                caCertificates = []
            }
            NSLog("[Tunnel] Failed to load CA certificates: \(error.localizedDescription)")
        }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let s = session else {
                return
            }

            let attempt = stateQueue.sync { () -> UInt64 in
                connectionAttempt += 1
                return connectionAttempt
            }
            NSLog("[Tunnel] connecting attempt #\(attempt) to \(fleetURL.absoluteString)")

            let t = s.webSocketTask(with: fleetURL)
            t.resume()
            stateQueue.sync {
                socket = t
                reconnectingAfterError = false
                lastPingRTTms = 0
                keepAliveTask?.cancel()
                keepAliveTask = Task.detached { [weak self] in
                    await self?.runKeepAlive(for: t)
                }
            }

            await drainMessages(using: t)

            while !Task.isCancelled {
                do {
                    let r = try await t.receive()
                    switch r {
                    case .string(let s):
                        let handler = stateQueue.sync { onMessage }
                        handler?(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) {
                            let handler = stateQueue.sync { onMessage }
                            handler?(s)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    NSLog("[Tunnel] receive failed: \(error.localizedDescription)")
                    break
                }
            }

            stateQueue.sync {
                keepAliveTask?.cancel()
                keepAliveTask = nil
            }
            notifyConnectionState(false)
            t.cancel()

            let delay = stateQueue.sync { () -> Double in
                socket = nil
                let current = backoff
                backoff = min(backoff * 2, 60)
                return current
            }
            NSLog("[Tunnel] reconnecting in \(String(format: "%.1f", delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func drainMessages(using sock: URLSessionWebSocketTask) async {
        let pending = stateQueue.sync { () -> [String] in
            let out = queue
            queue = []
            return out
        }

        for msg in pending {
            try? await sock.send(.string(msg))
        }
    }

    func send(_ text: String) {
        Task.detached { [weak self] in
            guard let self else { return }
            if let sock = self.stateQueue.sync(execute: { self.socket }) {
                do {
                    try await sock.send(.string(text))
                } catch {
                    let shouldLog = self.stateQueue.sync { () -> Bool in
                        if self.reconnectingAfterError {
                            return false
                        }
                        self.reconnectingAfterError = true
                        return true
                    }
                    if shouldLog {
                        NSLog("[Tunnel] send failed, forcing reconnect: \(error.localizedDescription)")
                    }
                    self.stateQueue.sync {
                        self.queue.append(text)
                    }
                    sock.cancel(with: .goingAway, reason: nil)
                }
                return
            }
            self.stateQueue.sync {
                self.queue.append(text)
            }
        }
    }

    private func runKeepAlive(for task: URLSessionWebSocketTask) async {
        // Send one ping immediately so latency is available shortly after the
        // connection opens, then keep pinging on the keepalive interval.
        while !Task.isCancelled {
            do {
                try await sendPing(on: task)
            } catch {
                NSLog("[Tunnel] ping failed, reconnecting: \(error.localizedDescription)")
                task.cancel(with: .goingAway, reason: nil)
                return
            }

            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if Task.isCancelled {
                return
            }
        }
    }

    private func sendPing(on task: URLSessionWebSocketTask) async throws {
        let start = DispatchTime.now()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { [weak self] error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let rtt = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    self?.stateQueue.sync { self?.lastPingRTTms = rtt }
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// Round-trip latency (ms) of the most recent WebSocket ping, or `nil` when
    /// no successful ping has completed on the current connection.
    func latencyMs() -> Double? {
        stateQueue.sync { lastPingRTTms > 0 ? lastPingRTTms : nil }
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        stateQueue.sync {
            onMessage = handler
        }
    }

    func setConnectionStateHandler(_ handler: @escaping (Bool) -> Void) {
        stateQueue.sync {
            onConnectionStateChanged = handler
        }
    }

    private func notifyConnectionState(_ connected: Bool) {
        let handler = stateQueue.sync { onConnectionStateChanged }
        handler?(connected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol `protocol`: String?
    ) {
        stateQueue.sync {
            reconnectingAfterError = false
            backoff = 1
        }
        NSLog("[Tunnel] connected")
        notifyConnectionState(true)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText: String
        if let reason, let str = String(data: reason, encoding: .utf8), !str.isEmpty {
            reasonText = str
        } else {
            reasonText = "-"
        }
        NSLog("[Tunnel] closed (code=\(closeCode.rawValue), reason=\(reasonText))")
        notifyConnectionState(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            NSLog("[Tunnel] task completed with error: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            let material = tlsQueue.sync { (clientIdentity, clientCertChain) }
            guard let identity = material.0 else {
                NSLog("[Tunnel] mTLS client cert challenge without loaded identity")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let certs: [Any] = material.1.isEmpty ? [] : material.1
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: certs, persistence: .forSession))
            return
        }

        if method == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            let anchors = tlsQueue.sync { caCertificates }
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
            }

            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                let msg = error.map { CFErrorCopyDescription($0) as String } ?? "unknown trust error"
                NSLog("[Tunnel] Server trust validation failed: \(msg)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private func loadClientIdentity(from path: String) throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "TunnelTLS", code: 1, userInfo: [NSLocalizedDescriptionKey: "node cert file missing at \(url.path)"])
        }

        let temporaryPKCS12Password = "jwswarm-temp"

        let ext = url.pathExtension.lowercased()
        if ext == "p12" || ext == "pfx" {
            let data = try Data(contentsOf: url)
            return try importPKCS12(data: data, password: ProcessInfo.processInfo.environment["JW_NODE_CERT_PASSWORD"] ?? "")
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jwswarm-node-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: temp) }

        let args = [
            "pkcs12",
            "-export",
            "-in", url.path,
            "-inkey", url.path,
            "-out", temp.path,
            "-passout", "pass:\(temporaryPKCS12Password)",
        ]
        let output = try runOpenSSL(args: args)
        if output.exitCode != 0 {
            throw NSError(domain: "TunnelTLS", code: 2, userInfo: [NSLocalizedDescriptionKey: "openssl conversion failed: \(output.text)"])
        }

        let p12 = try Data(contentsOf: temp)
        return try importPKCS12(data: p12, password: temporaryPKCS12Password)
    }

    private func importPKCS12(data: Data, password: String) throws -> (identity: SecIdentity, chain: [SecCertificate]) {
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let first = items.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            throw NSError(domain: "TunnelTLS", code: 3, userInfo: [NSLocalizedDescriptionKey: "unable to import PKCS#12 identity"])
        }
          let identity = rawIdentity as! SecIdentity

        if let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] {
            return (identity, chain)
        }

        var leaf: SecCertificate?
        let statusCert = SecIdentityCopyCertificate(identity, &leaf)
        let fallbackChain: [SecCertificate] = (statusCert == errSecSuccess && leaf != nil) ? [leaf!] : []
        return (identity, fallbackChain)
    }

    private func loadCACertificates(from path: String) throws -> [SecCertificate] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "TunnelTLS", code: 4, userInfo: [NSLocalizedDescriptionKey: "CA cert file missing at \(url.path)"])
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        let certs = parsePEMCertificates(text)
        if certs.isEmpty {
            throw NSError(domain: "TunnelTLS", code: 5, userInfo: [NSLocalizedDescriptionKey: "no CA certificates found in \(url.path)"])
        }
        return certs
    }

    private func parsePEMCertificates(_ text: String) -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"

        var certs: [SecCertificate] = []
        var searchStart = text.startIndex
        while let beginRange = text.range(of: begin, range: searchStart..<text.endIndex),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) {
            let body = text[beginRange.upperBound..<endRange.lowerBound]
            let base64 = body
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let der = Data(base64Encoded: base64),
               let cert = SecCertificateCreateWithData(nil, der as CFData) {
                certs.append(cert)
            }
            searchStart = endRange.upperBound
        }
        return certs
    }

    private func runOpenSSL(args: [String]) throws -> (exitCode: Int32, text: String) {
        let tool = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw NSError(domain: "TunnelTLS", code: 6, userInfo: [NSLocalizedDescriptionKey: "openssl not found at /usr/bin/openssl"])
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        try p.run()
        p.waitUntilExit()

        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }
}