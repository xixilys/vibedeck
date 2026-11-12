import SwiftUI

/// Detail page for vm2api. Both provider groups use the same quota-card language as the overview;
/// the page exists to show both windows and the local trend without crowding the subscription grid.
struct VM2APIQuotaDetail: View {
    let snapshot: VM2APIQuotaStore.Snapshot
    let history: [String: [String: [VM2APIQuota.Sample]]]
    let now: TimeInterval
    var refresh: () -> Void

    private func fresh(_ quota: QuotaWindow?) -> Bool {
        guard let quota, let captured = quota.capturedAt else { return false }
        if quota.isExpired(now: now) { return true }
        return captured <= now + 60 && now - captured <= 600
    }

    private func delta(_ account: VM2APIQuota.Account) -> Double? {
        guard let samples = history[account.id]?["week"], let last = samples.last else { return nil }
        let target = now - 86400
        guard let base = samples.last(where: { $0.at <= target }) ?? samples.first,
              last.at - base.at >= 3600 else { return nil }
        return last.pct - base.pct
    }

    private func windowCard(_ title: String, _ quota: QuotaWindow?) -> some View {
        let pct = quota?.effectivePct(now: now) ?? 0
        let active = quota != nil
        return VStack(spacing: 3) {
            ZStack {
                RingGauge(value: Double(pct) / 100,
                          tint: active ? (fresh(quota) ? VG.heat(pct) : .secondary) : .secondary,
                          lineWidth: 5)
                Text(active ? AccountPresentation.percent(Double(pct)) : "—")
                    .font(VG.font(11, .bold)).monospacedDigit()
            }
            .frame(width: 48 * VG.scale, height: 48 * VG.scale)
            Text(title).font(VG.font(10, .medium))
            Text(active ? (QuotaPresentation.compactReset(to: quota?.resetsAt, now: now) ?? L("重置未知", "Reset ?")) : L("无样本", "No sample"))
                .font(VG.font(9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func accountCard(_ account: VM2APIQuota.Account) -> some View {
        let samples = history[account.id]?["week"] ?? []
        let change = delta(account)
        let tint = Brand.color(account.provider.title)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                BrandTag(tool: account.provider.title)
                Text(account.vmID).font(VG.headline)
                if !account.variant.isEmpty {
                    Text(account.variant).font(.system(size: 8.5 * VG.scale)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer(minLength: 4)
                if let captured = account.capturedAt > 0 ? account.capturedAt : nil {
                    Text(UIFormat.agoShort(max(0, Int(now - captured)))).font(VG.font(9)).foregroundStyle(.secondary)
                }
                if !account.note.isEmpty {
                    Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help(account.note)
                }
            }
            HStack(spacing: 10) {
                windowCard(L("5 小时", "5-hour"), account.fiveHour)
                windowCard(L("每周", "Weekly"), account.sevenDay)
            }
            if samples.count > 1 {
                HStack(spacing: 6) {
                    Sparkline(values: samples.map(\.pct), tint: tint, ceiling: 100, lineWidth: 1.2)
                        .frame(height: 24)
                    Text(L("7 天", "7 days")).font(VG.font(9)).foregroundStyle(.tertiary)
                    if let change, abs(change) >= 0.5 {
                        Text((change > 0 ? "+" : "") + String(format: "%.0f", change) + "pp / 24h")
                            .font(VG.font(9, .semibold)).foregroundStyle(change > 0 ? .orange : .green).monospacedDigit()
                    }
                }
                .help(L("周额度采样（本机记录）；最新点在右边。", "Weekly quota samples recorded locally; newest on the right."))
            }
            if !account.note.isEmpty {
                Text(account.note).font(VG.font(9)).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .glassTile(tint: tint)
    }

    private var grouped: [(provider: VM2APIQuota.Provider, accounts: [VM2APIQuota.Account])] {
        VM2APIQuota.Provider.allCases.compactMap { provider in
            let accounts = snapshot.accounts.filter { $0.provider == provider }
            return accounts.isEmpty ? nil : (provider, accounts)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.hosts.isEmpty ? "vm2api" : snapshot.hosts.joined(separator: " · "))
                        .font(VG.headline)
                    Text("Claude accounts + Codex quota-reader" + (snapshot.fetchedAt > 0
                         ? " · " + L("更新 ", "updated ") + UIFormat.agoShort(max(0, Int(now - snapshot.fetchedAt))) : ""))
                        .font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(L("刷新", "Refresh"), action: refresh).buttonStyle(.plain).font(VG.caption)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(L("vm2api 里有两组独立登录：Claude 账号和 Codex OAuth。Claude 额度来自 accounts 库的官方 5h / 7d 窗口，Codex 来自 quota-reader 的确认读数；两组都是普通订阅账号，额度分别计算、不相加。超过 10 分钟的读数会标钟表。",
                        "vm2api keeps two independent logins: Claude accounts and Codex OAuth. Claude quotas come from the official 5h/7d windows in its accounts database; Codex quotas come from the quota-reader cache. Both are ordinary subscriptions, counted separately and never summed. Readings older than 10 minutes show a clock."))
                    .font(VG.font(9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("来源：", "Source: ") + snapshot.hosts.joined(separator: ", ") + " · "
                     + VM2APIQuota.configuredCodexPath() + " · " + VM2APIQuota.configuredDBPath())
                    .font(VG.font(8.5)).foregroundStyle(.tertiary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .glassTile(tint: Brand.color("Claude"), padding: 9, radius: 10)

            if !snapshot.error.isEmpty {
                Label(snapshot.error, systemImage: "exclamationmark.triangle")
                    .font(VG.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !snapshot.claudeError.isEmpty || !snapshot.codexError.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !snapshot.claudeError.isEmpty { Text("Claude: " + snapshot.claudeError) }
                    if !snapshot.codexError.isEmpty { Text("Codex: " + snapshot.codexError) }
                }
                .font(VG.font(9)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if grouped.isEmpty {
                Text(L("还没有读到 vm2api 额度。点右上角刷新，或检查 SSH 与数据库路径。",
                       "No vm2api quota yet. Refresh above, or check SSH and the database path."))
                    .font(VG.caption).foregroundStyle(.secondary)
            } else {
                ForEach(grouped, id: \.provider) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            BrandTag(tool: group.provider.title)
                            Text("\(group.accounts.count) " + L("个账号", "accounts"))
                                .font(VG.font(9.5)).foregroundStyle(.secondary).monospacedDigit()
                            Spacer(minLength: 4)
                        }
                        ForEach(group.accounts) { account in accountCard(account) }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}
