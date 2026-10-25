import SwiftUI
import AppKit

/// Process existence and an open turn are distinct observations. Never promote old samples to live work.
enum CodexProcessPresentation {
    static func isStale(_ process: CodexProcessInfo, now: TimeInterval) -> Bool {
        process.sampledAt <= 0 || now - process.sampledAt > 120 || process.sampledAt > now + 60
    }
    static func device(_ id: String) -> String {
        id == "local" ? L("本机", "Local") : RemoteCollector.displayName(for: id)
    }
    static func tint(_ state: CodexActivityState) -> Color {
        switch state {
        case .active: return .accentColor
        case .idle: return .secondary
        case .stopped, .unresponsive: return .orange
        case .unknown: return .secondary
        }
    }
    static func label(_ process: CodexProcessInfo, now: TimeInterval) -> String {
        if isStale(process, now: now) { return L("旧采样", "Old sample") }
        return process.state.label
    }
}

struct CodexProcessSummary: View {
    let processes: [CodexProcessInfo]
    let now: TimeInterval
    var open: () -> Void

    var body: some View {
        let current = processes.filter { !CodexProcessPresentation.isStale($0, now: now) }
        let openTurns = current.reduce(0) { $0 + $1.sessions.filter { $0.state == .active }.count }
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: "terminal").font(.system(size: 10 * VG.scale, weight: .semibold)).foregroundStyle(Brand.color("Codex"))
                Text(L("Codex 进程", "Codex processes")).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(current.isEmpty ? L("查看状态", "View status") : L("\(current.count) 个", "\(current.count) live"))
                    .font(VG.caption).foregroundStyle(.secondary).monospacedDigit()
                if openTurns > 0 {
                    Text(L("\(openTurns) 轮未结束", "\(openTurns) open turns"))
                        .font(VG.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 10 * VG.scale, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(VG.caption)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same quiet row as the vitals entry below it.
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassActionStyle(radius: 11)).accessibilityIdentifier("codex.processes.open")
        .help(L("查看各设备的进程、关联会话和状态依据；进程存活不等于正在执行任务。", "Inspect processes, linked sessions and evidence by device. A live process is not necessarily working."))
    }
}

struct CodexProcessDetailView: View {
    let processes: [CodexProcessInfo]
    let now: TimeInterval
    let observedDevices: [String]
    let errors: [String: String]
    @State private var deviceID = "all"

    private var devices: [String] { Array(Set(observedDevices + processes.map(\.deviceID) + Array(errors.keys))).sorted { a, b in (a == "local" && b != "local") || (a != "local" && b != "local" && a < b) } }
    private var visible: [CodexProcessInfo] {
        processes.filter { deviceID == "all" || $0.deviceID == deviceID }.sorted { a, b in
            if a.deviceID != b.deviceID { return a.deviceID < b.deviceID }
            if a.state != b.state { return a.state == .active || (b.state != .active && a.state.rawValue < b.state.rawValue) }
            return a.pid < b.pid
        }
    }
    private var inventoryUnavailable: Bool {
        guard visible.isEmpty else { return false }
        return deviceID == "all" ? observedDevices.isEmpty || !errors.isEmpty : !observedDevices.contains(deviceID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(inventoryUnavailable ? L("进程状态", "Process state") : L("\(visible.count) 个进程", "\(visible.count) processes")).font(VG.headline)
                VGInfoButton(title: L("状态如何判断", "How status is determined"),
                             text: L("按进程及启动时间识别，通过进程实际打开的会话文件读取明确的轮次开始／结束事件。未结束的轮次也可能在等工具或批准，不能据此断言模型正在生成。无法关联或采样过期时显示未知／旧采样。RSS 是单进程驻留内存，不是整组独占内存。", "Processes are identified by PID and start time. Explicit turn start/end events come from session files opened by that process. An open turn may be awaiting a tool or approval; it does not prove model generation. Unlinked or stale observations stay unknown/old. RSS is per-process resident memory, not exclusive process-tree memory."))
                Spacer(minLength: 4)
                Menu {
                    Button(L("全部设备", "All devices")) { deviceID = "all" }
                    ForEach(devices, id: \.self) { device in
                        Button(CodexProcessPresentation.device(device)) { deviceID = device }
                    }
                } label: {
                    Text(deviceID == "all" ? L("全部设备", "All devices") : CodexProcessPresentation.device(deviceID)).font(VG.caption)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("codex.processes.device")
            }
            Text(L("本机随扫描更新 · 远端约 5 分钟采样，可手动刷新", "Local scan updates · Remote snapshots about every 5 min; refresh on demand"))
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(errors.keys.sorted().filter { deviceID == "all" || deviceID == $0 }, id: \.self) { device in
                Label(CodexProcessPresentation.device(device) + " · " + L("暂时无法采集", "Collection unavailable"), systemImage: "exclamationmark.triangle")
                    .font(VG.caption).foregroundStyle(.orange).help(errors[device] ?? "")
            }
            if visible.isEmpty {
                Text(inventoryUnavailable ? L("暂无可确认的进程数据", "No confirmed process data yet") : L("此范围内未发现 Codex 进程", "No Codex processes observed in this scope"))
                    .font(VG.body).foregroundStyle(.secondary).padding(.vertical, 14)
            }
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(visible) { process in processRow(process) }
            }
        }
        .onChange(of: devices) { _, latest in if deviceID != "all" && !latest.contains(deviceID) { deviceID = "all" } }
    }

    private func processRow(_ process: CodexProcessInfo) -> some View {
        let stale = CodexProcessPresentation.isStale(process, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CodexProcessPresentation.device(process.deviceID)).font(VG.body.weight(.medium)).lineLimit(1)
                Text(process.role.label).font(VG.caption).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Text(CodexProcessPresentation.label(process, now: now)).font(VG.caption.weight(.medium))
                    .foregroundStyle(stale ? .secondary : CodexProcessPresentation.tint(process.state))
            }
            HStack(spacing: 8) {
                Text("PID \(process.pid)").monospacedDigit()
                Text(process.memMB.isFinite && process.memMB >= 0 ? String(format: "%.0f MB RSS", process.memMB) : "— RSS").monospacedDigit()
                Spacer(minLength: 0)
                Text(process.sampledAt > 0 ? (now - process.sampledAt < 5 ? L("刚刚", "Just now") : UIFormat.agoShort(max(0, Int(now - process.sampledAt)))) : "—")
                    .help(L("进程采样时间", "Process sample age"))
                Menu {
                    Button(L("复制 PID", "Copy PID")) { copy(String(process.pid)) }
                    if let cwd = process.cwd { Button(L("复制工作目录", "Copy working directory")) { copy(cwd) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L("进程定位信息", "Process location details"))
            }.font(VG.caption).foregroundStyle(.secondary)
            Text(process.cwd ?? L("工作目录不可用", "Working directory unavailable"))
                .font(VG.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if process.observationLimited || stale {
                Label(stale ? L("采样已过期，状态暂不作实时判断", "Old sample; activity is not current") : L("部分会话状态未知", "Some session states are unknown"), systemImage: "clock")
                    .font(VG.caption).foregroundStyle(.secondary)
            }
            if !process.sessions.isEmpty {
                DisclosureGroup(L("\(process.sessions.count) 个已关联会话", "\(process.sessions.count) linked sessions")) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(process.sessions) { session in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(String(session.id.suffix(8))).monospaced()
                                    Spacer()
                                    Text(stale ? L("旧采样", "Old sample") : session.state.label)
                                        .foregroundStyle(stale ? .secondary : CodexProcessPresentation.tint(session.state))
                                }
                                if let cwd = session.cwd { Text(cwd).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
                            }.font(VG.caption).help(session.basis.label + "\n" + session.id)
                        }
                    }.padding(.top, 7)
                }.font(VG.caption).tint(.secondary)
            } else {
                Text(process.basis.label).font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .glassTile(padding: 10, radius: 11)
        .accessibilityIdentifier("codex.process." + process.id)
        .help(process.basis.label)
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
