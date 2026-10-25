import SwiftUI

/// Native material, readable captions, and a restrained hierarchy of labels and values.
enum VG {
    static var scale: CGFloat { UITheme.fontScale }

    /// Collapse legacy sizes into the panel's three readable type sizes.
    private static func typeSize(_ legacy: CGFloat) -> CGFloat {
        if legacy < 12 { return 11 }
        if legacy < 16 { return 13 }
        return 24
    }

    static func scaled(_ legacy: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: typeSize(legacy) * scale, weight: weight, design: design)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, _ design: Font.Design = .default) -> Font {
        .system(size: typeSize(size) * scale, weight: weight, design: design)
    }
    static var title: Font { .system(size: 14 * scale, weight: .semibold) }
    static var headline: Font { font(13, .semibold) }
    static var body: Font { font(13) }
    static var callout: Font { .system(size: 12 * scale) }
    static var subheadline: Font { font(11) }
    static var caption: Font { font(11) }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: min(24, max(11, size)) * scale, weight: weight, design: .default).monospacedDigit()
    }

    static let radius: CGFloat = 10
    static let fill = Color.primary.opacity(0.05)
    static let fillStrong = Color.primary.opacity(0.06)
    static let stroke = Color.primary.opacity(0.08)

    /// Used percentages share one meaning throughout the panel.
    static func heat(_ pct: Int) -> Color { VGUsageLevel.evaluate(pct).tint }
}

// MARK: - 卡片

struct VGCardModifier: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: VG.radius, style: .continuous).fill(VG.fill))
    }
}

extension View {
    /// Legacy cards now share the frosted glass tile so older pages match the redesigned ones.
    func vgCard(padding: CGFloat = 10) -> some View {
        modifier(GlassTile(tint: nil, padding: padding, radius: 12))
    }

    /// Neutral legacy fill with a continuous rounded shape and no extra outline.
    func vgFill(_ opacity: Double, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
        return background(shape.fill(Color.primary.opacity(opacity * 0.65)))
    }
}

// MARK: - 基础部件

/// A quiet section marker; colour carries meaning without a row of solid icon tiles.
struct VGIcon: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.8 * VG.scale, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size * VG.scale, height: size * VG.scale)
    }
}

/// 分区标题：图标方块 + 标题 + 右侧附注。
struct VGSectionHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            VGIcon(symbol: symbol, tint: tint)
            Text(title).font(VG.headline).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

extension VGSectionHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String, tint: Color = .accentColor) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.trailing = { EmptyView() }
    }
}

/// 胶囊标签（状态 / 档位）。
struct VGPill: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(VG.font(9, .bold)) }
            Text(text).font(VG.font(10, .medium)).lineLimit(2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize(horizontal: false, vertical: true)
        .help(text)
    }
}

/// 细进度条（胶囊形）。
struct VGProgress: View {
    var value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5
    var marker: Double? = nil
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if value > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(1, geo.size.width * CGFloat(max(0, min(1, value)))))
                }
                if let marker {
                    Rectangle().fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * CGFloat(max(0, min(1, marker))) - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}

/// 数字小卡：标题 / 大号数值 / 说明。
struct VGStat: View {
    let title: String
    let value: String
    var detail: String = ""
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(VG.font(10, .semibold)).foregroundStyle(tint) }
                Text(title).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(VG.number(13)).lineLimit(1).minimumScaleFactor(0.85)
            if !detail.isEmpty {
                Text(detail).font(VG.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 柱状图：values 与 labels 等长；projected 是最后一根的预测（画成虚底）。
struct VGBarChart: View {
    let values: [Double]
    let labels: [String]
    var projectedLast: Double? = nil
    var tint: Color = .accentColor
    var height: CGFloat = 56
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        let top = max(values.max() ?? 0, projectedLast ?? 0, 0.000_001)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    let isLast = i == values.count - 1
                    ZStack(alignment: .bottom) {
                        if isLast, let p = projectedLast, p > values[i] {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .frame(height: max(2, height * CGFloat(p / top)))
                        }
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(tint.opacity(isLast ? 1 : (values[i] > 0 ? 0.45 : 0.12)))
                            .frame(height: max(2, height * CGFloat(values[i] / top)))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(labels.indices.contains(i) ? labels[i] : "") · \(format(values[i]))")
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack {
                Text(labels.first ?? "").font(VG.caption).foregroundStyle(.secondary)
                Spacer()
                Text(labels.last ?? "").font(VG.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 两列键值行。
struct VGKeyValue: View {
    let key: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(VG.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(VG.font(11, .medium)).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension NerfReport.Status {
    var tint: Color {
        switch self {
        case .alert: return .red
        case .watch: return .orange
        case .ok: return .green
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .alert: return "exclamationmark.octagon.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.seal.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    var label: String {
        switch self {
        case .alert: return L("疑似降智", "Possible degradation")
        case .watch: return L("有可疑迹象", "Suspicious signs")
        case .ok: return L("未见异常", "No anomalies")
        case .unknown: return L("暂无数据", "No data")
        }
    }
}

extension NerfFinding.Severity {
    var tint: Color {
        switch self {
        case .hard: return .red
        case .soft: return .orange
        case .info: return .secondary
        case .good: return .green
        }
    }
    var symbol: String {
        switch self {
        case .hard: return "xmark.octagon.fill"
        case .soft: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        case .good: return "arrow.up.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .hard: return L("硬证据", "Hard evidence")
        case .soft: return L("可疑", "Suspicious")
        case .info: return L("提示", "Tip")
        case .good: return L("好消息", "Good news")
        }
    }
}

/// Pure threshold decision, with a separate forecast flag so low usage can still warn.
enum VGUsageLevel: Equatable {
    case normal, elevated, critical

    static func evaluate(_ usedPct: Int, predictedDepletion: Bool = false) -> Self {
        if predictedDepletion || usedPct > 85 { return .critical }
        return usedPct >= 60 ? .elevated : .normal
    }

    var tint: Color {
        switch self {
        case .normal: return .accentColor
        case .elevated: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark"
        case .elevated: return "exclamationmark"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .normal: return L("正常", "Normal")
        case .elevated: return L("用量偏高", "High usage")
        case .critical: return L("即将用尽", "Near limit")
        }
    }
}

/// Secondary explanations are readable on demand without extending the first screen.
struct VGInfoButton: View {
    let title: String
    let text: String
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "info.circle").font(VG.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(VG.headline)
                Text(text).font(VG.body).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 280, alignment: .leading)
        }
    }
}
