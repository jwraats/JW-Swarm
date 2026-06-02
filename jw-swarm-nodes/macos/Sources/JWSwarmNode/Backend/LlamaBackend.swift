import Foundation
import LlamaSwift

final class LlamaBackend: @unchecked Sendable {
    private struct LoadedModel {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
    }

    private enum BackendError: Error, LocalizedError {
        case modelFileMissing(String)
        case modelTooLarge(model: String, sizeMB: UInt64, limitMB: UInt64)
        case loadFailed(String)
        case contextInitFailed(String)
        case tokenizeFailed
        case decodeFailed
        case logitsMissing

        var errorDescription: String? {
            switch self {
            case .modelFileMissing(let id):
                return "Model file missing for \(id)"
            case .modelTooLarge(let model, let sizeMB, let limitMB):
                return "Model \(model) is \(sizeMB)MB, over configured memory limit \(limitMB)MB"
            case .loadFailed(let id):
                return "Failed to load model \(id)"
            case .contextInitFailed(let id):
                return "Failed to create context for model \(id)"
            case .tokenizeFailed:
                return "Failed to tokenize input"
            case .decodeFailed:
                return "Decoding failed"
            case .logitsMissing:
                return "Failed to read logits"
            }
        }
    }

    private var readyModels: Set<String> = []
    private var loaded: [String: LoadedModel] = [:]
    private var memoryLimitMB: UInt64
    private let queue = DispatchQueue(label: "jwswarm.macos.llama.backend")

    init(memoryLimitMB: UInt64) {
        self.memoryLimitMB = memoryLimitMB
        llama_backend_init()
    }

    deinit {
        queue.sync {
            for item in loaded.values {
                llama_free(item.context)
                llama_model_free(item.model)
            }
            loaded.removeAll()
        }
        llama_backend_free()
    }

    func updateMemoryLimitMB(_ value: UInt64) {
        queue.sync {
            memoryLimitMB = value
            unloadOversizedModelsIfNeeded()
        }
    }

    func register(_ id: String) {
        queue.sync {
            guard (try? checkModelFitsLimit(id)) != nil else {
                readyModels.remove(id)
                return
            }
            readyModels.insert(id)
        }
    }

    func ready() -> [String] {
        queue.sync { readyModels.sorted() }
    }

    func dispatch(_ pd: PromptDispatchPayload, sender: @escaping (String) -> Void) {
        queue.async {
            do {
                guard self.readyModels.contains(pd.model) else {
                    throw BackendError.modelFileMissing(pd.model)
                }

                let prompt = self.extractPrompt(payload: pd.payload)
                let maxTokens = self.extractMaxTokens(payload: pd.payload)
                let result = try self.generate(modelID: pd.model, prompt: prompt, maxTokens: maxTokens)

                for (i, tok) in result.chunks.enumerated() {
                    guard let chunk = try? PayloadType.tokenChunk(
                        TokenChunkPayload(request_id: pd.request_id, delta: tok, index: UInt32(i))
                    ).toJSON() else { continue }
                    sender(chunk)
                }

                guard let done = try? PayloadType.done(
                    DonePayload(request_id: pd.request_id, usage: result.usage)
                ).toJSON() else { return }
                sender(done)
            } catch {
                let msg = error.localizedDescription
                if let json = try? PayloadType.error(
                    ErrorPayload(request_id: pd.request_id, message: msg)
                ).toJSON() {
                    sender(json)
                }
                NSLog("[Backend] dispatch error for \(pd.request_id): \(msg)")
            }
        }
    }

    private func unloadOversizedModelsIfNeeded() {
        let ids = Array(loaded.keys)
        for id in ids {
            guard let file = modelFile(for: id),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let bytes = attrs[.size] as? UInt64 else { continue }
            let sizeMB = bytes / (1024 * 1024)
            if sizeMB > memoryLimitMB, let loadedItem = loaded.removeValue(forKey: id) {
                llama_free(loadedItem.context)
                llama_model_free(loadedItem.model)
                readyModels.remove(id)
                NSLog("[Backend] unloaded \(id) due to memory limit \(memoryLimitMB)MB")
            }
        }
    }

    private func checkModelFitsLimit(_ id: String) throws {
        guard let file = modelFile(for: id) else {
            throw BackendError.modelFileMissing(id)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let bytes = (attrs[.size] as? UInt64) ?? 0
        let sizeMB = max(1, bytes / (1024 * 1024))
        if sizeMB > memoryLimitMB {
            throw BackendError.modelTooLarge(model: id, sizeMB: sizeMB, limitMB: memoryLimitMB)
        }
    }

    private func modelFile(for id: String) -> URL? {
        let dir = ConfigManager.shared.modelDir().appendingPathComponent(id)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let gguf = entries.first(where: { $0.pathExtension.lowercased() == "gguf" }) {
            return gguf
        }
        let bin = dir.appendingPathComponent("weights.bin")
        if fm.fileExists(atPath: bin.path) {
            return bin
        }
        return entries.first(where: { $0.lastPathComponent != "sha256" })
    }

    private func ensureLoaded(modelID: String) throws -> LoadedModel {
        if let existing = loaded[modelID] {
            return existing
        }

        try checkModelFitsLimit(modelID)

        guard let file = modelFile(for: modelID) else {
            throw BackendError.modelFileMissing(modelID)
        }

        let model = try file.path.withCString { pathPtr -> OpaquePointer in
            let modelParams = llama_model_default_params()
            guard let ptr = llama_model_load_from_file(pathPtr, modelParams) else {
                throw BackendError.loadFailed(modelID)
            }
            return ptr
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 4096
        contextParams.n_batch = 512

        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw BackendError.contextInitFailed(modelID)
        }

        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw BackendError.contextInitFailed(modelID)
        }
        let item = LoadedModel(model: model, context: context, vocab: vocab)
        loaded[modelID] = item
        return item
    }

    private func generate(modelID: String, prompt: String, maxTokens: Int) throws -> (chunks: [String], usage: Usage) {
        let item = try ensureLoaded(modelID: modelID)

        let utf8Count = prompt.utf8.count
        var tokens = [llama_token](repeating: 0, count: max(utf8Count + 8, 256))
        let tokenCount = prompt.withCString { cstr in
            llama_tokenize(
                item.vocab,
                cstr,
                Int32(utf8Count),
                &tokens,
                Int32(tokens.count),
                true,
                true
            )
        }

        guard tokenCount > 0 else {
            throw BackendError.tokenizeFailed
        }

        let promptTokens = Array(tokens.prefix(Int(tokenCount)))

        var batch = llama_batch_init(Int32(max(promptTokens.count + 1, 512)), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)
        for i in 0..<promptTokens.count {
            batch.token[i] = promptTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIDs = batch.seq_id, let seqID = seqIDs[i] {
                seqID[0] = 0
            }
            batch.logits[i] = 0
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        guard llama_decode(item.context, batch) == 0 else {
            throw BackendError.decodeFailed
        }

        var generated: [String] = []
        var nCur = batch.n_tokens

        for _ in 0..<maxTokens {
            guard let logits = llama_get_logits_ith(item.context, batch.n_tokens - 1) else {
                throw BackendError.logitsMissing
            }

            let vocabSize = Int(llama_vocab_n_tokens(item.vocab))
            var maxLogit = logits[0]
            var nextToken: llama_token = 0
            for i in 1..<vocabSize {
                if logits[i] > maxLogit {
                    maxLogit = logits[i]
                    nextToken = llama_token(i)
                }
            }

            if nextToken == llama_vocab_eos(item.vocab) {
                break
            }

            if let piece = tokenPiece(vocab: item.vocab, token: nextToken), !piece.isEmpty {
                generated.append(piece)
            }

            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            if let seqIDs = batch.seq_id, let seqID = seqIDs[0] {
                seqID[0] = 0
            }
            batch.logits[0] = 1
            nCur += 1

            guard llama_decode(item.context, batch) == 0 else {
                throw BackendError.decodeFailed
            }
        }

        let usage = Usage(
            prompt_tokens: UInt32(tokenCount),
            completion_tokens: UInt32(generated.count),
            total_tokens: UInt32(Int(tokenCount) + generated.count)
        )
        return (generated, usage)
    }

    private func tokenPiece(vocab: OpaquePointer, token: llama_token) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        guard n > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private func extractPrompt(payload: [String: AnyCodable]) -> String {
        if let rawMessages = payload["messages"]?.value as? [Any] {
            for msgAny in rawMessages.reversed() {
                if let dict = msgAny as? [String: Any],
                   let content = dict["content"] as? String,
                   !content.isEmpty {
                    return content
                }
            }
        }
        if let prompt = payload["prompt"]?.value as? String, !prompt.isEmpty {
            return prompt
        }
        return ""
    }

    private func extractMaxTokens(payload: [String: AnyCodable]) -> Int {
        if let value = payload["max_tokens"]?.value as? Int {
            return max(1, min(512, value))
        }
        if let value = payload["max_tokens"]?.value as? Double {
            return max(1, min(512, Int(value)))
        }
        return 128
    }
}
