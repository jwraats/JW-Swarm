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
            nonisolated(unsafe) self.socket = t
            nonisolated(unsafe) self.backoff = 1
            drainMessages()
            while let r = try? await socket?.receive() {
                switch r {
                case .string(let s): onMessage?(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { onMessage?(s) }
                default: break
                }
            }
            nonisolated(unsafe) self.socket?.cancel()
            nonisolated(unsafe) self.socket = nil
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            nonisolated(unsafe) self.backoff = min(backoff * 2, 60)
        }
    }

    @MainActor
    private func drainMessages() {
        nonisolated(unsafe) let pending = queue
        nonisolated(unsafe) self.queue = []
        guard let sock = socket else {
            nonisolated(unsafe) self.queue = pending; return
        }
        for msg in pending {
            Task { try? await sock.send(.string(msg)) }
        }
    }

    nonisolated func send(_ text: String) {
        nonisolated(unsafe) let selfRef = self
        Task { @MainActor in
            nonisolated(unsafe) let s = selfRef
            if let sock = s.socket {
                try? await sock.send(.string(text))
                return
            }
            nonisolated(unsafe) s.queue.append(text)
        }
    }

    nonisolated func setIncomingHandler(_ handler: @escaping (String) -> Void) {
        Task { @MainActor in
            nonisolated(unsafe) self.onMessage = handler
        }
    }
}