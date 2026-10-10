import AppKit

// 命令行调试入口
if CommandLine.arguments.contains("--dump") {
    DumpMode.run()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()