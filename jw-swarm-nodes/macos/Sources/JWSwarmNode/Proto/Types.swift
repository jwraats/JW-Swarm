import Foundation

// MARK: - Enums (match proto/schema.json)

enum ScheduleStateValue: String, Codable, CaseIterable {
    case awake
    case asleep
    case draining
}

enum GpuVendor: String, Codable, CaseIterable {
    case nvidia
    case amd
    case apple
    case intel
}

enum OsKind: String, Codable, CaseIterable {
    case macos
    case linux
    case windows
}

enum Backend: String, Codable, CaseIterable {
    case vllm
    case llama_cpp = "llama.cpp"
    case mlx
}

// MARK: - Shared types

struct GpuInfo: Codable {
    let vendor: GpuVendor
    let name: String
    let vram_mb: UInt64
}

struct OwnerLimits: Codable {
    var gpu_power_pct: UInt8
    var memory_limit_mb: UInt64
}

struct NodeMetrics: Codable {
    var vram_used_mb: UInt64
    var vram_total_mb: UInt64
    var gpu_util_pct: Double
    var tps: Double
    var latency_ms: Double
    var in_flight: UInt32
}

struct CatalogModel: Codable {
    let id: String
    let display_name: String
    let download_url: String
    let sha256: String
    let size_bytes: UInt64
    let context_length: UInt32
    let params_billions: Double
    let backend: Backend
}

struct Usage: Codable {
    let prompt_tokens: UInt32
    let completion_tokens: UInt32
    let total_tokens: UInt32
}

// MARK: - Node -> Fleet Manager payload types

struct RegisterPayload: Codable {
    let node_id: String
    let hostname: String
    let os: OsKind
    let gpu: GpuInfo
    let limits: OwnerLimits
    let selected_models: [String]
}

struct CatalogRequestPayload: Codable {}

struct HeartbeatPayload: Codable {
    let node_id: String
    let metrics: NodeMetrics
    let schedule_state: ScheduleStateValue
}

struct ModelStatusPayload: Codable {
    let node_id: String
    let ready_models: [String]
}

struct ScheduleStatePayload: Codable {
    let node_id: String
    let state: ScheduleStateValue
}

struct TokenChunkPayload: Codable {
    let request_id: String
    let delta: String
    let index: UInt32
}

struct DonePayload: Codable {
    let request_id: String
    let usage: Usage
}

struct ErrorPayload: Codable {
    let request_id: String
    let message: String
}

// MARK: - Fleet Manager -> Node payload types

struct CatalogResponsePayload: Codable {
    let models: [CatalogModel]
}

struct PromptDispatchPayload: Codable {
    let request_id: String
    let model: String
    let payload: [String: AnyCodable]
}

// MARK: - Envelope

struct TunnelEnvelope: Codable {
    let type: MessageType
    let payload: AnyCodable
}

enum MessageType: String, Codable {
    case register = "Register"
    case catalogRequest = "CatalogRequest"
    case heartbeat = "Heartbeat"
    case modelStatus = "ModelStatus"
    case scheduleState = "ScheduleState"
    case tokenChunk = "TokenChunk"
    case done = "Done"
    case error = "Error"
    case catalogResponse = "CatalogResponse"
    case promptDispatch = "PromptDispatch"
}

enum PayloadType {
    case register(RegisterPayload)
    case catalogRequest
    case heartbeat(HeartbeatPayload)
    case modelStatus(ModelStatusPayload)
    case scheduleState(ScheduleStatePayload)
    case tokenChunk(TokenChunkPayload)
    case done(DonePayload)
    case error(ErrorPayload)
    case catalogResponse(CatalogResponsePayload)
    case promptDispatch(PromptDispatchPayload)
}

extension PayloadType {
    var messageType: MessageType {
        switch self {
        case .register: return .register
        case .catalogRequest: return .catalogRequest
        case .heartbeat: return .heartbeat
        case .modelStatus: return .modelStatus
        case .scheduleState: return .scheduleState
        case .tokenChunk: return .tokenChunk
        case .done: return .done
        case .error: return .error
        case .catalogResponse: return .catalogResponse
        case .promptDispatch: return .promptDispatch
        }
    }

    var rawValue: Any {
        switch self {
        case .register(let v): return v
        case .catalogRequest: return CatalogRequestPayload()
        case .heartbeat(let v): return v
        case .modelStatus(let v): return v
        case .scheduleState(let v): return v
        case .tokenChunk(let v): return v
        case .done(let v): return v
        case .error(let v): return v
        case .catalogResponse(let v): return v
        case .promptDispatch(let v): return v
        }
    }

    func toJSON() throws -> String {
        let env = TunnelEnvelope(type: messageType, payload: AnyCodable(rawValue))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(env)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func fromJSON(_ string: String) throws -> PayloadType {
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "PayloadType", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env = try decoder.decode(TunnelEnvelope.self, from: data)

        switch env.type {
        case .register:
            return .register(try decodeFromAny(env.payload, RegisterPayload.self))
        case .catalogRequest:
            return .catalogRequest
        case .heartbeat:
            return .heartbeat(try decodeFromAny(env.payload, HeartbeatPayload.self))
        case .modelStatus:
            return .modelStatus(try decodeFromAny(env.payload, ModelStatusPayload.self))
        case .scheduleState:
            return .scheduleState(try decodeFromAny(env.payload, ScheduleStatePayload.self))
        case .tokenChunk:
            return .tokenChunk(try decodeFromAny(env.payload, TokenChunkPayload.self))
        case .done:
            return .done(try decodeFromAny(env.payload, DonePayload.self))
        case .error:
            return .error(try decodeFromAny(env.payload, ErrorPayload.self))
        case .catalogResponse:
            return .catalogResponse(try decodeFromAny(env.payload, CatalogResponsePayload.self))
        case .promptDispatch:
            return .promptDispatch(try decodeFromAny(env.payload, PromptDispatchPayload.self))
        }
    }
}

// Decode AnyCodable.value back to a Codable struct (re-encode then decode)
func decodeFromAny<T: Codable>(_ any: AnyCodable, _ type: T.Type) throws -> T {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(any)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: data)
}

// MARK: - AnyCodable (for PromptDispatch.payload)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) {
            value = v.map { $0.value }
        }
        else if let v = try? container.decode([String: AnyCodable].self) {
            var dict: [String: Any] = [:]
            for (k, val) in v { dict[k] = val.value }
            value = dict
        }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Int64 { try container.encode(Double(truncating: v)) }
        else if let v = value as? UInt64 { try container.encode(Double(truncating: v)) }
        else if let v = value as? UInt8 { try container.encode(Int(exactly: v) ?? 0) }
        else if let v = value as? UInt32 { try container.encode(Int(exactly: v) ?? 0) }
        else if let v = value as? Int32 { try container.encode(Int(exactly: v) ?? 0) }
        else if let v = value as? Float { try container.encode(Double(v)) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? String { try container.encode(v) }
        else if let v = value as? [Any] { try container.encode(v.map { AnyCodable($0) }) }
        else if let v = value as? [String: Any] { try container.encode(v.mapValues { AnyCodable($0) }) }
        else { try container.encodeNil() }
    }
}
