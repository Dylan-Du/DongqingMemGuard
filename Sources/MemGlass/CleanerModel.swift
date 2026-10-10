import Foundation
import AppKit

struct CleanResult {
    var freedBytes: UInt64 = 0
    var itemsRemoved: Int = 0
    var purged = false
    var cacheCleared = false
    var details: [String] = []

    var summary: String {
        var parts: [String] = []
        if purged { parts.append("系统内存已回收") }
        if cacheCleared { parts.append("缓存已清理 \(formatBytes(freedBytes))") }
        if parts.isEmpty { parts.append("无需清理") }
        return parts.joined(separator: " · ")
    }
}

final class CleanerModel: ObservableObject {

    static let shared = CleanerModel()

    @Published var isCleaning = false
    @Published var isAuthorizing = false
    @Published var lastCleanDate: Date?
    @Published var lastResult: CleanResult?
    @Published var statusMessage: String?
    @Published var sudoersInstalled: Bool

    private var lastAutoClean: Date?
    /// 自动清理冷却时间放宽到 30 分钟，避免频繁触发 purge 造成系统卡顿
    private let autoCleanCooldown: TimeInterval = 1800
    private let workQueue = DispatchQueue(label: "com.memglass.cleaner", qos: .utility)

    private static let sudoersPath = "/etc/sudoers.d/memglass"

    private init() {
        sudoersInstalled = FileManager.default.fileExists(atPath: Self.sudoersPath)
    }

    // MARK: - 自动触发

    func autoCleanIfNeeded(_ snap: MemorySnapshot) {
        let defaults = UserDefaults.standard
        // 首次运行时 UserDefaults 中没有该键，需按「默认开启」处理
        let autoCleanEnabled = (defaults.object(forKey: "autoClean") as? Bool) ?? true
        guard autoCleanEnabled, !isCleaning, !isAuthorizing else { return }

        let threshold = defaults.object(forKey: "threshold") as? Double
            ?? MemoryMonitor.recommendedThreshold(forTotal: snap.total)
        // 占用率超阈值，或系统内存压力进入「紧张」时触发
        let pressureCritical = snap.pressure >= 4
        guard snap.usageFraction >= threshold || pressureCritical else { return }

        if let last = lastAutoClean, Date().timeIntervalSince(last) < autoCleanCooldown { return }
        lastAutoClean = Date()

        /// 自动模式只做「系统内存回收 (purge)」这一件事，且必须已获免密授权；
        /// 绝不自动删除用户文件，避免误删缓存导致其他应用异常或系统卡顿。
        if sudoersInstalled {
            perform(deep: true, automatic: true)
        } else {
            UserNotifier.post(
                title: "内存占用偏高",
                body: "在东青MemGuard 面板中「一键授权」后，即可自动回收系统内存。"
            )
        }
    }

    // MARK: - 执行清理

    func perform(deep: Bool, automatic: Bool = false) {
        guard !isCleaning, !isAuthorizing else { return }
        isCleaning = true
        statusMessage = automatic ? "内存超阈值，正在自动清理…" : "正在清理…"

        workQueue.async { [weak self] in
            guard let self else { return }
            var result = CleanResult()

            if deep {
                if self.sudoersInstalled {
                    result.purged = Self.runProcess("/usr/bin/sudo", ["-n", "/usr/sbin/purge"])
                } else if !automatic {
                    result.purged = Self.runAdmin("/usr/sbin/purge")
                }
                if result.purged { result.details.append("已执行系统内存回收 (purge)") }
            }

            if !automatic {
                let safe = Self.safeClean()
                result.freedBytes = safe.freedBytes
                result.itemsRemoved = safe.itemsRemoved
                result.cacheCleared = safe.itemsRemoved > 0
                result.details.append(contentsOf: safe.details)
            }

            DispatchQueue.main.async {
                self.isCleaning = false
                self.lastResult = result
                self.lastCleanDate = Date()
                self.statusMessage = result.summary
                self.notifyIfAutomatic(automatic: automatic, result: result)
            }
        }
    }

    private func notifyIfAutomatic(automatic: Bool, result: CleanResult) {
        guard automatic else { return }
        UserNotifier.post(title: "东青MemGuard 已自动清理", body: result.summary)
    }

    // MARK: - 安全清理（免密）

    /// 清理用户缓存、应用日志、临时文件（仅手动触发；不动废纸篓，避免误删）
    private static func safeClean() -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let targets: [(URL, TimeInterval, String)] = [
            (home.appendingPathComponent("Library/Caches"), 24 * 3600, "用户缓存"),
            (home.appendingPathComponent("Library/Logs"), 7 * 24 * 3600, "应用日志"),
            (URL(fileURLWithPath: "/private/tmp"), 3 * 24 * 3600, "临时文件")
        ]

        for (url, maxAge, label) in targets {
            let (bytes, count) = cleanDirectory(url, olderThan: maxAge)
            if count > 0 {
                result.freedBytes += bytes
                result.itemsRemoved += count
                result.details.append("清理\(label) \(formatBytes(bytes))")
            }
        }
        return result
    }

    @discardableResult
    private static func cleanDirectory(_ url: URL, olderThan maxAge: TimeInterval) -> (UInt64, Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: []
        ) else { return (0, 0) }

        var bytes: UInt64 = 0
        var count = 0
        let cutoff = Date().addingTimeInterval(-maxAge)

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            if maxAge > 0, let modified = values?.contentModificationDate, modified > cutoff { continue }
            let size = directorySize(entry)
            guard size > 0 else { continue }
            if (try? fm.removeItem(at: entry)) != nil {
                bytes += size
                count += 1
            }
        }
        return (bytes, count)
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    // MARK: - 深度回收授权（一次性）

    /// 授权过程会弹出系统密码框，必须在后台执行，绝不能阻塞主线程，否则 App 会卡死
    func installSudoers() {
        guard !isAuthorizing, !isCleaning else { return }
        isAuthorizing = true
        statusMessage = "请在系统弹窗中输入管理员密码…"

        workQueue.async { [weak self] in
            guard let self else { return }
            let user = NSUserName()
            let content = """
            # Managed by 东青MemGuard (MemGlass) — 允许免密执行系统内存回收
            \(user) ALL=(root) NOPASSWD: /usr/sbin/purge
            """
            let tmp = "/tmp/memglass_sudoers_\(UUID().uuidString)"
            var ok = false
            var message = "授权已取消"

            do {
                try content.write(toFile: tmp, atomically: true, encoding: .utf8)
                let cmd = "visudo -cf '\(tmp)' >/dev/null && chown root:wheel '\(tmp)' && chmod 440 '\(tmp)' && mv '\(tmp)' '\(Self.sudoersPath)'"
                ok = Self.runAdmin(cmd, timeout: 300)
                if ok { message = "已启用免密深度回收" }
            } catch {
                message = "授权失败：无法写入临时文件"
            }
            try? FileManager.default.removeItem(atPath: tmp)

            DispatchQueue.main.async {
                self.isAuthorizing = false
                self.sudoersInstalled = ok || FileManager.default.fileExists(atPath: Self.sudoersPath)
                self.statusMessage = message
                if self.sudoersInstalled {
                    UserDefaults.standard.set(true, forKey: "deepClean")
                }
            }
        }
    }

    func removeSudoers() {
        guard !isAuthorizing, !isCleaning else { return }
        isAuthorizing = true
        statusMessage = "正在关闭深度回收…"

        workQueue.async { [weak self] in
            guard let self else { return }
            let ok = Self.runAdmin("rm -f '\(Self.sudoersPath)'", timeout: 300)
            DispatchQueue.main.async {
                self.isAuthorizing = false
                if ok {
                    self.sudoersInstalled = false
                    UserDefaults.standard.set(false, forKey: "deepClean")
                    self.statusMessage = "已关闭深度回收"
                } else {
                    self.statusMessage = "操作已取消"
                }
            }
        }
    }

    // MARK: - 进程操作

    func quitProcess(_ item: ProcessItem) {
        guard let app = NSRunningApplication(processIdentifier: item.id) else {
            kill(item.id, SIGTERM)
            return
        }
        if !app.terminate() {
            app.forceTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MemoryMonitor.shared.refreshProcesses()
        }
    }

    // MARK: - 底层执行

    /// 执行外部命令并等待结束；带超时保护，避免命令卡住导致后台线程被永久占用
    private static func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            usleep(80_000)
        }
        if proc.isRunning {
            proc.terminate()
            usleep(200_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            return false
        }
        return proc.terminationStatus == 0
    }

    private static func runAdmin(_ shellCommand: String, timeout: TimeInterval = 120) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return runProcess("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }
}