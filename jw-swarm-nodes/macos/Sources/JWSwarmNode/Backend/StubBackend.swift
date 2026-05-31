import Foundation

class StubBackend {
    private var models: [String] = []
    private let lock = NSLock()

    func register(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        models.append(id)
    }

    func ready() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }

    func dispatch(_ pd: PromptDispatchPayload, sender: @escaping (String) -> Void) {
        let stub = ["Hello", ",", " ", "simulated", " ", "response", ".", " ", "!"]

        // Estimate prompt tokens from payload messages
        var pt: UInt32 = 50
        if let messages = pd.payload["messages"]?.value as? [AnyCodable] {
            for msg in messages {
                if let dict = msg.value as? [String: AnyCodable],
                   let content = dict["content"]?.value as? String {
                    pt = UInt32(max(content.count / 4, 1))
                }
            }
        }

        // Send token chunks
        for (i, token) in stub.enumerated() {
            let chunk = PayloadType.tokenChunk(TokenChunkPayload(
                request_id: pd.request_id,
                delta: token,
                index: UInt32(i)
            ))
            if let json = try? chunk.toJSON() {
                sender(json)
            }
        }

        // Send done
        let doneMsg = PayloadType.done(DonePayload(
            request_id: pd.request_id,
            usage: Usage(
                prompt_tokens: pt,
                completion_tokens: UInt32(stub.count),
                total_tokens: UInt32(Int(pt) + stub.count)
            )
        ))
        if let json = try? doneMsg.toJSON() {
            sender(json)
        }

        NSLog("[Backend] stub done for \(pd.request_id)")
    }
}
