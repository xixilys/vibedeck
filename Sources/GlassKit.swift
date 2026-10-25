import SwiftUI

/// Translucent building blocks shared by every page. Each metric family keeps one hue so a
/// glance at colour already says "CPU", "network" or "money"; percentages of quota keep VG.heat.
enum Glass {
    static let money = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let moneyEnd = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let cpu = Color(red: 0.20, green: 0.62, blue: 1.0)
    static let efficiency = Color(red: 0.35, green: 0.82, blue: 0.86)
    static let gpu = Color(red: 0.70, green: 0.45, blue: 1.0)
    static let memory = Color(red: 0.25, green: 0.80, blue: 0.55)
    static let wired = Color(red: 0.98, green: 0.70, blue: 0.25)
    static let compressed = Color(red: 0.95, green: 0.42, blue: 0.55)
    static let download = Color(red: 0.18, green: 0.75, blue: 0.95)
    static let upload = Color(red: 1.0, green: 0.48, blue: 0.40)
    static let disk = Color(red: 0.45, green: 0.52, blue: 1.0)
    static let latency = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let power = Color(red: 1.0, green: 0.80, blue: 0.20)

    static func thermal(_ celsius: Double?) -> Color {
        guard let celsius else { return .secondary }
        if celsius >= 90 { return .red }
        if celsius >= 75 { return .orange }
        if celsius >= 60 { return Color(red: 0.95, green: 0.75, blue: 0.2) }
        return memory
    }

    static func load(_ fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return cpu
    }

    static func latencyTint(_ ms: Int) -> Color {
        if ms <= 0 { return .secondary }
        if ms < 400 { return memory }
        if ms < 1200 { return Color(red: 0.95, green: 0.75, blue: 0.2) }
        return .orange
    }
}

// MARK: - Glass surface

/// A frosted tile: faint fill, a lit top edge and an optional coloured glow in one corner.
struct GlassTile: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 12
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(Color(nsColor: .controlBackgroundColor))
                    } else {
                        shape.fill(LinearGradient(colors: [Color.white.opacity(dark ? 0.10 : 0.62), Color.white.opacity(dark ? 0.035 : 0.30)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    if let tint, contrast != .increased {
                        shape.fill(RadialGradient(colors: [tint.opacity(dark ? 0.26 : 0.16), .clear],
                                                  center: .topLeading, startRadius: 0, endRadius: 190))
                    }
                }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.30), lineWidth: 1)
                } else {
                    shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.22 : 0.85), Color.white.opacity(dark ? 0.04 : 0.18)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
            }
    }
}

extension View {
    func glassTile(tint: Color? = nil, padding: CGFloat = 12, radius: CGFloat = 14) -> some View {
        modifier(GlassTile(tint: tint, padding: padding, radius: radius))
    }
}

/// Two soft colour fields behind the panel content; they read as depth through the popover glass.
struct AmbientBackdrop: View {
    var primary: Color
    var secondary: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geo in
            // Radial gradients instead of blur: identical in the live popover and offscreen renders, and cheaper.
            ZStack {
                if !reduceTransparency && contrast != .increased {
                    RadialGradient(colors: [primary.opacity(0.20), primary.opacity(0)], center: UnitPoint(x: 0.05, y: 0.0),
                               startRadius: 0, endRadius: max(geo.size.width, 1) * 0.9)
                    RadialGradient(colors: [secondary.opacity(0.15), secondary.opacity(0)], center: UnitPoint(x: 1.0, y: 1.0),
                               startRadius: 0, endRadius: max(geo.size.width, 1) * 0.95)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Charts

/// Smooth line with a fading fill. `ceiling` fixes the vertical scale (e.g. 1 for percentages).
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var ceiling: Double? = nil
    var lineWidth: CGFloat = 1.6
    var filled = true
    var dashedLast = false

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, size: geo.size, ceiling: ceiling)
            if points.count > 1 {
                ZStack {
                    if filled {
                        Self.path(points, closeTo: geo.size.height)
                            .fill(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    }
                    Self.path(points, closeTo: nil)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle().fill(tint).frame(width: lineWidth * 2.6, height: lineWidth * 2.6).position(last)
                    }
                }
            } else {
                Capsule().fill(tint.opacity(0.15)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], size: CGSize, ceiling: Double?) -> [CGPoint] {
        guard values.count > 1, values.allSatisfy({ $0.isFinite }),
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 4 else { return [] }
        let top = max(ceiling.flatMap { $0.isFinite ? $0 : nil } ?? (values.max() ?? 0) * 1.12, 0.000_001)
        let step = size.width / CGFloat(values.count - 1)
        let inset: CGFloat = 2
        return values.enumerated().map { index, value in
            let ratio = CGFloat(max(0, min(1, value / top)))
            return CGPoint(x: CGFloat(index) * step, y: inset + (size.height - inset * 2) * (1 - ratio))
        }
    }

    /// Monotone-ish smoothing through midpoints keeps peaks honest without overshoot.
    static func path(_ points: [CGPoint], closeTo baseline: CGFloat?) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        if let baseline { path.move(to: CGPoint(x: first.x, y: baseline)); path.addLine(to: first) }
        else { path.move(to: first) }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
            if index == points.count - 1 { path.addQuadCurve(to: point, control: point) }
        }
        if let baseline, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: baseline))
            path.closeSubpath()
        }
        return path
    }
}

/// Download above the axis, upload mirrored below; both share one scale so they compare honestly.
struct MirrorAreaChart: View {
    var up: [Double]
    var down: [Double]
    var upTint = Glass.download
    var downTint = Glass.upload

    var body: some View {
        let top = max((up + down).max() ?? 0, 1)
        VStack(spacing: 0) {
            half(up, top: top, tint: upTint)
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 0.5)
            half(down, top: top, tint: downTint).scaleEffect(x: 1, y: -1)
        }
        .accessibilityHidden(true)
    }

    private func half(_ values: [Double], top: Double, tint: Color) -> some View {
        GeometryReader { geo in
            let points = Sparkline.points(values, size: geo.size, ceiling: top)
            if points.count > 1 {
                ZStack {
                    Sparkline.path(points, closeTo: geo.size.height)
                        .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    Sparkline.path(points, closeTo: nil).stroke(tint, lineWidth: 1.2)
                }
            }
        }
    }
}

/// Columns with rounded tops; the last (current) column is solid, older ones fade.
struct GlassBars: View {
    var values: [Double]
    var labels: [String] = []
    var tint: Color
    var tintEnd: Color? = nil
    var highlightLast = true
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    @State private var hovered: Int?

    var body: some View {
        let top = max(values.max() ?? 0, 0.000_001)
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(values.indices, id: \.self) { index in
                        let isLast = highlightLast && index == values.count - 1
                        let height = max(2, geo.size.height * CGFloat(values[index] / top))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(colors: [tintEnd ?? tint, tint], startPoint: .top, endPoint: .bottom))
                            .opacity(hovered == index ? 1 : isLast ? 0.95 : values[index] > 0 ? 0.45 : 0.15)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                            .help((labels.indices.contains(index) ? labels[index] + " · " : "") + format(values[index]))
                            .accessibilityLabel(labels.indices.contains(index) ? labels[index] : String(index + 1))
                            .accessibilityValue(format(values[index]))
                    }
                }
                if average > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(height: 0.75)
                        .offset(y: -geo.size.height * CGFloat(average / top))
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - Gauges

/// Circular gauge with an angular gradient stroke and a quiet track.
struct RingGauge: View {
    var value: Double?
    var tint: Color
    var lineWidth: CGFloat = 5
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            if let value, value.isFinite, value > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, value)))
                    .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, min(1, value)))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Outer ring = longer window (week), inner ring = short window (5h). Missing windows leave a bare track.
struct DualRing: View {
    var outer: Double?
    var inner: Double?
    var outerTint: Color
    var innerTint: Color
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RingGauge(value: outer, tint: outerTint, lineWidth: size * 0.12)
            RingGauge(value: inner, tint: innerTint, lineWidth: size * 0.10)
                .padding(size * 0.19)
        }
        .frame(width: size, height: size)
    }
}

/// Per-core activity, E-cores in a cooler hue, like a small equalizer.
struct CoreBars: View {
    var cores: [Double]
    var efficiencyCores: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(cores.indices, id: \.self) { index in
                let tint = index < efficiencyCores ? Glass.efficiency : Glass.cpu
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                            .frame(height: max(3, geo.size.height * CGFloat(min(1, cores[index]))))
                    }
                }
                .help((index < efficiencyCores ? L("能效核", "E-core") : L("性能核", "P-core")) + " \(index) · " + SystemFormat.percent(cores[index]))
            }
        }
    }
}

/// A single horizontal bar made of coloured parts (memory composition, money by source…).
struct SegmentBar: View {
    struct Part: Identifiable { var id: String; var value: Double; var tint: Color }
    var parts: [Part]
    var total: Double? = nil
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            let sum = max(total ?? parts.reduce(0) { $0 + $1.value }, 0.000_001)
            HStack(spacing: 1.5) {
                ForEach(parts) { part in
                    Rectangle().fill(part.tint)
                        .frame(width: max(0, geo.size.width * CGFloat(part.value / sum) - 1.5))
                        .help(part.id)
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.07))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// Small label + value + optional micro chart, used in the overview vitals strip.
struct VitalChip: View {
    var symbol: String
    var title: String
    var value: String
    var tint: Color
    var series: [Double] = []
    var ceiling: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9 * VG.scale, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(VG.font(13, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
            Sparkline(values: series, tint: tint, ceiling: ceiling, lineWidth: 1.2)
                .frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(tint: tint, padding: 7, radius: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Pill used for sensors: coloured dot, value, caption.
struct SensorPill: View {
    var symbol: String
    var title: String
    var value: String
    var tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10 * VG.scale, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 14 * VG.scale)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(VG.font(12, .semibold)).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(title).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 0.6))
    }
}

// MARK: - Navigation

/// Quiet native button feedback; no scale animation or new polling work.
struct GlassActionStyle: ButtonStyle {
    var radius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        GlassActionBody(label: configuration.label, isPressed: configuration.isPressed, radius: radius)
    }
}

private struct GlassActionBody: View {
    let label: ButtonStyleConfiguration.Label
    let isPressed: Bool
    let radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        label
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? (isPressed ? 0.09 : hovered ? 0.045 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? (isPressed ? 0.88 : 1) : 0.45)
            .onHover { hovered = $0 }
    }
}

/// Tabs as a glass track with a sliding lit capsule.
struct GlassTabBar: View {
    struct Item: Identifiable { var id: Int; var title: String; var symbol: String }
    var items: [Item]
    @Binding var selection: Int
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    selection = item.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 10 * VG.scale, weight: .semibold))
                        Text(item.title).font(VG.caption.weight(selected ? .semibold : .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background {
                        if selected {
                            Capsule().fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(scheme == .dark ? 0.16 : 0.85))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.25 : 0.9), lineWidth: 0.6))
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(GlassActionStyle(radius: 20))
                .accessibilityIdentifier("tab.\(item.id)")
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        // Only the lit capsule slides; the page content swaps without an animation transaction.
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selection)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
        .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary.opacity(0.3) : Color.white.opacity(scheme == .dark ? 0.08 : 0.5), lineWidth: contrast == .increased ? 1 : 0.6))
    }
}

/// Section title used inside pages: small caps-like caption with an optional trailing view.
struct GlassSectionTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

extension GlassSectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.title = title; self.trailing = { EmptyView() } }
}
