import Foundation

struct AppConfig: Codable {
    var fleet_url: String
    var node_id: String
    var hostname: String
    var node_cert: String
    var ca_cert: String
    var limits: Limits
    var schedule: Schedule
    var selected_models: [String]
}

struct Limits: Codable {
    var gpu_power_pct: UInt8
    var memory_limit_mb: UInt64
}

struct Schedule: Codable {
    var awake_from: String
    var awake_until: String
}

class ConfigManager {
    static let shared = ConfigManager()
    private(set) var config: AppConfig

    private let configDir: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() {
        self.configDir = Self.configPath(fileManager: fileManager)
        // Bootstrap with a temporary value; load() immediately replaces it.
        self.config = AppConfig(
            fleet_url: "",
            node_id: "",
            hostname: "",
            node_cert: "",
            ca_cert: "",
            limits: Limits(gpu_power_pct: 0, memory_limit_mb: 0),
            schedule: Schedule(awake_from: "", awake_until: ""),
            selected_models: []
        )
        self.config = self.load()
    }

    private static func configPath(fileManager: FileManager) -> URL {
        if let env = ProcessInfo.processInfo.environment["JW_CONFIG_DIR"] {
            return URL(fileURLWithPath: env).appendingPathComponent("jw-swarm-node")
        }
        guard let dir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("jw-swarm-node")
        }
        return dir.appendingPathComponent("JWSwarmNode")
    }

    @discardableResult
    private func load() -> AppConfig {
        let path = configDir.appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: path.path) {
            if let data = try? Data(contentsOf: path),
               let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return applyEnvOverrides(loaded)
            }
        }
        return applyEnvOverrides(generate())
    }

    private func applyEnvOverrides(_ c: AppConfig) -> AppConfig {
        var result = c
        if let url = ProcessInfo.processInfo.environment["JW_FLEET_URL"], !url.isEmpty {
            result.fleet_url = url
        }
        if let cert = ProcessInfo.processInfo.environment["JW_NODE_CERT"], !cert.isEmpty {
            result.node_cert = cert
        }
        if let ca = ProcessInfo.processInfo.environment["JW_CA_CERT"], !ca.isEmpty {
            result.ca_cert = ca
        }
        return result
    }

    @discardableResult
    private func generate() -> AppConfig {
        let nid = UUID().uuidString
        let hn = ProcessInfo.processInfo.hostName.isEmpty
            ? "jw-macos-node"
            : ProcessInfo.processInfo.hostName
        let c = AppConfig(
            fleet_url: "wss://localhost/node/connect",
            node_id: nid,
            hostname: hn,
            node_cert: "/opt/jw-swarm-node/node.pem",
            ca_cert: "/opt/jw-swarm-node/ca.crt",
            limits: Limits(gpu_power_pct: 100, memory_limit_mb: 24000),
            schedule: Schedule(awake_from: "", awake_until: ""),
            selected_models: []
        )
        save(c)
        return c
    }

    func save(_ c: AppConfig) {
        try? fileManager.createDirectory(
            at: configDir, withIntermediateDirectories: true, attributes: nil
        )
        let path = configDir.appendingPathComponent("config.json")
        if let data = try? encoder.encode(c) {
            try? data.write(to: path, options: .atomic)
        }
    }

    func setAndSave(_ c: AppConfig) {
        self.config = c
        save(c)
    }

    func modelDir() -> URL {
        dataDir().appendingPathComponent("models")
    }

    func dataDir() -> URL {
        configDir
    }
}
