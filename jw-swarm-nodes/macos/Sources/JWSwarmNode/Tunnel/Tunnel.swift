import Foundation

class Tunnel: @unchecked Sendable {
    private let fleetURL: URL
    private var socket: URLSessionWebSocketTask?
    private var onMessage: ((String) -> Void)?
    private var backoff: Double = 1
    private var queue: [String] = []

    init(_ url: URL) { self.fleetURL = url }

    func startLoop() {
        Task { @MainActor in await run() }
    }

    @MainActor
    private func run() async {
        while !Task.isCancelled {
            let t = URLSession.shared.webSocketTask(with: fleetURL)
            t.resume()
            socket = t
            backoff = 1
            await drainMessages()
            while let r = try? await socket?.receive() {
                switch r {
                case .string(let s): onMessage?(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { onMessage?(s) }
                default: break
                }
            }
            socket?.cancel()
            socket = nil
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 60)
        }
    }

    @MainActor
    private func drainMessages() async {
        let pending = queue
        queue = []
        guard let sock = socket else { queue = pending; return }
        for msg in pending {
            try? await sock.send(.string(msg))
        }
    }

    func send(_ text: String) {
        let ref = self
        Task { @MainActor in
            if let sock = ref.socket {
                try? await sock.send(.string(text))
                return
            }
            ref.queue.append(text)
        }
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        Task { @MainActor in self.onMessage = handler }
    }
}