import SwiftUI

/// 设计 token。所有尺寸、圆角、动效曲线集中在这里，不要在视图里写魔法数字。
enum Theme {
    // 布局
    static let sidebarIdeal: CGFloat = 276
    static let listMin: CGFloat = 360
    static let listIdeal: CGFloat = 430
    static let detailMin: CGFloat = 380
    static let windowMinWidth: CGFloat = 1180
    static let windowMinHeight: CGFloat = 720

    // 形状
    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 9
    static let panelRadius: CGFloat = 18

    // 间距
    static let gap: CGFloat = 10
    static let pad: CGFloat = 14

    // 动效：两档就够。`spring` 用于结构变化（换视图、进出条件），`quick` 用于原地更新（数字、选中）
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let quick = Animation.smooth(duration: 0.18)

    static func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat = 11, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }

    /// 语义色：延迟越低越绿。阈值按实测来的——位图查询 p50 常态 8–20µs，
    /// 到 500µs 说明走了全表扫，再到 5ms 说明有问题。
    static func latencyTint(_ us: Double) -> Color {
        if us < 80 { return .green }
        if us < 600 { return .yellow }
        return .orange
    }
}

/// 玻璃卡片容器。
///
/// 只在**固定位置**用（侧栏、查询条、状态条），不要往 List 的行里塞：
/// 玻璃需要对背后内容采样，滚动列表里的玻璃会让每一帧都重新模糊，滚动直接掉帧。
struct GlassPanel<Content: View>: View {
    var tint: Color?
    var radius: CGFloat = Theme.cardRadius
    var padding: CGFloat = Theme.pad
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular,
                in: .rect(cornerRadius: radius)
            )
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(Theme.label(10, .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(10))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

/// 一行「名称 / 值」，值用等宽字体并可选中
struct StatRow: View {
    let name: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(Theme.label(11))
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(Theme.mono(11))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// 查询耗时徽标
struct LatencyBadge: View {
    let micros: Double

    var body: some View {
        let tint = Theme.latencyTint(micros)
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 8))
            Text(text)
                .font(Theme.mono(11, .medium))
                .monospacedDigit()
                .contentTransition(.numericText(value: micros))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }

    private var text: String {
        micros < 1000 ? String(format: "%.0f µs", micros) : String(format: "%.2f ms", micros / 1000)
    }
}

/// 计数徽标
struct CountBadge: View {
    let value: Int
    var tint: Color = .secondary

    var body: some View {
        Text("\(value)")
            .font(Theme.mono(10, .medium))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

/// 连接状态灯：就绪时有一圈缓慢呼吸的光晕（`TimelineView` 驱动，不占主线程定时器）
struct StatusDot: View {
    let ready: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !ready)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = ready ? (sin(t * 1.6) * 0.5 + 0.5) : 0
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(ready ? Color.green.opacity(0.55 * pulse) : .clear, lineWidth: 1)
                        .scaleEffect(1 + pulse * 1.6)
                        .opacity(ready ? 1 - pulse * 0.6 : 0)
                }
        }
        .frame(width: 16, height: 16)
    }
}

/// 图标按钮。
///
/// 不用 `.buttonStyle(.glass)`：玻璃按钮在浅色材质上会变成一块白色圆角，
/// 图标本身是白的，等于看不见。这里用「极淡的底色 + 悬停加深」，图标始终是 label 色，
/// 在浅色/深色下都可读。玻璃留给真正需要它的面板层。
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var prominent = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
        .help(help)
    }

    private var fill: Color {
        if prominent { return Color.accentColor.opacity(hover ? 0.24 : 0.14) }
        return Color.primary.opacity(hover ? 0.11 : 0.055)
    }
}

/// 下拉菜单的图标形态，和 IconButton 长得一样，避免两种按钮并排时风格打架
struct MenuIcon<Content: View>: View {
    let symbol: String
    var help: String = ""
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hover ? 0.11 : 0.055))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
        .help(help)
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.blurReplace)
    }
}
