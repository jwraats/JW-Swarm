import Foundation

@unchecked Sendable
final class StubBackend {
    nonisolated(unsafe) private var _models: [String] = []

    nonisolated func register(_ id: String) { _models.append(id) }
    nonisolated func ready() -> [String] { _models }

    nonisolated func dispatch(_ pd: PromptDispatchPayload, sender: @escaping (String) -> Void) {
        let stub = ["Hello", ",", " ", "simulated", " ", "response", ".", " ", "!"]
        var pt: UInt32 = 50
        if let rawMsgs = pd.payload["messages"]?.value as? [Any] {
            for msgAny in rawMsgs {
                if let d = msgAny as? [String: Any],
                   let c = d["content"] as? String {
                    pt = UInt32(max(c.count / 4, 1))
                }
            }
        }
        for (i, tok) in stub.enumerated() {
            guard let j = try? PayloadType.tokenChunk(
                TokenChunkPayload(request_id: pd.request_id, delta: tok, index: UInt32(i))
            ).toJSON() else { continue }
            sender(j)
        }
        guard let j = try? PayloadType.done(
            DonePayload(request_id: pd.request_id,
                       usage: Usage(prompt_tokens: pt,
                                    completion_tokens: UInt32(stub.count),
                                    total_tokens: UInt32(Int(pt) + stub.count)))
        ).toJSON() else { return }
        sender(j)
        NSLog("[Backend] stub done for \(pd.request_id)")
    }
}

@unchecked Sendable
final class Tunnel {
    nonisolated(unsafe) private let fleetURL: URL
    nonisolated(unsafe) private var socket: URLSessionWebSocketTask?
    nonisolated(unsafe) private var onMessage: ((String) -> Void)?
    nonisolated(unsafe) private var backoff: Double = 1
    nonisolated(unsafe) private var queue: [String] = []

    init(_ url: URL) { self.fleetURL = url }

    nonisolated func startLoop() {
        Task { @MainActor in
            await run()
        }
    }

    @MainActor
    private func run() async {
        nonisolated(unsafe) let _url = fleetURL
        while !Task.isCancelled {
            let t = URLSession.shared.webSocketTask(with: _url)
            t.resume()
            socket = t
            backoff = 1
            drainMessages()
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
    private func drainMessages() {
        let pending = queue; queue.removeAll()
        guard let sock = socket else { queue = pending; return }
        for msg in pending {
            Task { try? await sock.send(.string(msg)) }
        }
    }

    nonisolated func send(_ text: String) {
        nonisolated(unsafe) let selfRef = self
        Task { @MainActor in
            if let sock = selfRef.socket {
                try? await sock.send(.string(text))
                return
            }
            selfRef.queue.append(text)
        }
    }

    nonisolated func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        Task { @MainActor in self.onMessage = handler }
    }
}