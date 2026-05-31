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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/powermetrics")
    task.arguments = ["--samplers", "gpu", "--samples", "1"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run(); task.waitUntilExit()
    guard let data = try? pipe.fileHandleForReading.read(upToCount: Int.max), !data.isEmpty else {
        return 0
    }
    guard let text = String(data: data, encoding: .utf8) else { return 0 }
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
