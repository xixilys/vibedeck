import SwiftUI

/// One row in the subscription monitor picker. Built from the same cards and vm2api accounts the
/// overview renders, so the checkbox always describes something that exists on the page.
struct SubscriptionMonitorEntry: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var group: String
    var tint: Color
    var symbol: String
}

/// Compact chip + custom popover. Native menus hide the checkmark behind a submenu and feel like a
/// settings dialog; this keeps selection visible as a real checkbox and puts quota context next to it.
struct SubscriptionMonitorControl: View {
    let entries: [SubscriptionMonitorEntry]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void
    @Binding var isPresented: Bool

    private var selectedCount: Int { entries.filter { isSelected($0.id) }.count }
    private var summary: String {
        if selectedCount == entries.count { return L("全部", "All") }
        return "\(selectedCount)/\(entries.count)"
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "checklist").font(.system(size: 9 * VG.scale, weight: .bold))
                Text(L("监控", "Monitor")).font(VG.font(10.5, .semibold))
                Text(summary).font(VG.font(9.5, .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(LinearGradient(colors: [Glass.money, Glass.moneyEnd], startPoint: .leading, endPoint: .trailing))
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background {
                Capsule().fill(LinearGradient(colors: [Glass.money.opacity(0.18), Glass.moneyEnd.opacity(0.13)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(Capsule().strokeBorder(Glass.money.opacity(0.30), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SubscriptionMonitorPanel(entries: entries, isSelected: isSelected, toggle: toggle,
                                     selectAll: selectAll, selectNone: selectNone)
        }
        .help(L("选择首页要显示的订阅；包括 vm2api 的 Claude / Codex。只影响显示，不改变采集与告警。",
                "Choose which subscriptions the overview shows, including vm2api Claude/Codex. Display only — collection and alerts are unchanged."))
        .accessibilityIdentifier("subscriptions.monitor")
    }
}

struct SubscriptionMonitorPanel: View {
    let entries: [SubscriptionMonitorEntry]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void
    let selectAll: () -> Void
    let selectNone: () -> Void
    @State private var hovered: String?

    private var selectedCount: Int { entries.filter { isSelected($0.id) }.count }
    private var groups: [(name: String, entries: [SubscriptionMonitorEntry])] {
        var order: [String] = []
        var byName: [String: [SubscriptionMonitorEntry]] = [:]
        for entry in entries {
            if byName[entry.group] == nil { order.append(entry.group) }
            byName[entry.group, default: []].append(entry)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }
    private var allSelected: Bool { selectedCount == entries.count }
    private var panelHeight: CGFloat {
        let rows = CGFloat(entries.count) * 45
        let sections = CGFloat(max(groups.count, 1)) * 26
        return min(430, max(180, 104 + rows + sections))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.name) { group in
                        section(group.name, group.entries)
                    }
                    if entries.isEmpty {
                        Text(L("还没有可监控的订阅", "No subscriptions to monitor yet"))
                            .font(VG.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
            }
            Divider().opacity(0.45)
            footer
        }
        .frame(width: 306, height: panelHeight)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("监控订阅", "Monitor subscriptions")).font(VG.headline)
                Spacer(minLength: 4)
                Text("\(selectedCount)/\(entries.count)")
                    .font(VG.font(12, .semibold)).monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [Glass.money, Glass.moneyEnd], startPoint: .leading, endPoint: .trailing))
            }
            HStack(spacing: 5) {
                Text(L("勾选后才会出现在首页", "Checked items appear on the overview"))
                    .font(.system(size: 9 * VG.scale)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                compactAction(L("全选", "All"), active: allSelected, action: selectAll)
                compactAction(L("清空", "None"), active: selectedCount == 0, action: selectNone)
            }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 9)
    }

    private func compactAction(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(VG.font(9.5, .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(Color.primary.opacity(active ? 0.10 : 0.05)))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func section(_ name: String, _ items: [SubscriptionMonitorEntry]) -> some View {
        if !items.isEmpty {
            let selected = items.filter { isSelected($0.id) }.count
            HStack(spacing: 5) {
                Text(name).font(.system(size: 9.5 * VG.scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(selected)/\(items.count)").font(.system(size: 8.5 * VG.scale)).monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            ForEach(items) { entry in row(entry) }
        }
    }

    private func row(_ entry: SubscriptionMonitorEntry) -> some View {
        let checked = isSelected(entry.id)
        let hovering = hovered == entry.id
        return Button {
            toggle(entry.id)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(entry.tint.opacity(checked ? 0.18 : 0.10))
                    Image(systemName: entry.symbol)
                        .font(.system(size: 11 * VG.scale, weight: .semibold))
                        .foregroundStyle(entry.tint.opacity(checked ? 1 : 0.8))
                }
                .frame(width: 27 * VG.scale, height: 27 * VG.scale)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(VG.font(11.5, .medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(entry.subtitle).font(.system(size: 9 * VG.scale)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                MonitorCheck(checked: checked, tint: entry.tint)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(checked ? entry.tint.opacity(0.10) : hovering ? Color.primary.opacity(0.045) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = entry.id }
            else if hovered == entry.id { hovered = nil }
        }
        .accessibilityLabel(entry.title)
        .accessibilityValue(checked ? L("已选", "Selected") : L("未选", "Not selected"))
        .accessibilityAddTraits(checked ? .isSelected : [])
        .help(entry.subtitle)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye").font(.system(size: 9 * VG.scale, weight: .semibold))
            Text(L("只影响首页显示 · 采集与告警照常", "Display only · collection and alerts unchanged"))
            Spacer(minLength: 2)
            Text("vm2api").font(.system(size: 8.5 * VG.scale, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 9 * VG.scale))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// A real checkbox with a springy checkmark; the whole row is the hit target.
struct MonitorCheck: View {
    var checked: Bool
    var tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(checked ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.72)],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.clear))
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .strokeBorder(checked ? tint.opacity(0) : Color.secondary.opacity(0.38), lineWidth: 1.15)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9 * VG.scale, weight: .heavy))
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        .shadow(color: checked ? tint.opacity(0.28) : .clear, radius: 3, y: 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.68), value: checked)
    }
}
