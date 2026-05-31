import Foundation
import Security

final class Tunnel {
    private let fleetURL: URL
    private let certPath: String
    private let caPath: String
    private var socket: URLSessionWebSocketTask?
    private var onMessage: ((String) -> Void)?
    private var backoff: TimeInterval = 1
    private var queue: [String] = []
    private let lock = NSLock()

    init(fleetURL: URL, certPath: String, caPath: String) {
        self.fleetURL = fleetURL; self.certPath = certPath; self.caPath = caPath
    }

    func start() { Task { @MainActor in await loop() } }

    @MainActor
    private func loop() async {
        while !Task.isCancelled {
            guard let sess = makeSession() else {
                log("TLS unavailable; retry in \(backoff)"); try? await sleep(backoff); backoff = min(backoff*2, 60); continue
            }
            let t = sess.webSocketTask(with: fleetURL); t.resume(); socket = t
            log("connected"); backoff = 1; drain()
            while let r = try? await socket?.receive() { switch r {
                    case .string(let s): onMessage?(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { onMessage?(s) }
                    case .close: break
                    @unknown default: break
                }
            }
            socket?.cancel(); socket = nil
            log("disconnected; retry in \(backoff)"); try? await sleep(backoff); backoff = min(backoff*2, 60)
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private func makeSession() -> URLSession? {
        let c = URLSessionConfiguration.default
        if !certPath.isEmpty, let ident = identityAt(certPath) {
            if #available(macOS 15.0, *) {
                c.tlsIdentities = [ident]
            } else {
                var sslDict: NSDictionary = [:]
                sslDict[kCFStreamSSLCertArray as String] = [ident] as CFArray
                c.connectionProxyDictionary = sslDict
            }
        }
        if !caPath.isEmpty { c.connectionProxyDictionary = caDict() }
        return URLSession(configuration: c)
    }

    private func caDict() -> NSDictionary {
        var d: NSDictionary = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: caPath)),
           let cert = SecCertificateCreateWithData(nil, data as CFData) {
            d = [kCFStreamSSLCertArray as String: [cert] as CFArray]
        }
        return d
    }

    @MainActor
    func send(_ text: String) {
        if let t = socket { try? t.send(.string(text)); return }
        lock.lock(); queue.append(text); lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock(); let m = queue; queue.removeAll(); lock.unlock()
        guard let t = socket else { lock.lock(); queue = m; lock.unlock(); return }
        for s in m { try? t.send(.string(s)) }
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) { onMessage = handler }

    // ---------- PEM -> SecIdentity ----------

    private func identityAt(_ path: String) -> SecIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        guard let certData = pemBlock(lines, tag: "CERTIFICATE"),
              let keyData  = pemBlock(lines, tag: "PRIVATE") else { return nil }
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else { return nil }
        guard let key  = SecKeyCreateWithData(keyData as CFData,
                    [kSecAttrIsPermanent: false as CFBoolean] as CFDictionary,
                    nil) else { return nil }
        var ident: SecIdentity?
        guard SecIdentityCreate(cert, key, &ident) == noErr else { return nil }
        return ident
    }

    private func pemBlock(_ lines: [String], tag: String) -> Data? {
        var r: [String] = []; var on = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !on && t == "-----BEGIN \(tag)-----" { on = true; r.append(t) }
            else if on && t.hasPrefix("-----END") && t.contains(tag) { r.append(t); break }
            else if on { r.append(t) }
        }
        return !r.isEmpty ? Data((r.joined(separator: "\n") + "\n").utf8) : nil
    }

    private func log(_ m: String) { NSLog("[Tunnel] \(m)") }
}
