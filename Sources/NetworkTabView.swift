import SwiftUI
import Foundation

/// 网络页只接收缓存快照；所有采集都由 NetworkScanner 的后台队列完成，避免菜单栏主线程被命令或网络请求卡住。
public struct NetworkTabView: View {
    public let snapshot: NetworkSnapshot
    public let onRetest: () -> Void
    public let width: CGFloat

    public init(snapshot: NetworkSnapshot, onRetest: @escaping () -> Void = {}, width: CGFloat = 331) {
        self.snapshot = snapshot; self.onRetest = onRetest; self.width = width
    }

    private var traceExits: [AIExitStatus] { snapshot.aiExits.filter { !$0.isGemini } }

    private var exitsDiffer: Bool {
        let good = traceExits.filter { !$0.ip.isEmpty && $0.error.isEmpty }
        return Set(good.map { "\($0.ip)|\($0.loc)" }).count > 1
    }

    private var exitSummary: String {
        let good = traceExits.filter { !$0.ip.isEmpty && $0.error.isEmpty }
        guard !good.isEmpty else { return L("出口暂不可用", "Egress unavailable") }
        let count = Set(good.map { "\($0.ip)|\($0.loc)" }).count
        let unavailable = traceExits.count - good.count
        let summary = count == 1
            ? L("\(good.count) 家服务同一出口", "\(good.count) services share an exit")
            : L("出口不一致 · \(count) 个出口", "Different exits · \(count) routes")
        let availability = unavailable > 0 ? summary + L(" · \(unavailable) 家不可用", " · \(unavailable) unavailable") : summary
        return good.contains(where: isStale) ? availability + L(" · 含旧值", " · Includes stale") : availability
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("网络出口", "Network exits")).font(VG.headline)
                Spacer(minLength: 6)
                if snapshot.isRefreshing { ProgressView().controlSize(.mini) }
                Button(action: onRetest) {
                    Label(L("重测", "Retest"), systemImage: "arrow.clockwise").font(VG.caption)
                }
                .buttonStyle(.borderless)
                .help(L("立即重测（10 秒内最多一次）", "Retest now (at most once every 10 seconds)"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if exitsDiffer { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                Text(exitSummary).font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            aiExitSection
            leakSection
            DisclosureGroup {
                exitDetails.padding(.top, 5)
            } label: {
                Text(L("出口与检测详情", "Exit & check details")).font(VG.body)
            }
            .tint(.secondary)
            DisclosureGroup {
                proxySection.padding(.top, 5)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("代理内核", "Proxy engine")).font(VG.body)
                    Spacer(minLength: 4)
                    Text(!snapshot.proxy.error.isEmpty ? L("暂不可用", "Unavailable") : snapshot.proxy.running ? L("运行中", "Running") : L("未检测到", "Not detected"))
                        .font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).help(snapshot.proxy.error)
                }
            }
            .tint(.secondary)
            DisclosureGroup {
                localSection.padding(.top, 5)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("本机连接", "Local connection")).font(VG.body)
                    Spacer(minLength: 4)
                    Text(snapshot.local.interfaceName).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.secondary)
        }
        .frame(width: width, alignment: .leading)
    }

    // Trace refreshes every 60 seconds and connection routes every 10 seconds.
    // Ten minutes without a new sample is clearly old, without flagging normal in-flight probes.
    private func isStale(_ item: AIExitStatus) -> Bool {
        item.capturedAt > 0 && Date().timeIntervalSince1970 - item.capturedAt >= 600
    }

    /// "US" → 🇺🇸; anything else stays empty.
    static func flag(_ code: String) -> String {
        let letters = code.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "" }
        return String(String.UnicodeScalarView(letters.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    private func exitStatus(_ item: AIExitStatus) -> String {
        if item.isGemini {
            if item.error.hasPrefix("走出站：") { return L("活动路由", "Active route") }
            if item.error == "无活动连接，查不到出口" { return L("无活动连接", "No active connection") }
            return item.capturedAt == 0 ? "—" : L("出口未知", "Exit unknown")
        }
        guard item.error.isEmpty, !item.ip.isEmpty else {
            return item.capturedAt == 0 && item.error.isEmpty ? "—" : L("暂不可用", "Unavailable")
        }
        return item.loc.isEmpty ? "—" : item.loc
    }

    private func changeDescription(_ item: AIExitStatus) -> String {
        L("旧 IP：\(item.previousIP) → 新 IP：\(item.changedNewIP.isEmpty ? item.ip : item.changedNewIP) · \(item.previousAt > 0 ? Fmt.dateText(item.previousAt) : L("时间未知", "Unknown time"))",
          "Previous IP: \(item.previousIP) → new IP: \(item.changedNewIP.isEmpty ? item.ip : item.changedNewIP) · \(item.previousAt > 0 ? Fmt.dateText(item.previousAt) : L("时间未知", "Unknown time"))")
    }

    private var aiExitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.aiExits) { item in
                let healthy = !item.isGemini && item.error.isEmpty && !item.ip.isEmpty
                HStack(alignment: .center, spacing: 7) {
                    Circle().fill(healthy ? Glass.latencyTint(item.latencyMS) : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .shadow(color: healthy ? Glass.latencyTint(item.latencyMS).opacity(0.6) : .clear, radius: 3)
                    Text(item.name).font(VG.body)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    Spacer(minLength: 2)
                    Text((healthy ? Self.flag(item.loc) + " " : "") + exitStatus(item)).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                    if healthy {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.latencyMS > 0 ? "\(item.latencyMS) ms" : "—")
                                .font(VG.caption.weight(.medium)).monospacedDigit().foregroundStyle(Glass.latencyTint(item.latencyMS))
                            Capsule().fill(Color.primary.opacity(0.08)).frame(width: 46, height: 3)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Glass.latencyTint(item.latencyMS))
                                        .frame(width: 46 * CGFloat(min(1, Double(item.latencyMS) / 2500)), height: 3)
                                }
                        }
                        .fixedSize()
                    }
                    if isStale(item) {
                        Image(systemName: "clock")
                            .font(VG.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(L("旧值", "Stale sample"))
                            .help(L("旧值 · ", "Stale sample · ") + UIFormat.agoShort(max(0, Int(Date().timeIntervalSince1970 - item.capturedAt))))
                    }
                    if item.changed {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(VG.caption).foregroundStyle(.orange)
                            .accessibilityLabel(L("出口变化", "Exit changed"))
                            .help(changeDescription(item))
                    }
                }
                .help(item.isGemini || !item.error.isEmpty ? diagnosticText(item.error) : "\(item.ip) · \(item.colo)")
            }
            if snapshot.aiExits.isEmpty {
                Text(L("等待后台采集…", "Waiting for background collection…"))
                    .font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .vgCard(padding: 10)
    }

    private var exitDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.aiExits) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(VG.body)
                    if !item.isGemini, !item.ip.isEmpty {
                        Text("\(item.ip) · \(item.loc.isEmpty ? "—" : item.loc) · \(item.colo.isEmpty ? "—" : item.colo)")
                            .monospaced().textSelection(.enabled)
                    }
                    if !item.error.isEmpty {
                        Text(diagnosticText(item.error)).help(item.error)
                    } else if item.isGemini {
                        Text(L("等待连接表采集", "Waiting for connection data"))
                    }
                    if item.capturedAt > 0 {
                        Text(L("采样：", "Sampled: ") + Fmt.dateText(item.capturedAt) + " · " + UIFormat.agoShort(max(0, Int(Date().timeIntervalSince1970 - item.capturedAt))))
                    } else { Text(L("尚未采样", "Not sampled yet")) }
                    if item.changed { Text(changeDescription(item)).foregroundStyle(.orange) }
                }
                .font(VG.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("IPv6 · " + diagnosticText(snapshot.leak.ipv6Message) + (snapshot.leak.ipv6Country.isEmpty ? "" : " · \(snapshot.leak.ipv6Country)"))
                .help(snapshot.leak.ipv6Message)
            Text(dnsVerdictText)
            if snapshot.leak.checkedAt > 0 {
                Text(L("检测：", "Checked: ") + Fmt.dateText(snapshot.leak.checkedAt))
            }
        }
        .font(VG.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !snapshot.proxy.error.isEmpty {
                Text(diagnosticText(snapshot.proxy.error)).font(VG.scaled(11)).foregroundColor(.secondary).help(snapshot.proxy.error)
            } else {
                HStack {
                    Circle().fill(snapshot.proxy.running ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text(snapshot.proxy.running ? L("运行中", "Running") : L("未检测到", "Not detected"))
                        .font(VG.scaled(11, weight: .medium))
                        .foregroundColor(.primary)
                    if !snapshot.proxy.version.isEmpty { Text("· \(snapshot.proxy.version)").font(VG.scaled(11)).foregroundColor(.secondary) }
                }
                ForEach(snapshot.proxy.groups) { group in
                    HStack(spacing: 5) {
                        Text(group.name).font(VG.caption).fixedSize(horizontal: false, vertical: true)
                        Text(group.type).font(VG.scaled(11)).foregroundColor(.secondary)
                        Spacer(minLength: 4); Text(group.now.isEmpty ? L("未选择", "Not selected") : group.now).font(VG.scaled(11, design: .monospaced)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                    }
                }
                ForEach(snapshot.proxy.connections) { c in
                    if c.count > 0 {
                        HStack(spacing: 5) {
                            Text(c.name).font(VG.scaled(11)); Text(L("\(c.count) 连接", "\(c.count) connections")).font(VG.scaled(11)).foregroundColor(.secondary)
                            if !c.chains.isEmpty { Text(c.chains.joined(separator: L("、", ", "))).font(VG.scaled(11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        if !c.rules.isEmpty {
                            Text(L("规则：", "Rules: ") + c.rules.joined(separator: " / ")).font(VG.scaled(11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            localRow(L("默认路由", "Route"), value: snapshot.local.gateway.isEmpty ? L("查不到（系统未提供默认路由）", "Unavailable (system has no default route)") : "\(snapshot.local.gateway) · \(snapshot.local.interfaceName)")
            localRow("IPv4", value: snapshot.local.ipv4.isEmpty ? L("未检测到接口 IPv4", "No interface IPv4 detected") : snapshot.local.ipv4)
            localRow("IPv6", value: snapshot.local.ipv6.isEmpty ? L("未检测到 global IPv6", "No global IPv6 detected") : snapshot.local.ipv6)
            localRow("DNS", value: snapshot.local.dnsServers.isEmpty ? L("查不到（resolver #1 未提供 nameserver）", "Unavailable (resolver #1 has no nameserver)") : snapshot.local.dnsServers.joined(separator: ", "))
            if !snapshot.local.wifiName.isEmpty {
                localRow("Wi-Fi", value: snapshot.local.wifiName == "未连接 Wi-Fi" ? L("未连接 Wi-Fi", "Not connected") : snapshot.local.wifiName)
            }
            if !snapshot.local.tailscaleIP.isEmpty { localRow("Tailscale", value: snapshot.local.tailscaleIP) }
            if let down = snapshot.local.downloadBPS, let up = snapshot.local.uploadBPS {
                localRow(L("实时速率", "Speed"), value: "↓ \(formatRate(down))  ↑ \(formatRate(up))")
            } else { localRow(L("实时速率", "Speed"), value: L("查不到（采样不足或接口计数器不可用）", "Unavailable (not enough samples or interface counters unavailable)")) }
        }
    }

    private func localRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(VG.caption).fixedSize()
                Spacer(minLength: 0)
                Text(value).font(VG.caption).foregroundStyle(.secondary).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VG.caption)
                Text(value).font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(value)
    }

    private var leakSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            statusRow("IPv6", value: snapshot.leak.ipv6Blocked == false ? L("可能绕过代理", "May bypass proxy")
                      : snapshot.leak.ipv6Blocked == true ? L("未发现直连出口", "No direct exit found")
                      : L("未检测", "Not checked"), warning: snapshot.leak.ipv6Blocked == false)
                .help(diagnosticText(snapshot.leak.ipv6Message))
            statusRow("DNS", value: snapshot.leak.dnsVerdict == .domesticWarning ? L("可能漏到国内", "Possible domestic leak")
                      : snapshot.leak.dnsVerdict == .proxyOK ? L("走代理内核", "Uses proxy engine")
                      : L("未知", "Unknown"), warning: snapshot.leak.dnsVerdict == .domesticWarning)
                .help(dnsVerdictText)
        }
    }

    private func statusRow(_ title: String, value: String, warning: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if warning { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text(value).foregroundStyle(warning ? Color.orange : .secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .font(VG.caption)
    }

    private var dnsVerdictText: String {
        switch snapshot.leak.dnsVerdict {
        case .domesticWarning: return L("DNS 可能漏到国内", "DNS may leak to domestic resolvers")
        case .proxyOK: return L("DNS 走代理内核", "DNS uses the proxy engine")
        case .unknown: return L("DNS 查不到（本机 resolver 无法判断）", "DNS unknown (local resolver is inconclusive)")
        }
    }

    private func diagnosticText(_ text: String) -> String {
        switch text {
        case "未检测": return L(text, "Not checked")
        case "IPv6 可直连（可能绕过代理隧道）⚠️": return L(text, "Direct IPv6 available (may bypass the proxy tunnel)")
        case "无 IPv6 出口（探测走 IPv4 进隧道）✓": return L(text, "No IPv6 exit (probe used IPv4 through the tunnel)")
        case "IPv6 可直连（响应无 trace）⚠️": return L(text, "Direct IPv6 available (response has no trace)")
        case "IPv6 出站已阻断 ✓": return L(text, "IPv6 egress blocked")
        case "查不到出口：代理连接表不可用": return L(text, "Exit unavailable: proxy connection table unavailable")
        case "无活动连接，查不到出口": return L(text, "No active connections; exit unavailable")
        case "有活动连接，但连接表未提供出站链路": return L(text, "Active connections have no outbound chain details")
        case "未检测到代理内核（clash API 未开或端口不对）": return L(text, "Proxy engine unavailable (check Clash API and port)")
        case "响应缺少有效的 ip / loc / colo 字段": return L(text, "Response is missing valid ip / loc / colo fields")
        default:
            let outboundPrefix = "走出站："
            if text.hasPrefix(outboundPrefix) { return L(text, "Outbound: " + String(text.dropFirst(outboundPrefix.count))) }
            guard text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return text }
            return L(text, "Collection unavailable; see details on hover")
        }
    }

    private func formatRate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
}
