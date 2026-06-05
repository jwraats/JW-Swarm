import Foundation
import CommonCrypto

final class ModelDownloader {
    static let shared = ModelDownloader()
    private let session = URLSession.shared
    private let streamChunkSize = 64 * 1024
    private let diskHeadroomBytes: UInt64 = 64 * 1024 * 1024

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
        let partial = dir.appendingPathComponent("\(filename).partial")
        try? FileManager.default.removeItem(at: partial)

        try ensureSufficientDiskSpace(for: m.size_bytes, at: dir)

        log("downloading \(m.id) (\(m.size_bytes) bytes)")
        guard let url = URL(string: m.download_url) else { throw DLE.invalidURL }
        let (bytes, resp) = try await session.bytes(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DLE.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }

        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: partial)
        defer {
            try? fileHandle.close()
        }

        var hasher = SHA256Hasher()
        var writtenBytes: UInt64 = 0
        var buffer = Data()
        buffer.reserveCapacity(streamChunkSize)

        do {
            var iterator = bytes.makeAsyncIterator()
            while let byte = try await iterator.next() {
                buffer.append(byte)
                if buffer.count >= streamChunkSize {
                    try writeChunk(buffer, to: fileHandle, hasher: &hasher, writtenBytes: &writtenBytes)
                    progressFraction(writtenBytes, totalBytes: m.size_bytes, progress: progress)
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            if !buffer.isEmpty {
                try writeChunk(buffer, to: fileHandle, hasher: &hasher, writtenBytes: &writtenBytes)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        progressFraction(writtenBytes, totalBytes: m.size_bytes, progress: progress)

        let hash = hasher.finalize()
        guard hash.lowercased() == m.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            throw DLE.mismatch(expected: m.sha256, actual: hash)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        if filename != "weights.bin" {
            let legacy = dir.appendingPathComponent("weights.bin")
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: dest)
        }
        try m.sha256.write(to: shaPath, atomically: true, encoding: .utf8)
        progress(1.0)
        log("\(m.id) verified")
    }

    private func ensureSufficientDiskSpace(for expectedBytes: UInt64, at url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let availableBytes = values.volumeAvailableCapacityForImportantUsage,
              availableBytes > 0 else {
            return
        }

        let requiredBytes = expectedBytes + diskHeadroomBytes
        if UInt64(availableBytes) < requiredBytes {
            throw DLE.insufficientDiskSpace(requiredBytes: requiredBytes, availableBytes: UInt64(availableBytes))
        }
    }

    private func writeChunk(
        _ chunk: Data,
        to fileHandle: FileHandle,
        hasher: inout SHA256Hasher,
        writtenBytes: inout UInt64
    ) throws {
        try fileHandle.write(contentsOf: chunk)
        hasher.update(data: chunk)
        writtenBytes += UInt64(chunk.count)
    }

    private func progressFraction(_ writtenBytes: UInt64, totalBytes: UInt64, progress: (Double) -> Void) {
        guard totalBytes > 0 else { return }
        progress(min(Double(writtenBytes) / Double(totalBytes), 1.0))
    }

    private func log(_ m: String) { NSLog("[Models] \(m)") }
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
    case invalidURL
    case http(Int)
    case mismatch(expected: String, actual: String)
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .http(let c): return "HTTP \(c)"
        case .mismatch(let e, let a): return "sha256 mismatch \(e) != \(a)"
        case .insufficientDiskSpace(let requiredBytes, let availableBytes):
            let requiredGB = Double(requiredBytes) / 1_000_000_000
            let availableGB = Double(availableBytes) / 1_000_000_000
            return String(format: "insufficient disk space for download: need %.2f GB, have %.2f GB free", requiredGB, availableGB)
        }
    }
}
