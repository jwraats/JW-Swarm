import Foundation

@MainActor
final class Tunnel {
    private let fleetURL: URL
    private var socket: URLSessionWebSocketTask? = nil
    private var onMessage: ((String) -> Void)?
    private var backoff: Double = 1
    private var queue: [String] = []

    init(fleetURL: URL) { self.fleetURL = fleetURL }

    func start() {
        Task { await loop() }
    }

    private func loop() async {
        while !Task.isCancelled {
            let t = URLSession.shared.webSocketTask(with: fleetURL)
            t.resume()
            socket = t
            log("connected"); backoff = 1
            drainPending()
            while let r = try? await socket?.receive() {
                switch r {
                case .string(let s): onMessage?(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { onMessage?(s) }
                default: break
                }
            }
            socket?.cancel(); socket = nil
            log("disconnected; retry in \(backoff)s")
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 60)
        }
    }

    private func drainPending() {
        let pending = queue; queue.removeAll()
        guard let t = socket else { queue = pending; return }
        for msg in pending {
            Task { try? await t.send(.string(msg)) }
        }
    }

    func send(_ text: String) {
        if let t = socket {
            Task { try? await t.send(.string(text)) }; return
        }
        queue.append(text)
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        onMessage = handler
    }

    private func log(_ msg: String) { NSLog("[Tunnel] \(msg)") }
}