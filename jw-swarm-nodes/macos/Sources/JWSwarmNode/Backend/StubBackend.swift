import Foundation

final class StubBackend {
    private var models: [String] = []
    private let lock = NSLock()

    func register(_ id: String) { lock.lock(); defer { lock.unlock() }; models.append(id) }
    func ready() -> [String] { lock.lock(); defer { lock.unlock() }; return models }

    func dispatch(_ pd: PromptDispatchPayload, sender: @escaping (String) -> Void) {
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
                       usage: Usage(prompt_tokens: pt, completion_tokens: UInt32(stub.count),
                                    total_tokens: UInt32(Int(pt) + stub.count)))
        ).toJSON() else { return }
        sender(j)
        NSLog("[Backend] stub done for \(pd.request_id)")
    }
}
