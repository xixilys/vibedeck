import SwiftUI

/// One row of the device switcher: who it is, whether it answers, and what it did today.
struct DeviceChoice: Identifiable {
    enum Kind { case all, local, remote }
    var id: String
    var title: String
    var kind: Kind
    /// nil = unknown (never pulled yet); local is always reachable.
    var online: Bool?
    var status: String
    var cost: String
    var tokens: Int64
    var tokenText: String = ""
    /// Today's API-equivalent spend per local hour, any currency folded to one scale (shape only).
    var hourly: [Double]
    var color: Color

    static let palette: [Color] = [
        Color(red: 0.16, green: 0.71, blue: 0.67), Color(red: 0.98, green: 0.56, blue: 0.20),
        Color(red: 0.91, green: 0.33, blue: 0.56), Color(red: 0.36, green: 0.73, blue: 0.33),
        Color(red: 0.63, green: 0.42, blue: 0.96), Color(red: 0.95, green: 0.75, blue: 0.18),
    ]
    static func color(kind: Kind, index: Int) -> Color {
        switch kind {
        case .all: return Glass.money
        case .local: return Color(red: 0.33, green: 0.47, blue: 1.0)
        case .remote: return palette[index % palette.count]
        }
    }
    var symbol: String {
        switch kind {
        case .all: return "square.stack.3d.up.fill"
        case .local: return "laptopcomputer"
        case .remote: return "server.rack"
        }
    }
}

/// The device switcher popover: a small "fleet" view instead of a plain menu. Each device gets its own colour,
/// a reachability dot and a 24-hour strip of today's activity; the "All" row shows how the day splits across them.
struct DevicePickerPanel: View {
    var choices: [DeviceChoice]
    var selected: String
    var select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("切换设备", "Switch device")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(L("今日 · 0–24 时", "Today · 0–24 h")).font(VG.font(9.5, .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            ForEach(choices) { choice in
                Button { select(choice.id) } label: { row(choice) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("device.choice.\(choice.id)")
                    .accessibilityValue(choice.id == selected ? L("已选中", "Selected") : "")
            }
        }
        .padding(10)
        .frame(width: 320 * VG.scale)
    }

    private var devices: [DeviceChoice] { choices.filter { $0.kind != .all } }

    private func row(_ choice: DeviceChoice) -> some View {
        let isSelected = choice.id == selected
        return HStack(spacing: 10) {
            glyph(choice)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(choice.title).font(VG.font(12.5, .semibold)).lineLimit(1).truncationMode(.middle)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10 * VG.scale)).foregroundStyle(choice.color)
                    }
                }
                if choice.kind == .all { shareBar } else {
                    Text(choice.status).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !choice.tokenText.isEmpty {
                    Text(choice.tokenText).font(VG.font(10, .medium)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(choice.cost).font(VG.font(12, .semibold)).monospacedDigit().lineLimit(1)
                HourStrip(values: choice.hourly, color: choice.color)
                    .frame(width: 72 * VG.scale, height: 13 * VG.scale)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? choice.color.opacity(0.14) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? choice.color.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func glyph(_ choice: DeviceChoice) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [choice.color, choice.color.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: choice.symbol).font(.system(size: 13 * VG.scale, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 32 * VG.scale, height: 32 * VG.scale)
        .overlay(alignment: .bottomTrailing) {
            if choice.kind != .all {
                Circle().fill(choice.online == true ? Color.green : choice.online == false ? Color.orange : Color.gray)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
    }

    /// Today's tokens split by device, in each device's colour.
    private var shareBar: some View {
        let total = max(1, devices.reduce(Int64(0)) { $0 + $1.tokens })
        return GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(devices.filter { $0.tokens > 0 }) { d in
                    Capsule().fill(d.color).frame(width: max(3, geo.size.width * CGFloat(Double(d.tokens) / Double(total)) - 1.5))
                }
            }
        }
        .frame(height: 5)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .clipShape(Capsule())
        .frame(maxWidth: 120 * VG.scale)
    }
}

/// 24 thin bars, one per hour; empty hours stay as faint ticks so the strip still reads as a day.
struct HourStrip: View {
    var values: [Double]
    var color: Color
    var body: some View {
        let peak = max(values.max() ?? 0, 1e-9)
        GeometryReader { geo in
            let gap: CGFloat = 1
            let width = max(1, (geo.size.width - gap * 23) / 24)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<24, id: \.self) { hour in
                    let v = hour < values.count ? values[hour] : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v > 0 ? color.opacity(0.35 + 0.65 * v / peak) : Color.primary.opacity(0.1))
                        .frame(width: width, height: v > 0 ? max(2, geo.size.height * CGFloat(v / peak)) : 1.5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
