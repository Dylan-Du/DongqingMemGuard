import SwiftUI
import AppKit

// MARK: - 配色

/// 依据实际占用率划分的视觉等级（蓝色为主，仅在真正吃紧时才转暖色）
enum UsageSeverity {
    case normal
    case elevated
    case critical

    init(fraction: Double) {
        if fraction >= 0.92 { self = .critical }
        else if fraction >= 0.80 { self = .elevated }
        else { self = .normal }
    }

    var label: String {
        switch self {
        case .normal: return "正常"
        case .elevated: return "偏高"
        case .critical: return "紧张"
        }
    }
}

enum Palette {
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.00)
    static let accentSoft = Color(red: 0.52, green: 0.84, blue: 1.00)
    static let warning = Color(red: 1.00, green: 0.70, blue: 0.26)
    static let critical = Color(red: 1.00, green: 0.37, blue: 0.39)

    static func levelColor(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .normal: return accent
        case .elevated: return warning
        case .critical: return critical
        }
    }

    static func gradient(_ severity: UsageSeverity) -> [Color] {
        switch severity {
        case .normal: return [accent, accentSoft]
        case .elevated: return [warning, Color(red: 1.0, green: 0.86, blue: 0.47)]
        case .critical: return [critical, Color(red: 1.0, green: 0.56, blue: 0.44)]
        }
    }
}

// MARK: - 玻璃材质

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

struct GlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blending: .behindWindow)
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.02), Color.black.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - 通用组件

struct PressureBadge: View {
    var severity: UsageSeverity

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.levelColor(severity))
                .frame(width: 6, height: 6)
                .shadow(color: Palette.levelColor(severity).opacity(0.8), radius: 3)
            Text(severity.label)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Palette.levelColor(severity).opacity(0.16))
        )
        .overlay(Capsule().strokeBorder(Palette.levelColor(severity).opacity(0.35), lineWidth: 1))
        .foregroundStyle(Palette.levelColor(severity))
    }
}

struct StatRow: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.55), radius: 3)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}

struct SectionLabel: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 环形占用图

struct RingView: View {
    var fraction: Double
    var severity: UsageSeverity
    var used: UInt64

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), style: StrokeStyle(lineWidth: 11, lineCap: .round))

            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: Palette.gradient(severity)),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.levelColor(severity).opacity(0.45), radius: 6, y: 1)
                .animation(.easeOut(duration: 0.55), value: fraction)

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((fraction * 100).rounded()))")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("已用 \(formatGB(used))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(4)
    }
}

// MARK: - 折线图

struct Sparkline: View {
    var values: [Double]
    var threshold: Double

    private struct ChartGeometry {
        var points: [CGPoint] = []
        var thresholdY: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func compute(_ size: CGSize) -> ChartGeometry {
        let w = size.width
        let h = size.height
        let lo = max(0, (values.min() ?? 0) - 0.10)
        let hi = min(1, (values.max() ?? 1) + 0.10)
        let span = max(0.20, hi - lo)

        let yFor: (Double) -> CGFloat = { v in
            h - CGFloat((min(max(v, lo), hi) - lo) / span) * h
        }

        let pts: [CGPoint] = values.enumerated().map { idx, v in
            let x = values.count > 1 ? w * CGFloat(idx) / CGFloat(values.count - 1) : 0
            return CGPoint(x: x, y: yFor(v))
        }

        return ChartGeometry(points: pts, thresholdY: yFor(threshold), width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            let g = compute(geo.size)

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.thresholdY))
                    p.addLine(to: CGPoint(x: g.width, y: g.thresholdY))
                }
                .stroke(Palette.critical.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if g.points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: g.points[0].x, y: g.height))
                        g.points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: g.points[g.points.count - 1].x, y: g.height))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Palette.accent.opacity(0.28), Palette.accent.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { p in
                        p.move(to: g.points[0])
                        g.points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(
                        LinearGradient(colors: [Palette.accentSoft, Palette.accent], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    if let last = g.points.last {
                        Circle()
                            .fill(Palette.accentSoft)
                            .frame(width: 6, height: 6)
                            .shadow(color: Palette.accentSoft.opacity(0.8), radius: 4)
                            .position(last)
                    }
                }
            }
        }
    }
}