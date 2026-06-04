import Foundation
import CommonCrypto

final class ModelDownloader {
    static let shared = ModelDownloader()
    private let session = URLSession.shared

    func downloadModel(_ m: CatalogModel, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let dir = ConfigManager.shared.modelDir().appendingPathComponent(m.id)
        let shaPath = dir.appendingPathComponent("sha256")
        if FileManager.default.fileExists(atPath: shaPath.path) {
            if let existing = try? String(contentsOf: shaPath),
               existing.trimmingCharacters(in: .whitespacesAndNewlines) == m.sha256 {
                progress(1.0)
                log("\(m.id) already verified"); return
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let remoteName = URL(string: m.download_url)?.lastPathComponent ?? "weights.bin"
        let filename = remoteName.isEmpty ? "weights.bin" : remoteName
        let dest = dir.appendingPathComponent(filename)
        log("downloading \(m.id) (\(m.size_bytes) bytes)")
        guard let url = URL(string: m.download_url) else { throw DLE.invalidURL }
        let progressDelegate = DownloadProgressDelegate(onProgress: progress)
        let (tu, resp) = try await session.download(from: url, delegate: progressDelegate)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tu)
            throw DLE.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let hash = try sha256(at: tu)
        guard hash.lowercased() == m.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: tu)
            throw DLE.mismatch(expected: m.sha256, actual: hash)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tu, to: dest)
        if filename != "weights.bin" {
            let legacy = dir.appendingPathComponent("weights.bin")
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: dest)
        }
        try m.sha256.write(to: shaPath, atomically: true, encoding: .utf8)
        progress(1.0)
        log("\(m.id) verified")
    }

    private func sha256(at url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        var h = SHA256Hasher()
        while true {
            let chunk = try fh.read(upToCount: 8192)
            guard let d = chunk, !d.isEmpty else { break }
            h.update(data: d)
        }
        return h.finalize()
    }

    private func log(_ m: String) { NSLog("[Models] \(m)") }
}

/// Per-task delegate that reports download progress by observing the task's
/// `Progress` object. Used with `URLSession.download(from:delegate:)` so the
/// async API still returns the downloaded file URL.
final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}


struct SHA256Hasher {
    private var ctx = CC_SHA256_CTX()
    private var ok = false
    init() { CC_SHA256_Init(&ctx); ok = true }
    mutating func update(data: Data) {
        guard ok else { return }
        _ = data.withUnsafeBytes { CC_SHA256_Update(&ctx, $0.baseAddress, UInt32(data.count)) }
    }
    mutating func finalize() -> String {
        var h = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&h, &ctx); ok = false
        return h.map { String(format: "%02x", $0) }.joined()
    }
}

enum DLE: Error, LocalizedError {
    case invalidURL, http(Int), mismatch(expected: String, actual: String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .http(let c): return "HTTP \(c)"
        case .mismatch(let e, let a): return "sha256 mismatch \(e) != \(a)"
        }
    }
}
