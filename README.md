# 东青MemGuard

一款为 macOS 打造的轻量级内存监控与自动清理工具。常驻菜单栏，实时显示内存占用，按机器内存容量自动设定阈值，超出后自动回收无用内存。界面采用苹果玻璃（Glass）风格，安静地待在顶部，不打扰你。

![icon](Packaging/icon_source.jpg)

## 功能特性

- **菜单栏常驻实时显示** — 顶部直接显示当前内存占用百分比，鼠标悬停查看「已用 / 总量」详情
- **智能阈值自适配** — 根据机器总内存自动推荐阈值：8G 机型 82%、16G 机型 85%、32G 机型 88%、更大机型 90%
- **自动清理** — 占用超过阈值后自动回收无用内存，带冷却机制与安全边界，避免频繁触发
- **玻璃风格面板** — 点击菜单栏图标弹出毛玻璃面板，含内存环形图、历史走势、压力等级、进程排行
- **进程一键退出** — 面板内直接查看占用最高的进程并一键结束
- **两档清理强度** — 免密清理（常规回收）与深度回收（`purge`，需管理员授权）

## 系统要求

- macOS 13.0 或更高版本
- 支持 Apple Silicon 与 Intel 机型

## 安装

1. 前往 [Releases](../../releases) 页面下载最新版 `东青MemGuard.dmg`
2. 打开 DMG，将「东青MemGuard」拖入「应用程序」文件夹
3. 首次启动若提示「无法验证开发者」，请在「系统设置 → 隐私与安全性」中点击「仍要打开」

## 使用

启动后应用会常驻菜单栏顶部：

- 点击菜单栏图标 → 展开内存面板
- 面板内可开关「自动清理」「深度回收」，并手动调整阈值
- 右上角关闭面板，应用继续在后台静默守护

## 从源码构建

```bash
# 编译并组装 .app
bash Packaging/build_app.sh

# 打包 DMG
bash Packaging/make_dmg.sh
```

生成产物位于 `dist/` 目录下。

## 项目结构

```
MemGlass/
├── Package.swift              # SPM 工程配置（macOS 13+）
├── Sources/MemGlass/
│   ├── main.swift             # 应用入口
│   ├── AppDelegate.swift      # 菜单栏项、弹出面板、生命周期
│   ├── MemoryMonitor.swift    # 采样调度与阈值自适配
│   ├── MemorySampler.swift    # 内存采样与进程统计核心
│   ├── CleanerModel.swift     # 清理引擎（免密 / 深度回收 / 自动清理）
│   ├── PanelView.swift        # 主面板布局
│   └── Support.swift          # 玻璃风格 UI 组件库
└── Packaging/
    ├── Info.plist             # 应用信息配置
    ├── build_app.sh           # 构建脚本
    ├── make_dmg.sh            # DMG 打包脚本
    ├── make_icon.swift        # 图标生成（squircle 遮罩）
    └── AppIcon.icns           # 应用图标
```

## 技术说明

- 纯原生实现：Swift 6 + SwiftUI + AppKit，无第三方依赖
- 内存数据来自 `host_statistics64` 与 `sysctl` 系统调用
- 进程统计基于 `ps` 采集，并按应用归并
- 深度回收通过 `purge` 命令，需要管理员授权

## 许可

本项目仅供学习与个人使用。