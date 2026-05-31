import Foundation
import CommonCrypto

class ModelDownloader {
    static let shared = ModelDownloader()
    private let session = URLSession(configuration: .default)

    func download(_ model: CatalogModel) async throws {
        let dir = ConfigManager.shared.modelDir().appendingPathComponent(model.id)
        let shaPath = dir.appendingPathComponent("sha256")

        // Already verified?
        if FileManager.default.fileExists(atPath: shaPath.path) {
            if let existing = try? String(contentsOf: shaPath),
               existing.trimmingCharacters(in: .whitespacesAndNewlines) == model.sha256 {
                log("\(model.id) already verified")
                return
            }
        }

        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )

        let dest = dir.appendingPathComponent("weights.bin")
        log("downloading \(model.id) (\(model.size_bytes) bytes)")

        guard let url = URL(string: model.download_url) else {
            throw DownloadError.invalidURL
        }

        let (tempURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let hash = try sha256File(at: tempURL)
        guard hash.lowercased() == model.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.mismatch(expected: model.sha256, actual: hash)
        }

        try FileManager.default.moveItem(from: tempURL, to: dest)
        try model.sha256.write(to: shaPath, atomically: true, encoding: .utf8)
        log("\(model.id) verified")
    }

    private func sha256File(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        var hasher = SHA256Hasher()
        while true {
            let chunk = try file.read(upToCount: 8192)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private func log(_ msg: String) {
        NSLog("[Models] \(msg)")
    }
}

class SHA256Hasher {
    private var ctx = CC_SHA256_CTX()
    private var ready = false

    init() {
        CC_SHA256_Init(&ctx)
        ready = true
    }

    func update(data: Data) {
        guard ready else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            CC_SHA256_Update(&ctx, base, UInt32(data.count))
        }
    }

    func finalize() -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&hash, &ctx)
        ready = false
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum DownloadError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpStatus(let code): return "HTTP \(code)"
        case .mismatch(let exp, let act): return "sha256 mismatch: \(exp) != \(act)"
        }
    }
}
