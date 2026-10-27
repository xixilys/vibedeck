import SwiftUI

struct AccountPresentation: Identifiable {
    var id: String
    var account: AccountIdentity?
    var usage: AccountUsageGroup?
    var quotas: [AccountQuotaObservation]
    /// Current signed-in device sources; historical observations do not inflate this list.
    var signedInSources: [String] = []
    /// Subscription plans without a sign-in identity (Grok, GLM, Gemini) carry their own "Tool · Plan" title.
    var planTitle: String? = nil

    var title: String {
        if let planTitle { return planTitle }
        let provider = account?.provider ?? quotas.first?.provider ?? ""
        let tool = provider == "openai" ? "Codex" : provider == "anthropic" ? "Claude" : provider.capitalized
        if let label = account?.displayLabel, !label.isEmpty { return tool + " · " + label }
        if let account { return tool + " · " + String(account.accountID.suffix(6)) }
        let source = quotas.first?.source ?? usage?.bySource.keys.sorted().first ?? ""
        return source.isEmpty ? L("未归属", "Unassigned") : AccountPresentation.sourceLabel(source)
    }
    static func sourceLabel(_ source: String) -> String {
        let tool = UsageHistory.cli(of: source)
        return tool + " · " + (UsageHistory.device(of: source).map { RemoteCollector.displayName(for: $0) } ?? L("本机", "Local"))
    }
    var sources: [String] {
        if !signedInSources.isEmpty { return signedInSources }
        return Array(Set((usage?.bySource.keys.map { $0 } ?? []) + quotas.flatMap { $0.associatedSources ?? [$0.source] })).sorted()
    }

    static func latestPresence(_ observations: [AccountPresence]) -> [AccountPresence] {
        var latest: [String: AccountPresence] = [:]
        for observation in observations {
            if let old = latest[observation.id], old.sampledAt > observation.sampledAt { continue }
            latest[observation.id] = observation
        }
        return latest.values.sorted { ($0.deviceID, $0.tool) < ($1.deviceID, $1.tool) }
    }

    static func isCurrent(_ observation: AccountPresence, now: TimeInterval) -> Bool {
        observation.sampledAt.isFinite && observation.sampledAt > 0 &&
            observation.sampledAt <= now + 60 && now - observation.sampledAt <= 600
    }

    /// A quota or historical request never establishes a current login.
    static func currentCards(usage: AccountUsageSnapshot, quotas: [AccountQuotaObservation],
                             presence: [AccountPresence], now: TimeInterval) -> [Self] {
        var cards: [String: Self] = [:]
        for login in latestPresence(presence) where isCurrent(login, now: now) && login.isIdentifiedLogin {
            guard let identity = login.account else { continue }
            let source = login.tool + (login.deviceID == "local" ? "" : " · " + login.deviceID)
            if cards[identity.key] == nil {
                let group = usage.groups.first { $0.account == identity }
                // Keep only explicit account matches. In particular, matching reset times
                // do not make an anonymous observation belong to this login.
                let matching = quotas.filter { $0.account == identity }
                cards[identity.key] = Self(id: identity.key, account: group?.account ?? identity, usage: group,
                                           quotas: AccountUsage.mergedQuotas(matching))
            }
            cards[identity.key]?.signedInSources.append(source)
        }
        return cards.values.map { card in
            var value = card; value.signedInSources = Array(Set(value.signedInSources)).sorted(); return value
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    static func cards(usage: AccountUsageSnapshot, quotas: [AccountQuotaObservation], now: TimeInterval) -> [Self] {
        var cards: [String: Self] = [:]
        for group in usage.groups {
            cards[group.id] = Self(id: group.id, account: group.account, usage: group, quotas: [])
        }
        let merged = AccountUsage.mergedQuotas(quotas)
        // One device can report the same login twice, once with its account id and once without.
        // Same source, pool, window and reset time means the same quota: fold it into the identified account.
        let identified = merged.filter { $0.account != nil }
        for var q in merged {
            if q.account == nil, let match = identified.first(where: {
                $0.source == q.source && $0.pool == q.pool && $0.window == q.window && Self.sameCycle($0.resetAt, q.resetAt)
            }) { q.account = match.account }
            let key = q.account?.key ?? "unassigned:" + q.source
            if cards[key] == nil { cards[key] = Self(id: key, account: q.account, usage: nil, quotas: []) }
            cards[key]?.quotas.append(q)
        }
        return cards.values.sorted { a, b in
            let ac = a.quotas.contains { ($0.resetAt ?? 0) > now }, bc = b.quotas.contains { ($0.resetAt ?? 0) > now }
            if ac != bc { return ac }
            if (a.account != nil) != (b.account != nil) { return a.account != nil }
            return (a.title, a.id) < (b.title, b.id)
        }
    }
    /// Providers jitter reset timestamps by a few seconds between devices and samples.
    static func sameCycle(_ a: TimeInterval?, _ b: TimeInterval?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return abs(x - y) <= 600
        case (nil, nil): return true
        default: return false
        }
    }

    /// Collapse observations of one cycle (pool + window + reset within 10 min) to the newest trusted reading.
    static func distinctCycles(_ cycles: [AccountCycleUsage]) -> [AccountCycleUsage] {
        var kept: [AccountCycleUsage] = []
        for cycle in cycles {
            let q = cycle.observation
            if let index = kept.firstIndex(where: {
                $0.observation.pool == q.pool && $0.observation.window == q.window && sameCycle($0.observation.resetAt, q.resetAt)
            }) {
                let old = kept[index].observation
                if (q.trusted && !old.trusted) || (q.trusted == old.trusted && q.capturedAt > old.capturedAt) { kept[index] = cycle }
            } else {
                kept.append(cycle)
            }
        }
        return kept
    }

    static func poolLabel(_ pool: String) -> String {
        pool.split(separator: ":").map { part in
            part == "codex" ? "Codex" : part == "claude" ? "Claude" : String(part)
        }.joined(separator: " · ")
    }
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: value == value.rounded() ? "%.0f%%" : "%.1f%%", value)
    }
    static func selfTest() {
        precondition(percent(31.5) == "31.5%" && percent(30) == "30%")
        let a = AccountIdentity(provider: "openai", accountID: "fixture-a")!
        let q = AccountQuotaObservation(account: a, source: "Codex", provider: "openai", pool: "codex", window: "5h",
                                        startedAt: 100, resetAt: 300, capturedAt: 150, usedPercent: 30)
        var remote = q; remote.source = "Codex · fixture"; remote.capturedAt = 160
        let merged = cards(usage: AccountUsageSnapshot(), quotas: [q, remote], now: 200)
        precondition(merged.count == 1 && merged[0].quotas.count == 1 && merged[0].quotas[0].source == remote.source)
        remote.account = nil
        precondition(cards(usage: AccountUsageSnapshot(), quotas: [q, remote], now: 200).count == 2)
        precondition(merged[0].currentQuotas(at: 301).isEmpty)
        var anonymous = q; anonymous.account = nil; anonymous.capturedAt = 170
        precondition(cards(usage: AccountUsageSnapshot(), quotas: [q, anonymous], now: 200).count == 1, "same source/window/reset folds into the identified account")
        let login = AccountPresence(deviceID: "local", tool: "Codex", state: .loggedIn, account: a,
                                    sampledAt: 150, basis: .cliStatus, method: "chatgpt")
        let otherDevice = AccountPresence(deviceID: "fixture", tool: "Codex", state: .loggedIn, account: a,
                                          sampledAt: 150, basis: .cliStatus, method: "chatgpt")
        let current = currentCards(usage: AccountUsageSnapshot(), quotas: [q, anonymous], presence: [login, otherDevice], now: 200)
        precondition(current.count == 1 && current[0].sources.count == 2 && current[0].quotas.count == 1)
        precondition(current[0].quotas[0].capturedAt == q.capturedAt, "Anonymous quota cannot replace identified quota")
        precondition(currentCards(usage: AccountUsageSnapshot(), quotas: [q], presence: [], now: 200).isEmpty)
        precondition(currentCards(usage: AccountUsageSnapshot(), quotas: [], presence: [login], now: 200).count == 1,
                     "New current accounts remain visible before any quota or history exists")
        precondition(currentCards(usage: AccountUsageSnapshot(), quotas: [q], presence: [login], now: 751).isEmpty)
        let logout = AccountPresence(deviceID: "local", tool: "Codex", state: .loggedOut, account: nil,
                                     sampledAt: 180, basis: .cliStatus, method: nil)
        precondition(currentCards(usage: AccountUsageSnapshot(), quotas: [q], presence: [login, logout], now: 200).isEmpty)
        let unknown = AccountPresenceCollector.unknown(tool: "Codex", deviceID: "fixture", now: 190)
        precondition(currentCards(usage: AccountUsageSnapshot(), quotas: [q], presence: [unknown], now: 200).isEmpty)
        precondition(sameCycle(1000, 1003) && !sameCycle(1000, 5000))
        var undated = q; undated.resetAt = nil
        precondition(cards(usage: AccountUsageSnapshot(), quotas: [undated], now: 200)[0].currentQuotas(at: 200).count == 1)
    }
    func currentQuotas(at now: TimeInterval) -> [AccountQuotaObservation] {
        var latest: [String: AccountQuotaObservation] = [:]
        for q in quotas where q.resetAt.map({ $0 > now }) ?? true {
            let key = q.pool + ":" + q.window
            if let old = latest[key], old.trusted && !q.trusted { continue }
            if latest[key] == nil || (q.trusted && latest[key]?.trusted == false) || (latest[key]?.capturedAt ?? 0) < q.capturedAt { latest[key] = q }
        }
        return latest.values.sorted { ($0.pool, $0.window) < ($1.pool, $1.window) }
    }
}

struct AccountQuotaSection: View {
    let cards: [AccountPresentation]
    let now: TimeInterval
    let mode: DisplayCurrency
    let quote: ExchangeQuote?
    var open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(cards) { card in
                let windows = card.currentQuotas(at: now)
                Button { open(card.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(card.title).font(VG.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if card.account == nil {
                                Image(systemName: "questionmark.circle").font(VG.caption).foregroundStyle(.secondary)
                                    .help(L("账号未验证，未与其他设备合并", "Unverified account; not merged across devices"))
                            }
                            Spacer(minLength: 4)
                            if card.sources.count > 1 {
                                Label("\(Set(card.sources.map { UsageHistory.device(of: $0) ?? "local" }).count)", systemImage: "desktopcomputer")
                                    .font(VG.caption).foregroundStyle(.tertiary)
                            }
                            if windows.count > 2 { Text("+\(windows.count - 2)").font(VG.caption).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 14) {
                            ForEach(Array(windows.prefix(2))) { q in window(q) }
                            Spacer(minLength: 0)
                        }
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("account.row.\(card.id)")
                if card.id != cards.last?.id { Divider().opacity(0.45) }
            }
            if cards.isEmpty {
                Text(L("暂无账号额度", "No account quotas yet")).font(VG.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
    }
    private func window(_ q: AccountQuotaObservation) -> some View {
        let fresh = q.trusted && now - q.capturedAt <= 600 && q.capturedAt <= now + 60
        return HStack(spacing: 4) {
            Text((q.pool.contains(":") ? String(q.pool.split(separator: ":").last ?? "") + " " : "")
                 + (q.window == "week" ? L("周", "Week") : q.window)).foregroundStyle(.secondary).lineLimit(1)
            MiniProgressBar(value: q.usedPercent / 100, color: fresh ? VG.heat(Int(q.usedPercent)) : .secondary, width: 20, height: 3)
                .accessibilityHidden(true)
            Text(AccountPresentation.percent(q.usedPercent)).lineLimit(1).monospacedDigit().foregroundStyle(fresh ? VG.heat(Int(q.usedPercent)) : .secondary)
            if !fresh { Image(systemName: "clock").foregroundStyle(.tertiary) }
            if let reset = QuotaPresentation.compactReset(to: q.resetAt, now: now) {
                Text(reset).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Text(L("重置未知", "Reset ?")).foregroundStyle(.tertiary)
            }
        }
        .font(VG.caption)
        .help(q.pool + " · " + L("已用", "used") + String(format: " %.1f%%", q.usedPercent) + " · " + (QuotaPresentation.compactReset(to: q.resetAt, now: now) ?? L("重置未知", "Reset unknown")))
    }
}

struct AccountDetailView: View {
    let card: AccountPresentation
    let points: [AccountUsagePoint]
    let coverageStart: TimeInterval?
    let capturedAt: TimeInterval
    @State private var cycles: [AccountCycleUsage] = []
    let now: TimeInterval
    let mode: DisplayCurrency
    let quote: ExchangeQuote?

    private func money(_ totals: AccountUsageTotals) -> String {
        MoneyDisplay.format(totals.equivalentCostByCurrency, mode: mode, quote: quote).text
    }
    private var current: [AccountCycleUsage] { cycles.filter { $0.observation.resetAt.map { now < $0 } ?? true } }
    private var ended: [AccountCycleUsage] { cycles.filter { $0.observation.resetAt.map { now >= $0 } ?? false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !current.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Text(L("当前额度周期", "Current quota periods")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                        VGInfoButton(title: L("这些数字怎么来的", "How these are calculated"),
                                     text: L("百分比是官方额度已用多少。金额是这个周期里你的 token 按 API 官方价折算的“等价花费”，不是实际扣款。满额价值 = 已花 ÷ 已用百分比，例如花了 $120 用掉 30%，整个额度约值 $400；只有从周期开始就完整记录、读数是最新的时候才算。",
                                             "The percentage is how much of the official quota is used. The amount is your tokens this period valued at public API prices — an equivalent, not a charge. Full value = spent ÷ percent used (e.g. $120 at 30% ≈ $400 for the whole quota); shown only when the whole period was recorded and the reading is fresh."))
                    }
                    ForEach(current) { cycle in cycleRow(cycle) }
                }
            }
            if !ended.isEmpty {
                DisclosureGroup(L("已结束的周期（\(ended.count)）", "Finished periods (\(ended.count))")) {
                    VStack(spacing: 10) { ForEach(ended) { cycle in cycleRow(cycle) } }.padding(.top, 8)
                }.font(VG.body).tint(.secondary)
            }
            if let usage = card.usage, usage.byOrigin.count > 1 {
                DisclosureGroup(L("按数据来源拆分", "Split by data source")) {
                    ForEach(usage.byOrigin.keys.sorted(), id: \.self) { origin in
                        HStack { Text(origin == "cli" ? L("设备日志", "Device logs") : origin.uppercased()); Spacer(); Text(money(usage.byOrigin[origin]!)).monospacedDigit() }.font(VG.callout)
                    }
                }.font(VG.body).tint(.secondary)
            }
            if let usage = card.usage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(L("各设备用了多少（累计）", "Usage by device (all time)")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                        VGInfoButton(title: L("设备记录", "Device observations"), text: L("各设备保留原始观测；账号累计按可确认的真实请求 ID 去重。", "Device details keep each device's observations; account totals deduplicate confirmed genuine request IDs."))
                    }
                    ForEach(usage.bySource.keys.sorted(), id: \.self) { source in
                        if let totals = usage.bySource[source] {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(AccountPresentation.sourceLabel(source)).font(VG.body).lineLimit(1).truncationMode(.middle)
                                    Text("\(formatTokens(totals.usage.tokenTotal)) token").font(VG.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(money(totals)).font(VG.callout).monospacedDigit().multilineTextAlignment(.trailing)
                            }.padding(.vertical, 4).help(source)
                        }
                    }
                }
            }
        }
        .task(id: card.id + ":" + String(capturedAt) + ":" + String(card.quotas.map(\.capturedAt).max() ?? 0)) {
            let quotas = card.quotas, allPoints = points, start = coverageStart, time = now, account = card.account
            let result = await Task.detached(priority: .utility) {
                // Only this account's points (and unassigned ones, which the boundary checks need) — not all 77k.
                let relevant = allPoints.filter { $0.account == nil || $0.account == account }
                return quotas.map { AccountUsage.cycle(observation: $0, points: relevant, coverageStart: start, now: time) }
                    .sorted { ($0.observation.resetAt ?? 0) > ($1.observation.resetAt ?? 0) }
            }.value
            if !Task.isCancelled { cycles = AccountPresentation.distinctCycles(result) }
        }
    }
    private var header: some View {
        let tool = card.title.components(separatedBy: " · ").first ?? card.title
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                BrandTag(tool: tool)
                Text(L("这个账号累计用了", "This account has used")).font(VG.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(card.usage.map { money($0.totals) } ?? "—").font(.system(size: 24 * VG.scale, weight: .bold, design: .rounded))
                .monospacedDigit().textSelection(.enabled)
            if let totals = card.usage?.totals {
                Text(L("\(formatTokens(totals.usage.tokenTotal)) token · \(totals.requests) 次请求", "\(formatTokens(totals.usage.tokenTotal)) tokens · \(totals.requests) requests")
                     + (card.usage.map { L(" · 自 \(day($0.firstObservedAt)) 起", " · since \(day($0.firstObservedAt))") } ?? ""))
                    .font(VG.caption).foregroundStyle(.secondary)
                Text(L("按 API 官方价折算，不是实际扣款", "Valued at public API prices; not an actual charge")
                     + (totals.unpricedRequests > 0 ? L("；\(totals.unpricedRequests) 次请求的模型没有价格，未计入", "; \(totals.unpricedRequests) requests have no price and are excluded") : ""))
                    .font(.system(size: 10 * VG.scale)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if card.account == nil { Text(L("账号未验证：只显示这台设备自己的记录", "Unverified account: this device’s records only")).font(VG.caption).foregroundStyle(.orange) }
        }
        .glassTile(tint: Brand.color(tool))
    }

    private func cycleRow(_ cycle: AccountCycleUsage) -> some View {
        let q = cycle.observation
        let active = q.resetAt.map { now < $0 } ?? false
        let fresh = q.trusted && now - q.capturedAt <= 600 && q.capturedAt <= now + 60
        let capacity = active && fresh ? cycle.capacityUSD : nil
        let windowName = q.window == "week" ? L("每周额度", "Weekly quota") : q.window == "5h" ? L("5 小时额度", "5-hour quota") : q.window
        let why: String = {
            if capacity != nil { return "" }
            if q.resetAt == nil { return L("不知道何时重置，估不出满额价值", "Reset time unknown, so the full value can’t be estimated") }
            if !active { return L("这个周期已结束", "This period has ended") }
            if !fresh { return L("额度读数 \(UIFormat.agoShort(max(0, Int(now - q.capturedAt))))未更新，暂不估满额价值", "Quota reading is \(UIFormat.agoShort(max(0, Int(now - q.capturedAt)))) old; full value not estimated") }
            return L("这个周期开始时还没在记录，下个周期起能估出满额价值", "Recording started mid-period; the full value is available from the next period")
        }()
        let tint = fresh ? VG.heat(Int(q.usedPercent)) : Color.secondary
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RingGauge(value: q.usedPercent / 100, tint: tint, lineWidth: 5)
                Text(AccountPresentation.percent(q.usedPercent)).font(.system(size: 11 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 46 * VG.scale, height: 46 * VG.scale)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(windowName).font(VG.font(13, .semibold))
                    Spacer(minLength: 4)
                    Text(active ? (QuotaPresentation.compactReset(to: q.resetAt, now: now).map { L("\($0)后重置", "resets in \($0)") } ?? "") : L("已结束", "Ended"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                Text(cycle.coverage == "unknown" ? L("这个周期的花费还没有记录", "No spend recorded for this period yet")
                     : L("这个周期用了约 ", "Used about ") + money(cycle.consumed) + L("（API 等价）", " this period (API equivalent)"))
                    .font(VG.callout).fixedSize(horizontal: false, vertical: true)
                if let capacity {
                    Text(L("整个额度约值 ", "Whole quota is worth about ") + MoneyDisplay.format(["USD": capacity], mode: mode, quote: quote).text)
                        .font(VG.callout.weight(.semibold)).foregroundStyle(Glass.money)
                } else {
                    Text(why).font(.system(size: 10 * VG.scale)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help((q.startedAt.map(date) ?? "?") + " → " + (q.resetAt.map(date) ?? "?") + "\n" + L("读数来自 ", "Reading from ") + AccountPresentation.sourceLabel(q.source) + " · " + date(q.capturedAt))
    }
    private func day(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter(); formatter.locale = AppLanguage.current.locale; formatter.dateFormat = "M/d"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    private func date(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter(); formatter.locale = AppLanguage.current.locale; formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
