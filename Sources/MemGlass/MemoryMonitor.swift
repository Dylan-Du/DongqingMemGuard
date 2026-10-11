import Foundation
import Combine

final class MemoryMonitor: ObservableObject {

    static let shared = MemoryMonitor()

    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var history: [Double] = []
    @Published private(set) var processes: [ProcessItem] = []

    private var sampleTimer: Timer?
    private var processTimer: Timer?
    private let historyLimit = 90
    private let processQueue = DispatchQueue(label: "com.memglass.process", qos: .utility)

    var onSample: ((MemorySnapshot) -> Void)?

    /// 面板是否可见。不可见时不向 SwiftUI 发布数据、也不采集进程列表，
    /// 避免隐藏状态下仍在每 2 秒重绘整棵视图树造成 CPU 周期性飙高
    var isPanelVisible = false

    private init() {
        applyRecommendedThresholdIfNeeded()
        refresh()
        refreshProcesses()

        let st = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(st, forMode: .common)
        sampleTimer = st

        let pt = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshProcesses() }
        RunLoop.main.add(pt, forMode: .common)
        processTimer = pt
    }

    func refresh() {
        let snap = MemorySampler.sample()
        // 菜单栏标题始终刷新（开销极小）
        onSample?(snap)
        guard isPanelVisible else { return }
        snapshot = snap
        history.append(snap.usageFraction)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    func refreshProcesses() {
        guard isPanelVisible else { return }
        processQueue.async { [weak self] in
            let items = MemorySampler.topProcesses(limit: 5)
            DispatchQueue.main.async { self?.processes = items }
        }
    }

    /// 按机器总内存自动给出推荐阈值（8G / 16G / 32G+ 分别不同）
    static func recommendedThreshold(forTotal total: UInt64) -> Double {
        let gb = Double(total) / 1_073_741_824
        if gb <= 9 { return 0.82 }
        if gb <= 17 { return 0.85 }
        if gb <= 34 { return 0.88 }
        return 0.90
    }

    private func applyRecommendedThresholdIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "threshold") == nil {
            let total = MemorySampler.sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
            defaults.set(MemoryMonitor.recommendedThreshold(forTotal: total), forKey: "threshold")
        }
    }
}