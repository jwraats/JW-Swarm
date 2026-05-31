import Foundation

func collectMetrics() -> MetricsInfo {
    let total = totalMemoryMB()
    let used  = usedMemoryMB()
    let gpu   = gpuUtilPct()
    return MetricsInfo(totalMB: total, usedMB: used, gpuPct: gpu, name: "Apple Silicon")
}

struct MetricsInfo { let totalMB: UInt64; let usedMB: UInt64; let gpuPct: Double; let name: String }

private func totalMemoryMB() -> UInt64 {
    var size: size_t = 0
    var len = MemoryLayout<size_t>.size
    return (sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0)
           ? UInt64(size) / (1024*1024) : 0
}

private func usedMemoryMB() -> UInt64 {
    var info  = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let host = mach_host_self()
    guard host_statistics64(host, HOST_VM_INFO64,
                            &info.assumingMemoryBound(to: integer_t.self),
                            &count) == KERN_SUCCESS else { return 0 }
    let used = UInt64(info.active_count + info.inactive_count + info.wire_count)
               * UInt64(vm_page_size)
    return used / (1024*1024)
}

private func gpuUtilPct() -> Double {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/powermetrics")
    task.arguments = ["--samplers", "gpu", "--samples", "1"]
    let pipe = Pipe(); task.standardOutput = pipe
    try? task.run(); task.waitUntilExit()
    guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return 0 }
    var max_: Double? = nil
    var cur_: Double? = nil
    for line in text.components(separatedBy: "\n") {
        let lo = line.lowercased
        if let n = parseNum(line) {
            if lo.contains("max") { max_ = n }
            if lo.contains("current") || lo.contains("freq") { cur_ = n }
        }
    }
    guard let c = cur_, let m = max_, m > 0 else { return 0 }
    return min((c / m) * 100, 100)
}

private func parseNum(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count >= 2 else { return nil }
    var v = String(parts[1]).trimmingCharacters(in: .whitespaces)
    v = v.replacingOccurrences(of: " MHz", with: "")
    v = v.replacingOccurrences(of: "%", with: "")
    return Double(v)
}
