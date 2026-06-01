import Foundation

class Tunnel: @unchecked Sendable {
    private let fleetURL: URL
    private var socket: URLSessionWebSocketTask?
    private var onMessage: ((String) -> Void)?
    private var backoff: Double = 1
    private var queue: [String] = []
    private let stateQueue = DispatchQueue(label: "com.jw.swarm.tunnel.state")

    init(_ url: URL) { self.fleetURL = url }

    func startLoop() {
        Task.detached { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let t = URLSession.shared.webSocketTask(with: fleetURL)
            t.resume()
            stateQueue.sync {
                socket = t
                backoff = 1
            }

            await drainMessages(using: t)

            while let r = try? await t.receive() {
                switch r {
                case .string(let s):
                    let handler = stateQueue.sync { onMessage }
                    handler?(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        let handler = stateQueue.sync { onMessage }
                        handler?(s)
                    }
                default: break
                }
            }

            t.cancel()

            let delay = stateQueue.sync { () -> Double in
                socket = nil
                let current = backoff
                backoff = min(backoff * 2, 60)
                return current
            }
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
                try? await sock.send(.string(text))
                return
            }
            self.stateQueue.sync {
                self.queue.append(text)
            }
        }
    }

    func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        stateQueue.sync {
            onMessage = handler
        }
    }
}