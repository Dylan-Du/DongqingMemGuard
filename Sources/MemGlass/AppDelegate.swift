import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let monitor = MemoryMonitor.shared
    private let cleaner = CleanerModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()

        monitor.onSample = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
            self?.cleaner.autoCleanIfNeeded(snapshot)
        }
        updateStatusItem(monitor.snapshot)
        monitor.refresh()

        UserNotifier.requestAuthorization()

        if ProcessInfo.processInfo.environment["MEMGLASS_PREVIEW"] != nil {
            PreviewWindow.shared.show()
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "东青MemGuard")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// 左键弹面板；右键（或 Control+左键）弹原生菜单，保证「退出」永远可达
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showStatusMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开面板", action: #selector(openPanelFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let clean = NSMenuItem(title: "立即清理", action: #selector(cleanFromMenu), keyEquivalent: "")
        clean.target = self
        menu.addItem(clean)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出东青MemGuard", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // 借用系统机制弹出菜单：临时挂上 menu 触发点击，
        // 等菜单真正收起后再摘除，避免过早清空导致菜单不出现
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func openPanelFromMenu() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true { togglePopover(button) }
    }

    @objc private func cleanFromMenu() {
        cleaner.perform(deep: UserDefaults.standard.bool(forKey: "deepClean"))
    }

    @objc private func quitFromMenu() {
        AppQuit.perform()
    }

    /// 明确允许退出，避免任何窗口/弹出面板残留导致终止被拦下
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        popover?.close()
    }

    private func updateStatusItem(_ snapshot: MemorySnapshot) {
        guard let button = statusItem?.button else { return }
        button.title = " \(Int(snapshot.usagePercent.rounded()))%"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = "东青MemGuard · 已用 \(formatBytes(snapshot.used)) / \(formatGB(snapshot.total))"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // 打开前先刷新一次，保证面板数据是最新的
        monitor.isPanelVisible = true
        monitor.refresh()
        monitor.refreshProcesses()

        // 内容高度会随进程列表变化，展示前按真实尺寸重新定尺，避免弹窗超出屏幕顶部
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // 面板收起后停止向 SwiftUI 推送数据，避免隐藏状态下仍在重绘
    func popoverDidClose(_ notification: Notification) {
        monitor.isPanelVisible = false
    }

    // MARK: - 弹出面板

    private func setUpPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(
            rootView: PanelView(monitor: monitor, cleaner: cleaner)
        )
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        self.popover = popover
    }
}

// MARK: - 退出应用

/// 统一的退出入口：先收起弹出面板、关闭所有窗口，再终止；
/// 若 0.6 秒后进程仍在（极端情况下终止流程被拦下），直接强制退出兜底。
enum AppQuit {
    static func perform() {
        for window in NSApp.windows where window.isVisible {
            window.orderOut(nil)
        }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            exit(0)
        }
    }
}

// MARK: - 命令行数据校验

enum DumpMode {
    static func run() {
        let snapshot = MemorySampler.sample()
        print("总量        : \(formatBytes(snapshot.total))")
        print("已用        : \(formatBytes(snapshot.used))  (\(String(format: "%.1f", snapshot.usagePercent))%)")
        print("应用内存    : \(formatBytes(snapshot.appMemory))")
        print("联动内存    : \(formatBytes(snapshot.wired))")
        print("已压缩      : \(formatBytes(snapshot.compressed))")
        print("缓存文件    : \(formatBytes(snapshot.cached))")
        print("可用        : \(formatBytes(snapshot.free))")
        print("交换        : \(formatBytes(snapshot.swapUsed)) / \(formatBytes(snapshot.swapTotal))")
        print("压力等级    : \(snapshot.level.label) (raw=\(snapshot.pressure))")
        print("推荐阈值    : \(Int(MemoryMonitor.recommendedThreshold(forTotal: snapshot.total) * 100))%")
        print("--- 占用最高进程 ---")
        for item in MemorySampler.topProcesses(limit: 5) {
            print("  \(item.name)  \(formatBytes(item.rss))")
        }
    }
}

// MARK: - 设计预览窗口（开发调试用）

final class PreviewWindow {
    static let shared = PreviewWindow()
    private var window: NSWindow?

    func show() {
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingView(
            rootView: PanelView(monitor: MemoryMonitor.shared, cleaner: CleanerModel.shared)
        )
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

// MARK: - 系统通知

enum UserNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}