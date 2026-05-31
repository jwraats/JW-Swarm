import Foundation

@unchecked Sendable
final class Tunnel {
    nonisolated private var url: URL { fleetURL }
    private let fleetURL: URL
    nonisolated(unsafe) private var socket: URLSessionWebSocketTask?
    nonisolated(unsafe) private var onMessage: ((String) -> Void)?
    nonisolated(unsafe) private var backoff: Double = 1
    nonisolated(unsafe) private var queue: [String] = []

    init(_ url: URL) { self.fleetURL = url }

    nonisolated func start() {
        Task { @MainActor in
            loop()
        }
    }

    @MainActor
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
                case .data(let d): if let s = String(data: d, encoding: .utf8) { onMessage?(s) }
                default: break
                }
            }
            socket?.cancel(); socket = nil
            log("disconnected; retry in \(backoff)s")
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 60)
        }
    }

    @MainActor
    private func drainPending() {
        let p = queue; queue.removeAll()
        guard let t = socket else { queue = p; return }
        for m in p { Task { try? await t.send(.string(m)) } }
    }

    nonisolated     nonisolated func send(_ text: String) {
        nonisolated(unsafe) let s = socket
        if let t = s {
            Task { @MainActor in self._send(text) }; return
        }
        nonisolated(unsafe) queue.append(text)
    }

    @MainActor
    private func _send(_ text: String) {
        if let t = socket {
            try? t.send(.string(text)); return
        }
        queue.append(text)
    }

    nonisolated func setIncomingHandler(_ h: @escaping (String) -> Void) {
        nonisolated(unsafe) onMessage = h
    }

    nonisolated private func log(_ msg: String) { NSLog("[Tunnel] \(msg)") }
}