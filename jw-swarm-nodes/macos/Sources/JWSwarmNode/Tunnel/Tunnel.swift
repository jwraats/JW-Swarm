import Foundation
import Security

class Tunnel {
    private let fleetURL: URL
    private let nodeCertPath: String
    private let caCertPath: String

    private var task: URLSessionWebSocketTask?
    private var incomingHandler: ((String) -> Void)?
    private var backoff: TimeInterval = 1.0
    private var queue: [String] = []
    private let queueLock = NSLock()

    init(fleetURL: URL, nodeCertPath: String, caCertPath: String) {
        self.fleetURL = fleetURL
        self.nodeCertPath = nodeCertPath
        self.caCertPath = caCertPath
    }

    func start() {
        Task {
            await connectLoop()
        }
    }

    @MainActor
    private func connectLoop() async {
        while true {
            guard let session = buildSession() else {
                log("TLS unavailable, retry in \(backoff)s")
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
                continue
            }

            task = session.webSocketTask(with: fleetURL)
            task?.resume()
            log("tunnel connected")
            backoff = 1.0

            // Drain any queued messages
            await drainQueue()

            // Read loop
            do {
                while let out = try await receiveOne(), let task = task {
                    if let text = String(data: out, encoding: .utf8) {
                        incomingHandler?(text)
                    }
                }
            } catch {
                log("read error: \(error.localizedDescription)")
            }

            task = nil
            log("disconnected, retry in \(backoff)s")
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 60)
        }
    }

    private func receiveOne() async throws -> Data? {
        guard let task = task else { return nil }
        let msg = try await task.receive()
        if case .data(let d) = msg { return d }
        if case .string(let s) = msg { return Data(s.utf8) }
        return nil
    }

    @MainActor
    private func drainQueue() {
        queueLock.lock()
        let messages = queue
        queue.removeAll()
        queueLock.unlock()

        guard let task = task else {
            queueLock.lock()
            queue = messages
            queueLock.unlock()
            return
        }

        for m in messages {
            task.send(.string(m), completionHandler: nil)
        }
    }

    func send(_ text: String) {
        if let task = task {
            task.send(.string(text), completionHandler: nil)
            return
        }
        queueLock.lock()
        queue.append(text)
        queueLock.unlock()
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        incomingHandler = handler
    }

    @MainActor
    private func buildSession() -> URLSession? {
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocol = .tlsV13

        if !nodeCertPath.isEmpty {
            guard let identity = identityFromPEM(nodeCertPath) else {
                log("load identity failed")
                return nil
            }
            config.tlsIdentities = [identity]
        }

        return URLSession(configuration: config)
    }

    private func identityFromPEM(_ path: String) -> SecIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return pemToIdentity(data)
    }

    private func pemToIdentity(_ data: Data) -> SecIdentity? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)

        var certLines: [String] = []
        var inCert = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "-----BEGIN CERTIFICATE-----" {
                inCert = true
                certLines.append(t)
            } else if t == "-----END CERTIFICATE-----" {
                certLines.append(t)
                break
            } else if inCert {
                certLines.append(t)
            }
        }

        let certData = Data((certLines.joined(separator: "\n") + "\n").utf8)
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }

        var keyLines: [String] = []
        var inKey = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-----BEGIN") && (t.contains("PRIVATE KEY") || t.contains("EC PRIVATE")) {
                inKey = true
                keyLines.append(t)
            } else if t.contains("END") && t.contains("PRIVATE KEY") {
                keyLines.append(t)
                break
            } else if inKey {
                keyLines.append(t)
            }
        }

        guard !keyLines.isEmpty else { return nil }
        let keyData = Data((keyLines.joined(separator: "\n") + "\n").utf8)

        let attr: NSDictionary = [kSecAttrIsTemporary: NSNumber(booleanLiteral: true)]
        var key: SecKey?
        guard SecKeyImport(keyData as CFData, attr as CFDictionary, &key) == noErr,
              let key = key else {
            return nil
        }

        var identity: SecIdentity?
        guard SecIdentityCreate(cert, key, &identity) == noErr else {
            return nil
        }
        return identity
    }

    private func log(_ msg: String) {
        NSLog("[Tunnel] \(msg)")
    }
}

// MARK: - Duration extension

extension Duration {
    static func seconds(_ value: TimeInterval) -> Duration {
        return Duration.nanoseconds(UInt64(value * 1_000_000_000))
    }
}
