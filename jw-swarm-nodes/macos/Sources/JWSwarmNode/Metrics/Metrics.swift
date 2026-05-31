import Foundation

// MARK: - SystemMetrics (combines NodeMetrics with macOS system info)

struct SystemMetrics {
    let metrics: NodeMetrics
    let gpuName: String

    static func collect() -> SystemMetrics {
        let totalMB = SystemInfo.totalMemoryMB()
        let usedMB = SystemInfo.usedMemoryMB()
        let gpuUtil = SystemInfo.gpuUtilization()
        let nmetrics = NodeMetrics(
            vram_used_mb: usedMB,
            vram_total_mb: totalMB,
            gpu_util_pct: gpuUtil,
            tps: 0.0,
            latency_ms: 0.0,
            in_flight: 0
        )
        return SystemMetrics(metrics: nmetrics, gpuName: SystemInfo.gpuName())
    }
}

// MARK: - SystemInfo

struct SystemInfo {
    static func totalMemoryMB() -> UInt64 {
        var size: size_t = 0
        var len = MemoryLayout<size_t>.size
        guard sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 else {
            return 0
        }
        return UInt64(size) / (1024 * 1024)
    }

    static func usedMemoryMB() -> UInt64 {
        var info = vm_statistics64_data_t()
        var count = UInt32(
            MemoryLayout<vm_statistics64_data_t>.stride
            / MemoryLayout<natural_t>.stride
        )
        let host = mach_host_self()
        guard host_statistics64(host, HOST_VM_INFO64, &info, &count) == KERN_SUCCESS else {
            return 0
        }
        let pageSize = UInt64(vm_page_size)
        let used = UInt64(
            info.active_count
            + info.inactive_count
            + info.wire_count
        ) * pageSize
        return used / (1024 * 1024)
    }

    static func gpuUtilization() -> Double {
        guard let output = runCommand(
            "/usr/sbin/powermetrics",
            args: ["--samplers", "gpu", "--samples", "1"]
        ) else {
            return 0.0
        }
        let lines = output.components(separatedBy: "\n")
        var maxMHz: Double? = nil
        var curMHz: Double? = nil
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("max") {
                if let n = parseNumber(line) { maxMHz = n }
            }
            if lower.contains("current") || lower.contains("freq") {
                if let n = parseNumber(line) { curMHz = n }
            }
        }
        guard let cur = curMHz, let max = maxMHz, max > 0 else { return 0.0 }
        return min((cur / max) * 100.0, 100.0)
    }

    static func gpuName() -> String {
        return "Apple Silicon"
    }

    private static func runCommand(_ path: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func parseNumber(_ line: String) -> Double? {
        let parts = line.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        value = value.replacingOccurrences(of: " MHz", with: "")
        value = value.replacingOccurrences(of: "%", with: "")
        return Double(value)
    }
}
