import Foundation

@unchecked Sendable
final class Tunnel {
    private let fleetURL: URL
    var socket: URLSessionWebSocketTask? = nil
    var onMessage: ((String) -> Void)?
    var backoff: Double = 1
    var queue: [String] = []

    init(fleetURL: URL) { self.fleetURL = fleetURL }

    func start() {
        Task { @MainActor in loop() }
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

    @MainActor
    private func drainPending() {
        let pending = queue; queue.removeAll()
        guard let t = socket else { queue = pending; return }
        for msg in pending { Task { @MainActor in try? await t.send(.string(msg)) } }
    }

    @MainActor
    func send(_ text: String) {
        if let t = socket { Task { @MainActor in try? await t.send(.string(text)) }; return }
        queue.append(text)
    }

    @MainActor
    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        onMessage = handler
    }

    private func log(_ msg: String) { NSLog("[Tunnel] \(msg)") }
}