import Foundation

struct MetricsInfo {
    let totalMB: UInt64
    let usedMB: UInt64
    let gpuPct: Double
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
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    let result = info.withUnsafeMutablePointer { ptr in
        host_statistics64(host, HOST_VM_INFO64, ptr.bindMemory(to: integer_t.self, capacity: Int(count)), &count)
    }
    guard result == KERN_SUCCESS else { return 0 }
    let used = UInt64(info.active_count + info.inactive_count + info.wire_count) * UInt64(vm_page_size)
    return used / (1024 * 1024)
}

private func gpuUtilPct() -> Double {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/powermetrics")
    task.arguments = ["--samplers", "gpu", "--samples", "1"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run(); task.waitUntilExit()
    guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return 0 }
    var maxMHz: Double? = nil, curMHz: Double? = nil
    for line in text.components(separatedBy: "\n") {
        let low = line.lowercased()
        if let n = parseNumber(line) {
            if low.contains("max") { maxMHz = n }
            if low.contains("current") || low.contains("freq") { curMHz = n }
        }
    }
    guard let c = curMHz, let m = maxMHz, m > 0 else { return 0 }
    return min((c / m) * 100, 100)
}

private func parseNumber(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count >= 2 else { return nil }
    var v = String(parts[1]).trimmingCharacters(in: .whitespaces)
    v = v.replacingOccurrences(of: " MHz", with: "")
    v = v.replacingOccurrences(of: "%", with: "")
    return Double(v)
}
