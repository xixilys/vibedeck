import SwiftUI

/// Pure presentation decisions shared by the overview and its focused checks.
/// No currency fallback, clock reads, or persisted state is hidden inside these helpers.
enum OverviewMetricPresentation {
    static func isCurrentDay(capturedAt: TimeInterval, now: TimeInterval, calendar: Calendar = .current) -> Bool {
        capturedAt.isFinite && now.isFinite && capturedAt > 0 && capturedAt <= now + 60
            && calendar.isDate(Date(timeIntervalSince1970: capturedAt), inSameDayAs: Date(timeIntervalSince1970: now))
    }

    static func hourly(_ values: [String: [Double]], through hour: Int,
                       convert: ([String: Double]) -> Double?) -> [Double] {
        guard !values.isEmpty, (0..<24).contains(hour),
              values.values.allSatisfy({ $0.count == 24 && $0.allSatisfy(\.isFinite) }) else { return [] }
        var result: [Double] = []
        for index in 0...hour {
            guard let amount = convert(values.mapValues { $0[index] }), amount.isFinite else { return [] }
            result.append(amount)
        }
        return result
    }

    static func moneyRows(_ costs: [String: Double], target: String?,
                          convert: ([String: Double], String) -> Double?) -> [(currency: String, amount: Double)] {
        guard !costs.isEmpty, costs.values.allSatisfy(\.isFinite) else { return [] }
        if let target, let amount = convert(costs, target), amount.isFinite { return [(target, amount)] }
        return costs.keys.sorted().map { ($0, costs[$0]!) }
    }

    static func latestKind<Sample>(_ samples: [Sample], kind: (Sample) -> String,
                                   timestamp: (Sample) -> TimeInterval) -> (kind: String, samples: [Sample])? {
        let grouped = Dictionary(grouping: samples, by: kind)
        let keys = grouped.keys.sorted {
            let a = grouped[$0]?.map(timestamp).max() ?? 0
            let b = grouped[$1]?.map(timestamp).max() ?? 0
            return a == b ? $0 < $1 : a > b
        }
        guard let key = keys.first else { return nil }
        return (key, grouped[key] ?? [])
    }

    static func selfTest() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now: TimeInterval = 1_792_670_400 // Fixed clock; calendar relation matters, not the live date.
        precondition(isCurrentDay(capturedAt: now - 60, now: now, calendar: calendar))
        precondition(!isCurrentDay(capturedAt: now - 86_400, now: now, calendar: calendar))
        precondition(!isCurrentDay(capturedAt: now + 120, now: now, calendar: calendar))
        let usd = Array(repeating: 2.0, count: 24), cny = Array(repeating: 7.0, count: 24)
        precondition(hourly(["USD": usd], through: 3) { $0["USD"] } == [2, 2, 2, 2])
        precondition(hourly(["CNY": cny], through: 3) { _ in nil }.isEmpty)
        precondition(hourly(["USD": usd, "CNY": cny], through: 3) { _ in nil }.isEmpty)
        precondition(hourly(["USD": [2]], through: 3) { $0["USD"] }.isEmpty)
        precondition(hourly(["USD": usd], through: 24) { $0["USD"] }.isEmpty)
        precondition(hourly(["USD": usd], through: 3) { _ in .nan }.isEmpty)
        let unconverted = moneyRows(["CNY": 14], target: "USD") { _, _ in nil }
        precondition(unconverted.count == 1 && unconverted[0].currency == "CNY" && unconverted[0].amount == 14)
        let mixed = moneyRows(["USD": 3, "CNY": 7], target: "USD") { _, _ in nil }
        precondition(mixed.count == 2 && mixed.map(\.amount).reduce(0, +) == 10)
        let converted = moneyRows(["USD": 3, "CNY": 7], target: "USD") { _, _ in 4 }
        precondition(converted.count == 1 && converted[0].currency == "USD" && converted[0].amount == 4)
        struct Sample { var kind: String; var timestamp: Double; var ms: Double }
        let samples = [Sample(kind: "Claude", timestamp: 10, ms: 9000), Sample(kind: "opencode", timestamp: 20, ms: 100), Sample(kind: "Claude", timestamp: 5, ms: 8000)]
        let chosen = latestKind(samples, kind: { $0.kind }, timestamp: { $0.timestamp })!
        precondition(chosen.kind == "opencode" && chosen.samples.count == 1 && chosen.samples[0].ms == 100)
        precondition(latestKind([Sample](), kind: { $0.kind }, timestamp: { $0.timestamp }) == nil)
    }
}

/// Today's API-equivalent spend and its hourly trend occupy separate, readable tracks.
/// Uses the pre-aggregated ledger; unavailable conversion never becomes a zero-valued curve.
struct TodayHeroTile<Controls: View>: View {
    let snapshot: UsageHistory.Snapshot
    let scope: DeviceScope
    let hosts: [String]
    let now: TimeInterval
    let mode: DisplayCurrency
    let quote: ExchangeQuote?
    var openStats: () -> Void
    var openLive: () -> Void
    @ViewBuilder var controls: () -> Controls

    private func included(_ source: String) -> Bool {
        !UsageHistory.isProxySource(source) && DeviceScope.includes(source: source, scope: scope, hosts: hosts)
    }

    private var today: AccountUsageTotals {
        snapshot.accountUsage.todayBySource.filter { included($0.key) }.values.reduce(into: AccountUsageTotals()) { total, value in
            total.usage.add(value.usage); total.requests += value.requests; total.unpricedRequests += value.unpricedRequests
            for (currency, cost) in value.equivalentCostByCurrency { total.equivalentCostByCurrency[currency, default: 0] += cost }
        }
    }

    private var currentDay: Bool {
        OverviewMetricPresentation.isCurrentDay(capturedAt: snapshot.capturedAt, now: now)
    }

    /// Only draw a shared scale when all amounts have the same display currency.
    private func hourly(target: String?, only: String? = nil) -> [Double] {
        guard currentDay, let target else { return [] }
        var byCurrency: [String: [Double]] = [:]
        for (source, perCurrency) in snapshot.accountUsage.todayHourlyBySource where included(source) {
            for (currency, values) in perCurrency where only == nil || currency == only {
                guard values.count == 24 else { return [] }
                var sum = byCurrency[currency] ?? Array(repeating: 0, count: 24)
                for index in 0..<24 { sum[index] += values[index] }
                byCurrency[currency] = sum
            }
        }
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: now))
        return OverviewMetricPresentation.hourly(byCurrency, through: hour) {
            MoneyDisplay.convertedValue($0, to: target, quote: quote, at: now)
        }
    }

    var body: some View {
        let totals = today
        let cost = MoneyDisplay.format(totals.equivalentCostByCurrency, mode: mode, quote: quote, at: now)
        let mixed = currentDay && (mode == .original || cost.conversionUnavailable) && totals.equivalentCostByCurrency.count > 1
        // Mixed originals (e.g. a small CNY DSH amount next to USD subscriptions): the dominant currency keeps the
        // hero figure, curve and share bar; the rest become a labelled "+ CNY 1.97" line. Nothing is converted.
        let primary = mixed ? Self.primaryCurrency(totals.equivalentCostByCurrency) : nil
        let target = mixed ? primary : ((mode == .original || cost.conversionUnavailable) ? totals.equivalentCostByCurrency.keys.first : mode.code)
        let curve = hourly(target: target, only: primary)
        let shares = currentDay ? TodayBreakdown.shares(snapshot, scope: scope, hosts: hosts, target: target, quote: quote, now: now) : []
        let barShares = shares.filter { $0.currency == (target ?? $0.currency) && $0.amount > 0 }
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(L("今日 · API 等价", "Today · API equivalent")).font(VG.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 4)
                    controls()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("今日 · API 等价", "Today · API equivalent")).font(VG.caption).foregroundStyle(.secondary)
                    HStack { Spacer(minLength: 0); controls() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    todayFigure(totals: totals, cost: cost, primary: primary).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    toolBreakdown(shares)
                }
                VStack(alignment: .leading, spacing: 7) {
                    todayFigure(totals: totals, cost: cost, primary: primary)
                    toolBreakdown(shares).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if curve.count > 1, let target {
                Sparkline(values: curve, tint: Glass.money, lineWidth: 1.3)
                    .frame(height: 26)
                    .clipped()
                    .help(L("今日每小时的 API 等价花费（\(target)，0 点 → 现在）", "Hourly API-equivalent spend (\(target), midnight → now)"))
            }
            if barShares.count > 1 {
                SegmentBar(parts: barShares.map { .init(id: Brand.name($0.tool), value: $0.amount, tint: Brand.color($0.tool)) }, height: 5)
            }
        }
        .glassTile(tint: Glass.money, padding: 12)
    }

    /// USD first when present (subscriptions are priced in it), otherwise the largest original amount.
    static func primaryCurrency(_ costs: [String: Double]) -> String? {
        costs.keys.sorted { a, b in
            if (a == "USD") != (b == "USD") { return a == "USD" }
            return (costs[a] ?? 0) == (costs[b] ?? 0) ? a < b : (costs[a] ?? 0) > (costs[b] ?? 0)
        }.first
    }

    private func todayFigure(totals: AccountUsageTotals, cost: MoneyDisplay.Presentation, primary: String?) -> some View {
        Button(action: openStats) {
            VStack(alignment: .leading, spacing: 2) {
                if let primary, let amount = totals.equivalentCostByCurrency[primary] {
                    moneyHero(MoneyDisplay.amount(amount, currency: primary))
                    let others = totals.equivalentCostByCurrency.keys.filter { $0 != primary }.sorted()
                        .map { "+ " + MoneyDisplay.amount(totals.equivalentCostByCurrency[$0]!, currency: $0) }
                    Text(others.joined(separator: "  ")).font(VG.font(11, .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(L("不同币种分开显示，未做换算", "Other currencies stay separate; nothing is converted"))
                } else {
                    moneyHero(currentDay ? cost.text : "—")
                }
                Text(currentDay ? L("\(formatTokens(totals.usage.tokenTotal)) token · \(totals.requests) 次", "\(formatTokens(totals.usage.tokenTotal)) tokens · \(totals.requests) req")
                     : L("等待今日记录", "Waiting for today"))
                    .font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(GlassActionStyle()).accessibilityIdentifier("summary.today")
        .accessibilityLabel(L("查看今日用量统计", "Open today’s usage statistics"))
        .accessibilityValue(currentDay ? cost.text + ", " + formatTokens(totals.usage.tokenTotal) + " tokens" : L("等待今日记录", "Waiting for today"))
        .help(L("今日 API 等价用量，不是订阅实付账单。点击查看统计。", "Today’s API-equivalent usage, not subscription charges. Open statistics.") + (cost.detail.isEmpty ? "" : "\n" + cost.detail)
              + (totals.unpricedRequests > 0 ? "\n" + L("\(totals.unpricedRequests) 次请求未定价", "\(totals.unpricedRequests) requests unpriced") : ""))
    }

    private func toolBreakdown(_ shares: [ToolShare]) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(shares.prefix(4))) { share in
                HStack(spacing: 5) {
                    Circle().fill(Brand.color(share.tool)).frame(width: 6, height: 6)
                    Text(Brand.name(share.tool)).font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(MoneyDisplay.amount(share.amount, currency: share.currency)).font(VG.font(11, .semibold)).monospacedDigit().lineLimit(1)
                }
                .help(L("\(Brand.name(share.tool)) 今日 \(formatTokens(share.tokens)) token", "\(Brand.name(share.tool)) today: \(formatTokens(share.tokens)) tokens"))
            }
            if shares.isEmpty {
                Text(currentDay ? L("暂无已定价用量", "No priced usage yet") : L("等待今日记录", "Waiting for today")).font(VG.caption).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }

    /// "USD 110.99" → small code + large gradient figure.
    @ViewBuilder
    private func moneyHero(_ text: String) -> some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].count <= 4, parts[0].allSatisfy({ $0.isLetter || $0 == "≈" }) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts[0]).font(VG.font(11, .semibold)).foregroundStyle(.secondary)
                Text(parts[1]).font(.system(size: 30 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [Glass.money, Glass.moneyEnd], startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1).minimumScaleFactor(0.9)
            }
        } else {
            Text(text).font(.system(size: 22 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
        }
    }
}

/// Compact machine entry on the overview. The System page owns the full instruments; this row only answers
/// "is the machine busy or hot right now" and opens System. `openNetwork` is kept for call-site compatibility.
struct VitalsStrip: View {
    @ObservedObject var monitor = SystemMonitor.shared
    var openSystem: () -> Void
    var openNetwork: () -> Void = {}

    var body: some View {
        let s = monitor.latest
        // Hottest core matches what Smart cooling steers by; fall back to the mean on models without per-core sensors.
        let hottest = s.cpuTempMax ?? s.cpuTemp
        Button(action: openSystem) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    reading(symbol: "cpu", tint: Glass.load(s.cpu), title: "CPU", value: SystemFormat.percent(s.cpu))
                    if hottest != nil {
                        reading(symbol: "thermometer.medium", tint: Glass.thermal(hottest),
                                title: s.cpuTempMax != nil ? L("最热", "Hottest") : L("温度", "Temp"),
                                value: SystemFormat.temperature(hottest))
                    }
                    reading(symbol: "memorychip", tint: s.memPressure >= 4 ? .red : s.memPressure >= 2 ? .orange : Glass.memory,
                            title: L("内存", "Memory"), value: SystemFormat.percent(s.memFraction))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10 * VG.scale, weight: .semibold)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        reading(symbol: "cpu", tint: Glass.load(s.cpu), title: "CPU", value: SystemFormat.percent(s.cpu))
                        if hottest != nil {
                            reading(symbol: "thermometer.medium", tint: Glass.thermal(hottest),
                                    title: s.cpuTempMax != nil ? L("最热", "Hottest") : L("温度", "Temp"), value: SystemFormat.temperature(hottest))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    reading(symbol: "memorychip", tint: s.memPressure >= 4 ? .red : s.memPressure >= 2 ? .orange : Glass.memory, title: L("内存", "Memory"), value: SystemFormat.percent(s.memFraction))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassActionStyle(radius: 11))
        .accessibilityIdentifier("vitals.cpu")
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("打开系统页", "Opens System"))
        .help(L("打开系统页查看 CPU、GPU、内存、温度与风扇", "Open System for CPU, GPU, memory, temperature and fans"))
    }

    private func reading(symbol: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10 * VG.scale, weight: .semibold)).foregroundStyle(tint)
            Text(title).foregroundStyle(.secondary)
            Text(value).font(VG.font(12, .semibold)).monospacedDigit()
        }
        .font(VG.caption).lineLimit(1).fixedSize()
    }
}

/// One quota pool per paired gauge: week is always outer, 5h always inner.
/// Other pools/windows remain reachable through the account detail, never mixed into this pair.
enum AccountQuotaRingPresentation {
    struct Selection {
        var pool: String?
        var outer: AccountQuotaObservation?
        var inner: AccountQuotaObservation?
        var additionalCount: Int
        var shown: [AccountQuotaObservation] { [inner, outer].compactMap { $0 } }
        var needsPoolLabel: Bool { pool?.contains(":") == true }
    }

    static func select(_ windows: [AccountQuotaObservation]) -> Selection {
        let pools = Dictionary(grouping: windows, by: \.pool)
        let orderedPools = pools.keys.sorted {
            let a = $0.contains(":"), b = $1.contains(":")
            return a == b ? $0 < $1 : !a
        }
        guard let pool = orderedPools.first else {
            return Selection(pool: nil, outer: nil, inner: nil, additionalCount: 0)
        }
        let current = pools[pool] ?? []
        func newest(_ window: String) -> AccountQuotaObservation? {
            current.filter { $0.window == window }.sorted {
                if $0.trusted != $1.trusted { return $0.trusted }
                return $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt > $1.capturedAt
            }.first
        }
        let outer = newest("week"), inner = newest("5h")
        let shownIDs = Set([outer, inner].compactMap { $0?.id })
        return Selection(pool: pool, outer: outer, inner: inner,
                         additionalCount: windows.filter { !shownIDs.contains($0.id) }.count)
    }

    static func selfTest() {
        func q(_ pool: String, _ window: String, _ percent: Double) -> AccountQuotaObservation {
            AccountQuotaObservation(account: nil, source: "Codex", provider: "openai", pool: pool, window: window,
                                    resetAt: 300, capturedAt: 150, usedPercent: percent)
        }
        let five = q("codex", "5h", 0), week = q("codex", "week", 35)
        let secondaryFive = q("codex:secondary", "5h", 86), secondaryWeek = q("codex:secondary", "week", 92)
        let multiple = select([secondaryFive, five, week, secondaryWeek])
        precondition(multiple.pool == "codex" && multiple.inner?.usedPercent == 0 && multiple.outer?.usedPercent == 35)
        precondition(multiple.shown.count == 2 && multiple.additionalCount == 2 && !multiple.needsPoolLabel)
        let onlyFive = select([five])
        precondition(onlyFive.inner?.id == five.id && onlyFive.outer == nil && onlyFive.additionalCount == 0)
        let onlyWeek = select([week])
        precondition(onlyWeek.outer?.id == week.id && onlyWeek.inner == nil)
        let crossPool = select([five, secondaryWeek])
        precondition(crossPool.inner?.id == five.id && crossPool.outer == nil && crossPool.additionalCount == 1)
        let secondary = select([secondaryFive, secondaryWeek])
        precondition(secondary.needsPoolLabel && secondary.pool == "codex:secondary")
        precondition(secondary.outer?.pool == secondary.inner?.pool && secondary.additionalCount == 0)
        let loneSecondary = select([secondaryFive])
        precondition(loneSecondary.needsPoolLabel && loneSecondary.outer == nil && loneSecondary.inner != nil)
        let zeros = select([q("codex", "5h", 0), q("codex", "week", 0)])
        precondition(zeros.inner?.usedPercent == 0 && zeros.outer?.usedPercent == 0 && zeros.shown.count == 2)
        let noSamples = select([])
        precondition(noSamples.pool == nil && noSamples.outer == nil && noSamples.inner == nil && noSamples.additionalCount == 0)
    }
}

/// Account quotas as a two-column grid of tiles. Outer ring = week, inner ring = 5h, from one pool.
struct AccountQuotaGrid: View {
    let cards: [AccountPresentation]
    let now: TimeInterval
    /// Recent quota holders whose sign-in is not confirmed right now; drawn dimmed with a "待确认" mark.
    var unconfirmedIDs: Set<String> = []
    /// Estimated full-quota value per card ("≈ $410 / wk"), already formatted in the display currency.
    var fullValue: [String: String] = [:]
    var open: (String) -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        if cards.isEmpty {
            Text(L("暂无已确认登录的账号", "No confirmed signed-in accounts")).font(VG.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        let pending = unconfirmedIDs.contains(card.id)
                        Button { open(card.id) } label: {
                            tile(card).opacity(pending ? 0.62 : 1)
                                .overlay(alignment: .topTrailing) {
                                    if pending {
                                        Image(systemName: "questionmark.circle").font(.system(size: 9 * VG.scale, weight: .semibold))
                                            .foregroundStyle(.secondary).padding(6)
                                            .help(L("最近 6 小时有额度记录，但此刻未确认登录（设备离线或尚未更新）", "Quota seen in the last 6 h, but sign-in not confirmed right now (device offline or not yet refreshed)"))
                                    }
                                }
                        }
                            .buttonStyle(GlassActionStyle()).accessibilityIdentifier("account.row.\(card.id)")
                            .accessibilityHint(L("打开账号额度详情", "Open account quota details"))
                            .accessibilityValue(pending ? L("登录待确认", "Sign-in unconfirmed") : "")
                    }
                }
            }
        }
    }

    private func fresh(_ q: AccountQuotaObservation) -> Bool {
        q.trusted && now - q.capturedAt <= 600 && q.capturedAt <= now + 60
    }

    private func tint(_ q: AccountQuotaObservation) -> Color { fresh(q) ? VG.heat(Int(q.usedPercent)) : .secondary }

    private func tile(_ card: AccountPresentation) -> some View {
        let selection = AccountQuotaRingPresentation.select(card.currentQuotas(at: now))
        let shown = selection.shown
        let outer = selection.outer, inner = selection.inner
        let parts = card.title.components(separatedBy: " · ")
        let tool = parts.first ?? card.title
        let label = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
        let devices = Set(card.sources.map { UsageHistory.device(of: $0) ?? "local" }).count
        return HStack(alignment: .center, spacing: 8) {
            ZStack {
                DualRing(outer: outer.map { $0.usedPercent / 100 }, inner: inner.map { $0.usedPercent / 100 },
                         outerTint: outer.map(tint) ?? .secondary, innerTint: inner.map(tint) ?? .secondary, size: 36 * VG.scale)
                Image(systemName: Self.symbol(tool)).font(.system(size: 9 * VG.scale, weight: .semibold)).foregroundStyle(Brand.color(tool))
            }
            .overlay(alignment: .bottomTrailing) {
                if devices > 1 {
                    Text("×\(devices)").font(.system(size: 11 * VG.scale, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Capsule().fill(Brand.color(tool)))
                        .offset(x: 4, y: 2)
                        .help(L("\(devices) 台设备同一账号，额度已合并", "Same account on \(devices) devices; quota merged"))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        BrandTag(tool: tool)
                        accountLabel(label.isEmpty ? tool : label, card: card).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        BrandTag(tool: tool)
                        accountLabel(label.isEmpty ? tool : label, card: card)
                    }
                }
                if selection.needsPoolLabel, let pool = selection.pool {
                    Text(AccountPresentation.poolLabel(pool)).font(VG.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(AccountPresentation.poolLabel(pool))
                }
                ForEach(shown) { q in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            quotaPercent(q)
                            resetLabel(q)
                        }.fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            quotaPercent(q)
                            resetLabel(q)
                        }
                    }
                    .font(VG.caption).monospacedDigit()
                    .help(q.pool + " · " + L("已用", "used") + String(format: " %.1f%%", q.usedPercent) + " · "
                          + (QuotaPresentation.compactReset(to: q.resetAt, now: now).map { L("重置 ", "resets ") + $0 } ?? L("重置未知", "Reset unknown"))
                          + (fresh(q) ? "" : "\n" + L("旧采样", "Older sample")))
                }
                if shown.isEmpty {
                    Text(card.planTitle == nil ? L("额度 —", "Quota —") : L("额度暂不可读", "Quota not readable"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                if let value = fullValue[card.id] {
                    HStack(spacing: 2) {
                        Image(systemName: "equal.circle").font(.system(size: 8.5 * VG.scale, weight: .semibold))
                        Text(L("满额 ", "Full ") + value)
                    }
                    .font(VG.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    .help(L("按最近的用量折算：这段时间按 API 价花了多少 ÷ 额度涨了几个百分点。是估算，不是官方数字。",
                            "From recent usage: API-priced spend in this stretch ÷ the percentage points it used. An estimate, not an official figure."))
                }
                if selection.additionalCount > 0 {
                    Text(L("+\(selection.additionalCount) · 详情", "+\(selection.additionalCount) · Details"))
                        .font(VG.caption).foregroundStyle(.secondary)
                        .help(L("另有 \(selection.additionalCount) 个额度窗口，点击查看全部额度池", "\(selection.additionalCount) more quota windows; open details for all pools"))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .glassTile(tint: Brand.color(tool), padding: 7, radius: 12)
    }

    private func accountLabel(_ label: String, card: AccountPresentation) -> some View {
        HStack(spacing: 3) {
            Text(label).font(VG.font(12, .semibold)).lineLimit(1).truncationMode(.middle).help(card.title)
            if card.account == nil && card.planTitle == nil {
                Image(systemName: "questionmark.circle").font(VG.caption).foregroundStyle(.secondary)
                    .help(L("账号未验证，未与其他设备合并", "Unverified account; not merged across devices"))
            }
        }
    }

    private func quotaPercent(_ q: AccountQuotaObservation) -> some View {
        HStack(spacing: 3) {
            Text(q.window == "week" ? L("周", "Wk") : q.window).foregroundStyle(.secondary)
            Text(AccountPresentation.percent(q.usedPercent)).fontWeight(.semibold).foregroundStyle(tint(q))
        }
    }

    private func resetLabel(_ q: AccountQuotaObservation) -> some View {
        HStack(spacing: 3) {
            Text(QuotaPresentation.compactReset(to: q.resetAt, now: now) ?? "—").foregroundStyle(.secondary).lineLimit(1)
            if !fresh(q) { Image(systemName: "clock").foregroundStyle(.secondary) }
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Claude": return "sparkle"
        case "Codex": return "chevron.left.forwardslash.chevron.right"
        case "Grok": return "bolt"
        case "Gemini", "Antigravity": return "diamond"
        case "GLM": return "circle.hexagongrid"
        case "OpenCode", "opencode": return "terminal"
        default: return "person.crop.circle"
        }
    }
}

// MARK: - Brands

/// Provider identity shown wherever an account or tool appears, so "7b864e" is never a bare id.
enum Brand {
    static func color(_ tool: String) -> Color {
        switch tool.lowercased() {
        case "claude", "claude code", "anthropic": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex", "openai": return Color(red: 0.06, green: 0.64, blue: 0.50)
        case "deepseek", "dsh": return Color(red: 0.30, green: 0.42, blue: 1.0)
        case "opencode", "opencode go": return Color(red: 0.96, green: 0.62, blue: 0.14)
        case "grok", "xai": return Color.primary.opacity(0.78)
        case "cpa": return Color(red: 0.93, green: 0.36, blue: 0.55)
        case "gemini", "google": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "kimi", "moonshot": return Color(red: 0.55, green: 0.40, blue: 0.95)
        case "glm", "zhipu", "z.ai": return Color(red: 0.20, green: 0.55, blue: 0.95)
        default: return .secondary
        }
    }

    static func name(_ tool: String) -> String {
        switch tool.lowercased() {
        case "opencode": return "opencode"
        case "dsh": return "DSH"
        default: return tool
        }
    }
}

/// Small coloured provider label.
struct BrandTag: View {
    var tool: String
    var body: some View {
        let tint = Brand.color(tool)
        Text(Brand.name(tool))
            .font(VG.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.16)))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Today by tool

struct ToolShare: Identifiable {
    var id: String { tool + "\u{0}" + currency }
    var tool: String
    var amount: Double
    var currency: String
    var tokens: Int64
}

enum TodayBreakdown {
    /// Per-tool costs use a shared currency only when conversion succeeds; otherwise each original stays labelled.
    static func shares(_ snapshot: UsageHistory.Snapshot, scope: DeviceScope, hosts: [String], target: String?,
                       quote: ExchangeQuote?, now: TimeInterval) -> [ToolShare] {
        var byTool: [String: (costs: [String: Double], tokens: Int64)] = [:]
        for (source, totals) in snapshot.accountUsage.todayBySource
            where !UsageHistory.isProxySource(source) && DeviceScope.includes(source: source, scope: scope, hosts: hosts) {
            let tool = UsageHistory.cli(of: source)
            var entry = byTool[tool] ?? ([:], 0)
            for (currency, value) in totals.equivalentCostByCurrency { entry.costs[currency, default: 0] += value }
            entry.tokens += totals.usage.tokenTotal
            byTool[tool] = entry
        }
        return byTool.flatMap { tool, entry -> [ToolShare] in
            OverviewMetricPresentation.moneyRows(entry.costs, target: target) {
                MoneyDisplay.convertedValue($0, to: $1, quote: quote, at: now)
            }.map { ToolShare(tool: tool, amount: $0.amount, currency: $0.currency, tokens: entry.tokens) }
        }
        .filter { $0.amount > 0 || $0.tokens > 0 }
        .sorted {
            if $0.currency != $1.currency { return $0.currency < $1.currency }
            return $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }
    }
}

// MARK: - First token per device

/// One chip per device: native Codex first-token when there is one, otherwise a clearly labelled approximation
/// (Claude first response from logs, opencode stream start, or proxy first byte). Never pooled across kinds.
struct FirstTokenStrip: View {
    let snapshot: UsageHistory.Snapshot
    let hosts: [String]
    let now: TimeInterval
    var open: () -> Void

    struct Reading: Identifiable {
        var id: String
        var device: String
        var ms: Double?
        var basis: String
        var window: String
        var native: Bool
        /// Caption-width basis: the tool only; "≈" on the value marks approximations, the tooltip explains them.
        var short: String { ms == nil ? basis : native ? "Codex" : basis.components(separatedBy: " ").first ?? basis }
    }

    private func device(of source: String) -> String {
        if UsageHistory.isProxySource(source) { return "" }
        return UsageHistory.device(of: source) ?? ""
    }

    var readings: [Reading] {
        let devices = hosts.reduce(into: [""]) { if !$0.contains($1) { $0.append($1) } }
        return devices.map { key in
            let turns = snapshot.turnLatencies.filter { device(of: $0.source) == key }
            let proxy = snapshot.performance.filter { key.isEmpty && UsageHistory.isProxySource($0.source) }
            let name = key.isEmpty ? L("本机", "Local") : RemoteCollector.displayName(for: key)
            for (span, label) in [(3600.0, "1h"), (86_400.0, "24h")] {
                if let ms = PerformanceStats.turnTTFT(turns.filter { $0.isNativeFirstToken }, since: now - span, until: now) {
                    return Reading(id: key, device: name, ms: ms, basis: "Codex", window: label, native: true)
                }
                let approximate = turns.filter { !$0.isNativeFirstToken && $0.isSuccessfulSample && $0.timestamp >= now - span && $0.timestamp <= now }
                // Pick the most recent approximation kind before taking its median.
                if let group = OverviewMetricPresentation.latestKind(approximate, kind: { UsageHistory.cli(of: $0.source) }, timestamp: { $0.timestamp }),
                   let ms = PerformanceStats.turnTTFT(group.samples, since: now - span, until: now, includeApproximate: true) {
                    let tool = group.kind
                    return Reading(id: key, device: name, ms: ms, basis: tool == "Claude" ? L("Claude 首段", "Claude first reply") : L("\(tool) 首流", "\(tool) stream"),
                                   window: label, native: false)
                }
                if let ms = PerformanceStats.ttft(proxy.filter { $0.timestamp >= now - span && $0.timestamp <= now }) {
                    return Reading(id: key, device: name, ms: ms, basis: L("代理首字节", "Proxy first byte"), window: label, native: false)
                }
            }
            return Reading(id: key, device: name, ms: nil, basis: L("无样本", "No samples"), window: "", native: false)
        }
    }

    var body: some View {
        let rows = readings
        // One row of devices reads as a comparison; XL type falls back to two columns.
        let columns = VG.scale > 1.1 && rows.count > 2 ? 2 : min(4, max(1, rows.count))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 9 * VG.scale)).foregroundStyle(Glass.cpu)
                    Text(L("首字延迟 · 各设备 p50", "First token · p50 per device")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 7) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.device).font(VG.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                            Text((row.native || row.ms == nil ? "" : "≈") + PerformancePresentation.latency(row.ms))
                                .font(.system(size: 15 * VG.scale, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(row.ms == nil ? Color.secondary : Color.primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(row.window.isEmpty ? row.short : row.short + " · " + row.window)
                                .font(VG.caption).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(row.native ? L("Codex 记录的真实首 token 时间", "Codex’s own first-token time")
                              : row.basis + " · " + L("近似值：Claude 为提问到首条回复写入日志的时间；opencode 为开始流式输出的时间；代理为首字节时间。与 Codex 首 token 口径不同，不合并。",
                                  "Approximation: Claude = prompt to first logged reply; opencode = stream start; proxy = first byte. Different from Codex first-token and never pooled with it."))
                    }
                }
            }
            .glassTile(tint: Glass.cpu, padding: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassActionStyle())
        .accessibilityIdentifier("summary.ttft")
        .accessibilityHint(L("查看各设备的性能与采样详情", "Open device performance and sample details"))
    }
}

// MARK: - API balances & plans

/// API keys, balances and coding plans next to the subscription accounts. Each row says where its number came from.
/// A coding plan without a confirmed sign-in identity (Grok, GLM, Gemini): one row per plan, from the
/// device that captured its quota most recently.
struct PlanQuota: Identifiable {
    struct Bar: Hashable { var label: String; var used: Int; var reset: String? }
    var id: String
    var brand: String
    var title: String
    var detail: String
    var bars: [Bar]
    /// The runtime name to open for details, and its windows as quota observations for the ring tile.
    var runtimeName: String = ""
    var source: String = ""
    var observations: [AccountQuotaObservation] = []

    /// Ring-tile form, so subscription plans sit next to signed-in accounts instead of among API keys.
    var card: AccountPresentation {
        var card = AccountPresentation(id: "plan:" + id, account: nil, usage: nil, quotas: observations)
        card.planTitle = title
        card.signedInSources = [source]
        return card
    }

    static func collect(local: [DetectedLLMRuntime], remote: [String: [DetectedLLMRuntime]], now: TimeInterval) -> [PlanQuota] {
        let names = ["Grok": "Grok", "GLM": "GLM", "Gemini": "Gemini", "Antigravity": "Gemini"]
        var best: [String: (runtime: DetectedLLMRuntime, device: String, captured: TimeInterval, host: String?)] = [:]
        let candidates: [(DetectedLLMRuntime, String, String?)] = local.map { ($0, L("本机", "Local"), nil) }
            + remote.sorted { $0.key < $1.key }.flatMap { host, list in list.map { ($0, RemoteCollector.displayName(for: host), host) } }
        for (runtime, device, host) in candidates {
            guard let brand = names[runtime.name] else { continue }
            let key = brand + ":" + (runtime.planKey ?? "")
            let windows = [runtime.fiveHour, runtime.sevenDay, runtime.secondaryFiveHour, runtime.secondarySevenDay].compactMap { $0 }
            let captured = windows.compactMap(\.capturedAt).max() ?? (windows.isEmpty ? -1 : 0)
            if let current = best[key], current.captured >= captured { continue }
            best[key] = (runtime, device, captured, host)
        }
        return best.map { key, entry in
            let r = entry.runtime, brand = names[r.name] ?? r.name
            func bar(_ label: String, _ w: QuotaWindow?) -> Bar? {
                guard let w, !w.isExpired(now: now) else { return nil }
                return Bar(label: label, used: w.effectivePct(now: now), reset: UIFormat.countdown(to: w.resetsAt, now: now))
            }
            let secondary = r.secondaryPoolName.isEmpty ? "" : r.secondaryPoolName + " "
            let bars = [bar("5h", r.fiveHour), bar(L("周", "Week"), r.sevenDay),
                        bar(secondary + "5h", r.secondaryFiveHour), bar(secondary + L("周", "Week"), r.secondarySevenDay)].compactMap { $0 }
            let tier = ["已登录", "未登录", "Unknown", ""].contains(r.tier) ? "" : r.tier
            let title = brand + " · " + (tier.isEmpty ? (brand == "GLM" ? "Coding Plan" : L("订阅", "Plan")) : tier.replacingOccurrences(of: brand + " ", with: ""))
            let source = r.name + (entry.host.map { " · " + $0 } ?? "")
            let pool = brand.lowercased()
            func observation(_ w: QuotaWindow?, _ window: String, pool: String) -> AccountQuotaObservation? {
                guard let w, let captured = w.capturedAt, !w.isExpired(now: now) else { return nil }
                return AccountQuotaObservation(account: nil, source: source, provider: pool, pool: pool, window: window,
                    startedAt: w.windowSeconds > 0 ? w.resetsAt.map { $0 - w.windowSeconds } : nil, resetAt: w.resetsAt,
                    capturedAt: captured, usedPercent: w.accountingUsedPercent, trusted: now - captured <= 600,
                    baselineAt: w.baselineAt, baselinePercent: w.baselinePct.map(Double.init))
            }
            let secondaryPool = pool + ":" + r.secondaryPoolName.lowercased()
            let observations = [observation(r.fiveHour, "5h", pool: pool), observation(r.sevenDay, "week", pool: pool),
                                observation(r.secondaryFiveHour, "5h", pool: secondaryPool),
                                observation(r.secondarySevenDay, "week", pool: secondaryPool)].compactMap { $0 }
            var detail = entry.device
            if entry.captured > 0 { detail += " · " + UIFormat.agoShort(max(0, Int(now - entry.captured))) }
            if bars.isEmpty { detail = entry.device + " · " + L("额度暂不可读", "quota not readable") }
            return PlanQuota(id: key, brand: brand, title: title, detail: detail, bars: bars,
                             runtimeName: r.name, source: source, observations: observations)
        }.sorted { a, b in
            let order = ["Grok", "GLM", "Gemini"]
            return (order.firstIndex(of: a.brand) ?? 9, a.id) < (order.firstIndex(of: b.brand) ?? 9, b.id)
        }
    }
}

struct APIQuotaSection: View {
    let providers: [APIProviderStatus]
    let dshBalance: DSHUsage.Balance?
    var plans: [PlanQuota] = []
    let now: TimeInterval
    var openAPI: () -> Void

    struct Row: Identifiable {
        var id: String
        var brand: String
        var title: String
        var detail: String
        var value: String
        var fraction: Double?
        var bars: [PlanQuota.Bar] = []
    }

    private func brand(_ provider: String) -> String {
        let lower = provider.lowercased()
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("opencode") { return "opencode" }
        if lower.contains("kimi") || lower.contains("moonshot") { return "Kimi" }
        if lower.contains("glm") || lower.contains("zhipu") || lower.contains("z.ai") { return "GLM" }
        if lower.contains("openai") { return "OpenAI" }
        if lower.contains("anthropic") || lower.contains("claude") { return "Claude" }
        return provider
    }

    var rows: [Row] {
        var out: [Row] = []
        // Subscription plans are ring tiles above; a proxied key for the same plan would show it twice.
        let planBrands = Set(plans.filter { !$0.bars.isEmpty }.map(\.brand))
        if let balance = dshBalance {
            out.append(Row(id: "dsh", brand: "DeepSeek", title: "DeepSeek API",
                           detail: L("余额 · DSH 账本 ", "Balance · DSH ledger ") + UIFormat.agoShort(max(0, Int(now - balance.asOf))),
                           value: MoneyDisplay.amount(balance.amount, currency: balance.currency), fraction: nil))
        }
        for p in providers where !planBrands.contains(brand(p.provider)) {
            let window = p.monthly ?? p.sevenDay ?? p.fiveHour
            let value: String
            var detail = p.plan.isEmpty ? L("API Key", "API key") : p.plan
            if let window {
                value = "\(window.effectivePct(now: now))%"
                if let reset = UIFormat.countdown(to: window.resetsAt, now: now) { detail += " · " + L("重置 ", "resets ") + reset }
                if p.quotaIsEstimate { detail += " · " + L("估算", "est.") }
            } else if !p.balanceText.isEmpty {
                value = p.balanceText
            } else {
                value = L("\(p.calls) 次", "\(p.calls) req")
                detail += " · " + (p.quotaError.isEmpty ? L("无额度接口", "no quota API") : String(p.quotaError.prefix(18)))
            }
            out.append(Row(id: p.id, brand: brand(p.provider), title: p.provider, detail: detail, value: value,
                           fraction: window.map { Double($0.effectivePct(now: now)) / 100 }))
        }
        return out
    }

    var body: some View {
        let list = rows
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("API 与余额", "API & balances")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                VGInfoButton(title: L("API 与余额", "API & balances"),
                             text: L("Grok / GLM / Gemini 是订阅，显示在上方订阅卡里。DeepSeek 余额来自 DSH 记账插件最后一次读到的值。经本机记账代理的 API key / Coding Plan（如 GLM、Kimi、OpenCode Go）显示额度或调用数；没有用量接口的套餐可在 ~/.config/vibedeck/plans.json 填写上限，按请求数估算。",
                                     "Grok / GLM / Gemini are subscriptions and appear in the subscription tiles above. The DeepSeek balance is the value DSH’s cost meter last read. API keys and coding plans routed through the local proxy (GLM, Kimi, OpenCode Go…) show their quota or request count; plans without a usage API can be estimated from request counts via ~/.config/vibedeck/plans.json."))
                Spacer()
                Button(action: openAPI) {
                    HStack(spacing: 3) { Text(L("管理", "Manage")); Image(systemName: "chevron.right") }
                        .font(VG.caption).foregroundStyle(.secondary)
                }.buttonStyle(GlassActionStyle()).accessibilityIdentifier("api.manage")
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(list) { row in
                    HStack(spacing: 8) {
                        // One tag column so every row's text starts at the same x.
                        BrandTag(tool: row.brand).frame(width: 64 * VG.scale, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(VG.font(12, .medium)).lineLimit(2)
                            if !row.bars.isEmpty { PlanBars(bars: row.bars) }
                            Text(row.detail).font(VG.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if let fraction = row.fraction {
                            RingGauge(value: fraction, tint: VG.heat(Int(fraction * 100)), lineWidth: 3).frame(width: 16, height: 16)
                        }
                        if !row.value.isEmpty {
                            Text(row.value).font(VG.font(12, .semibold)).monospacedDigit().lineLimit(1).fixedSize().layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 5)
                    if row.id != list.last?.id { Divider().opacity(0.4) }
                }
                if list.isEmpty {
                    Text(L("还没有 API key 或套餐。经记账代理后会出现在这里。", "No API keys or plans yet. They appear here once routed through the proxy."))
                        .font(VG.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                }
            }
            .glassTile(tint: Brand.color("deepseek"), padding: 10)
        }
    }
}

/// Compact used-quota bars for one plan: "5h ▰▱ 3%  周 ▰▰ 24%".
struct PlanBars: View {
    var bars: [PlanQuota.Bar]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(bars, id: \.self) { bar in
                HStack(spacing: 4) {
                    Text(bar.label).font(VG.font(9.5, .medium)).foregroundStyle(.secondary)
                    MiniProgressBar(value: Double(bar.used) / 100, color: VG.heat(bar.used), width: 34, height: 4)
                    Text("\(bar.used)%").font(VG.font(9.5, .semibold)).monospacedDigit()
                }
                .help(bar.reset.map { L("重置 ", "Resets ") + $0 } ?? "")
            }
        }
    }
}
