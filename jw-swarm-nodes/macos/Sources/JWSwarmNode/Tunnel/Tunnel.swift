import Foundation

final class Tunnel {
    private let fleetURL: URL
    private var socket: URLSessionWebSocketTask?
    private var onMessage: ((String) -> Void)?
    private var backoff: TimeInterval = 1
    private var queue: [String] = []
    private let lock = NSLock()

    init(fleetURL: URL) {
        self.fleetURL = fleetURL
    }

    func start() {
        Task { @MainActor in await run() }
    }

    @MainActor
    private func run() async {
        while !Task.isCancelled {
            let t = URLSession.shared.webSocketTask(with: fleetURL)
            t.resume()
            socket = t
            log("connected")
            backoff = 1
            await drain()
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
            log("disconnected; retry in \(backoff)")
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 60)
        }
    }

    nonisolated func sendSync(_ text: String) {
        guard let t = socket else {
            lock.lock()
            queue.append(text)
            lock.unlock()
            return
        }
        Task { try? await t.send(.string(text)) }
    }

    @MainActor
    private func drain() async {
        var m: [String] = []
        lock.lock()
        m = queue; queue.removeAll()
        lock.unlock()
        guard let t = socket else {
            lock.lock(); queue = m; lock.unlock(); return
        }
        for s in m { try? await t.send(.string(s)) }
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        onMessage = handler
    }

    private func log(_ m: String) { NSLog("[Tunnel] \(m)") }
}
