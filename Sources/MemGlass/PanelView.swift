import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var cleaner: CleanerModel

    @AppStorage("autoClean") private var autoClean: Bool = true
    @AppStorage("deepClean") private var deepClean: Bool = false
    @AppStorage("threshold") private var threshold: Double = 0.85

    var body: some View {
        VStack(spacing: 11) {
            HeaderBar(snapshot: monitor.snapshot)
            MainCard(snapshot: monitor.snapshot)
            SparkCard(history: monitor.history, threshold: threshold)
            AutoCleanCard(
                autoClean: $autoClean,
                deepClean: $deepClean,
                threshold: $threshold,
                cleaner: cleaner
            )
            ActionBar(cleaner: cleaner)
            ProcessCard(
                processes: monitor.processes,
                total: monitor.snapshot.total,
                onQuit: { cleaner.quitProcess($0) }
            )
            FooterBar(cleaner: cleaner)
        }
        .padding(13)
        .frame(width: 348)
        .background(GlassBackground())
    }
}

// MARK: - 顶部标题

struct HeaderBar: View {
    var snapshot: MemorySnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Palette.accentSoft, Palette.accent], startPoint: .top, endPoint: .bottom)
                )
            Text("东青MemGuard")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            PressureBadge(severity: snapshot.severity)
            Button {
                AppQuit.perform()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("退出东青MemGuard")
        }
    }
}

// MARK: - 主体卡片

struct MainCard: View {
    var snapshot: MemorySnapshot

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 14) {
                RingView(fraction: snapshot.usageFraction, severity: snapshot.severity, used: snapshot.used)
                    .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 9) {
                    StatRow(title: "应用内存", value: formatBytes(snapshot.appMemory), color: Palette.accent)
                    StatRow(title: "联动内存", value: formatBytes(snapshot.wired), color: Color(red: 0.22, green: 0.78, blue: 0.58))
                    StatRow(title: "已压缩", value: formatBytes(snapshot.compressed), color: Color(red: 0.35, green: 0.72, blue: 0.82))
                    StatRow(title: "缓存文件", value: formatBytes(snapshot.cached), color: Color(red: 0.62, green: 0.72, blue: 0.30))
                    StatRow(title: "已用交换", value: formatBytes(snapshot.swapUsed), color: Palette.warning)
                }
            }

            Divider().opacity(0.35)

            HStack {
                miniStat(title: "总量", value: formatGB(snapshot.total))
                Spacer()
                miniStat(title: "可用", value: formatBytes(snapshot.free))
                Spacer()
                miniStat(title: "交换总量", value: formatGB(snapshot.swapTotal))
            }
        }
        .padding(13)
        .glassCard()
    }

    private func miniStat(title: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 实时曲线

struct SparkCard: View {
    var history: [Double]
    var threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "实时占用趋势", trailing: "最近 3 分钟")
            Sparkline(values: history, threshold: threshold)
                .frame(height: 52)
        }
        .padding(12)
        .glassCard()
    }
}

// MARK: - 自动清理设置

struct AutoCleanCard: View {
    @Binding var autoClean: Bool
    @Binding var deepClean: Bool
    @Binding var threshold: Double
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Toggle("", isOn: $autoClean)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.accent)
                Text("自动清理")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("阈值 \(Int((threshold * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.critical)
            }

            Slider(value: $threshold, in: 0.55...0.97)
                .tint(Palette.accent)
                .controlSize(.small)
                .disabled(!autoClean)
                .opacity(autoClean ? 1 : 0.45)

            HStack(spacing: 7) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(cleaner.sudoersInstalled ? Palette.accent : Color.secondary)
                Text("深度内存回收")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if cleaner.sudoersInstalled {
                    Toggle("", isOn: $deepClean)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Palette.accent)
                } else {
                    Button {
                        cleaner.installSudoers()
                    } label: {
                        HStack(spacing: 4) {
                            if cleaner.isAuthorizing {
                                ProgressView().controlSize(.mini).tint(Palette.onAccent)
                            }
                            Text(cleaner.isAuthorizing ? "等待授权…" : "一键授权")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.accent))
                        .foregroundStyle(Palette.onAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(cleaner.isAuthorizing || cleaner.isCleaning)
                }
            }

            if !cleaner.sudoersInstalled {
                Text("需一次性管理员授权后才能免密回收内存。自动模式只回收系统内存，不会删除你的文件。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if autoClean {
                Text("内存超阈值时自动回收系统内存（不会删除你的文件）。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .glassCard()
    }
}

// MARK: - 操作按钮

struct ActionBar: View {
    @ObservedObject var cleaner: CleanerModel
    @AppStorage("deepClean") private var deepClean: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                cleaner.perform(deep: deepClean)
            } label: {
                HStack(spacing: 6) {
                    if cleaner.isCleaning {
                        ProgressView().controlSize(.small).tint(Palette.onAccent)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(cleaner.isCleaning ? "清理中…" : "立即清理")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.onAccent)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.accent, Palette.accentSoft],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(cleaner.isCleaning ? 0.55 : 1)
                    .shadow(color: Palette.accent.opacity(0.35), radius: 6, y: 2)
            )
            .disabled(cleaner.isCleaning || cleaner.isAuthorizing)

            Button {
                AppQuit.perform()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("退出")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 11)
                .frame(height: 33)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassCard(cornerRadius: 11)
            .help("退出东青MemGuard（也可右键菜单栏图标退出）")
        }
    }
}

// MARK: - 进程列表

struct ProcessCard: View {
    var processes: [ProcessItem]
    var total: UInt64
    var onQuit: (ProcessItem) -> Void

    private let rowCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "内存占用最高", trailing: "点击 ✕ 退出应用")

            if processes.isEmpty {
                Text("正在读取…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(0..<rowCount, id: \.self) { index in
                    if index < processes.count {
                        ProcessRow(item: processes[index], total: total, onQuit: onQuit)
                    } else {
                        ProcessRow(
                            item: ProcessItem(id: -1 - Int32(index), name: "", rss: 0),
                            total: total,
                            onQuit: onQuit,
                            placeholder: true
                        )
                    }
                }
            }
        }
        .padding(12)
        .glassCard()
    }
}

struct ProcessRow: View {
    var item: ProcessItem
    var total: UInt64
    var onQuit: (ProcessItem) -> Void
    var placeholder: Bool = false

    @State private var hovering = false

    var body: some View {
        let fraction = total > 0 ? Double(item.rss) / Double(total) : 0

        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(formatBytes(item.rss))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    onQuit(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Palette.critical : Color.secondary.opacity(0.4))
                .disabled(placeholder)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Palette.accentSoft, Palette.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, fraction * 3))))
                }
            }
            .frame(height: 4)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(placeholder ? 0 : 1)
    }
}

// MARK: - 底部状态

struct FooterBar: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("每 2 秒刷新")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusText: String {
        if let message = cleaner.statusMessage { return message }
        if let date = cleaner.lastCleanDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "上次清理 \(formatter.string(from: date))"
        }
        return "尚未执行清理"
    }
}