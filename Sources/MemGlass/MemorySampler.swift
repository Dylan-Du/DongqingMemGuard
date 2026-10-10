import Foundation
import Darwin

// MARK: - 数据模型

enum PressureLevel {
    case normal
    case warning
    case critical

    init(raw: Int) {
        switch raw {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

struct MemorySnapshot {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Int = 1

    var usageFraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }

    var usagePercent: Double { usageFraction * 100 }

    var level: PressureLevel { PressureLevel(raw: pressure) }

    var severity: UsageSeverity { UsageSeverity(fraction: usageFraction) }
}

struct ProcessItem: Identifiable, Hashable {
    let id: Int32
    let name: String
    let rss: UInt64
}

// MARK: - 采样器

enum MemorySampler {

    static let pageSize: UInt64 = sysctlUInt64("hw.pagesize") ?? 16384

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private struct SwapUsage {
        var total: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var pagesize: UInt32 = 0
        var encrypted: Int32 = 0
    }

    static func readSwap() -> (total: UInt64, used: UInt64) {
        var usage = SwapUsage()
        var size = MemoryLayout<SwapUsage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.total, usage.used)
    }

    private static func hostVMStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    static func sample() -> MemorySnapshot {
        var snap = MemorySnapshot()

        let total = sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
        snap.total = total

        guard let stats = hostVMStatistics() else { return snap }

        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count) * page
        let externalPages = UInt64(stats.external_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page

        // 与「活动监视器」口径对齐：内存占用 = 应用内存 + 联动内存 + 已压缩
        let appMemory = internalPages > purgeable ? internalPages - purgeable : 0
        let used = appMemory + wired + compressed
        let cached = externalPages + purgeable
        let free = (used + cached) < total ? total - used - cached : 0

        snap.appMemory = appMemory
        snap.wired = wired
        snap.compressed = compressed
        snap.cached = cached
        snap.used = min(used, total)
        snap.free = free

        let swap = readSwap()
        snap.swapTotal = swap.total
        snap.swapUsed = swap.used

        snap.pressure = Int(sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)
        return snap
    }

    // MARK: 进程占用

    private struct ProcessGroup {
        var totalRSS: UInt64 = 0
        var peakRSS: UInt64 = 0
        var peakPID: Int32 = 0
        var mainPID: Int32?
        var rootPID: Int32?
    }

    /// 按「应用」归并统计（把 Chrome / TRAE 的多个 Helper 合并到所属 App）
    static func topProcesses(limit: Int = 6) -> [ProcessItem] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,ppid=,rss=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let selfPID = getpid()
        var groups: [String: ProcessGroup] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let rssKB = UInt64(parts[2]),
                  pid != selfPID else { continue }

            let path = String(parts[3])
            let name = groupingName(from: path)
            let bytes = rssKB * 1024

            var group = groups[name] ?? ProcessGroup()
            group.totalRSS += bytes
            if path.hasSuffix("/Contents/MacOS/\(name)") { group.mainPID = pid }
            if ppid == 1 { group.rootPID = pid }
            if bytes > group.peakRSS {
                group.peakRSS = bytes
                group.peakPID = pid
            }
            groups[name] = group
        }

        return groups
            .sorted { $0.value.totalRSS > $1.value.totalRSS }
            .prefix(limit)
            .map {
                ProcessItem(
                    id: $0.value.mainPID ?? $0.value.rootPID ?? $0.value.peakPID,
                    name: $0.key,
                    rss: $0.value.totalRSS
                )
            }
    }

    private static func groupingName(from path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        // 取最外层的 .app（Chrome / TRAE 的 Helper 本身也是独立 .app，需归并到主应用）
        if let appComponent = components.first(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }
        var name = components.last ?? path
        for suffix in [".xpc", ".appex", ".dext"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        for prefix in ["com.apple.", "com."] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name.isEmpty ? path : name
    }
}

// MARK: - 格式化

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}