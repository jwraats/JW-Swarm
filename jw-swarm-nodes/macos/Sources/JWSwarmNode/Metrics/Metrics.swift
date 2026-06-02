import Foundation

struct MetricsInfo {
    let totalMB: UInt64
    let usedMB: UInt64
    let gpuPct: Double
}

func deviceTotalMemoryMB() -> UInt64 {
    totalMemoryMB()
}

func detectedGPUDescription() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    task.arguments = ["SPDisplaysDataType", "-json"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return "Apple Silicon"
    }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    task.waitUntilExit()
    guard
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let displays = obj["SPDisplaysDataType"] as? [[String: Any]],
        let first = displays.first
    else {
        return "Apple Silicon"
    }
    if let model = first["sppci_model"] as? String, !model.isEmpty {
        return model
    }
    if let model = first["_name"] as? String, !model.isEmpty {
        return model
    }
    return "Apple Silicon"
}

func collectMetrics() -> MetricsInfo {
    MetricsInfo(totalMB: totalMemoryMB(), usedMB: usedMemoryMB(), gpuPct: gpuUtilPct())
}
private func totalMemoryMB() -> UInt64 {
    var size: size_t = 0
    var len = MemoryLayout<size_t>.size
    return (sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0)
        ? UInt64(size) / (1024 * 1024) : 0
}
private func usedMemoryMB() -> UInt64 {
    var info = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { bp in
            host_statistics64(host, HOST_VM_INFO64, bp, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let used = UInt64(info.active_count + info.inactive_count + info.wire_count) * UInt64(vm_page_size)
    return used / (1024 * 1024)
}
private func gpuUtilPct() -> Double {
    // powermetrics lives in /usr/bin and requires root; if it is missing or the
    // process fails to launch, return early. Never read the pipe unless the
    // process actually started, otherwise the read blocks forever waiting for an
    // EOF that never arrives (which would hang whatever thread calls this).
    let candidatePaths = ["/usr/bin/powermetrics", "/usr/sbin/powermetrics"]
    guard let toolPath = candidatePaths.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }) else {
        return 0
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: toolPath)
    task.arguments = ["--samplers", "gpu", "--samples", "1"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return 0
    }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    task.waitUntilExit()
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
        return 0
    }
    var maxMHz: Double? = nil, curMHz: Double? = nil
    for line in text.split(separator: "\n") {
        let low = String(line).lowercased()
        if let n = parseNumber(String(line)) {
            if low.contains("max") { maxMHz = n }
            if low.contains("current") || low.contains("freq") { curMHz = n }
        }
    }
    guard let c = curMHz, let m = maxMHz, m > 0 else { return 0 }
    return (c / m) * 100
}
private func parseNumber(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count >= 2, let d = Double(String(parts[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " MHz", with: "").replacingOccurrences(of: "%", with: "")) else {
        return nil
    }
    return d
}
