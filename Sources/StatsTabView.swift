import SwiftUI
import Foundation

/// 统计页先显示今日费用与短趋势，其余分析按需展开。
/// 展示层只读快照；历史归并、定价、预测和日历归桶都在后台完成。
/// 传了 scope 就只显示当前设备的来源 —— 全部按只读副本裁剪，不改 snapshot 本身。
public struct StatsTabView: View {
    public let snapshot: UsageHistory.Snapshot
    public let scope: DeviceScope
    public let hosts: [String]
    @State private var selectedCurrency = ""
    /// Day key selected on the 14-day chart; the panel below shows that day instead of only totals.
    @State private var selectedDay: String?
    @State private var modelPeriod: ModelPeriod = .today
    @State private var showAllModels = false
    public init(snapshot: UsageHistory.Snapshot, scope: DeviceScope = .all, hosts: [String] = []) {
        self.snapshot = snapshot; self.scope = scope; self.hosts = hosts
    }

    private var scoped: Bool { scope != .all }
    private var remoteHost: String? { if case .remote(let host) = scope { return host }; return nil }
    private func allows(_ source: String) -> Bool { DeviceScope.includes(source: source, scope: scope, hosts: hosts) }
    private func counts(_ day: UsageHistory.Day) -> Bool {
        day.sources.contains { allows($0.key) && !UsageHistory.isProxySource($0.key) }
    }

    private var visibleTotals: [String: UsageHistory.Totals] {
        scoped ? snapshot.totals.filter { allows($0.key) } : snapshot.totals
    }
    private var visibleAggregate: UsageHistory.Totals {
        guard scoped else { return snapshot.aggregate }
        return visibleTotals.filter { !UsageHistory.isProxySource($0.key) }
            .values.reduce(into: UsageHistory.Totals()) { $0.merge($1) }
    }
    private var hasRecords: Bool { visibleAggregate.turns > 0 }
    private var dailyTokens: [String: Int64] {
        guard scoped else { return snapshot.dailyTokens }
        var out: [String: Int64] = [:]
        for day in snapshot.days where counts(day) {
            out[day.date] = day.sources.filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }
                .values.reduce(Int64(0)) { $0 + $1.tokenTotal }
        }
        return out
    }
    private var activeDays: Int { dailyTokens.values.filter { $0 > 0 }.count }
    private var costBySource: [String: [String: Double]] {
        scoped ? snapshot.costBySource.filter { allows($0.key) } : snapshot.costBySource
    }
    private var costByCurrency: [String: Double] {
        var out: [String: Double] = [:]
        for (source, perCurrency) in costBySource where !UsageHistory.isProxySource(source) {
            for (currency, value) in perCurrency { out[currency, default: 0] += value }
        }
        return out
    }
    /// The account ledger values today's usage at API-equivalent rates, including subscription calls.
    /// Each source has already selected one accounting origin; proxy copies stay excluded here.
    private var todayEquivalent: AccountUsageTotals {
        snapshot.accountUsage.todayBySource.filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }
            .values.reduce(into: AccountUsageTotals()) { result, value in
                result.usage.add(value.usage)
                result.requests += value.requests
                result.unpricedRequests += value.unpricedRequests
                for (currency, cost) in value.equivalentCostByCurrency {
                    result.equivalentCostByCurrency[currency, default: 0] += cost
                }
            }
    }
    private var unpricedBySource: [String: Int] {
        scoped ? snapshot.unpricedBySource.filter { allows($0.key) } : snapshot.unpricedBySource
    }
    private var unpricedNames: Set<String> {
        Set(snapshot.unpricedNamesBySource.filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }.values.flatMap { $0 })
    }
    private var forecasts: [String: CostForecast] {
        scoped ? snapshot.forecastsByDevice[scope.key] ?? [:] : snapshot.forecasts
    }
    private var forecast: CostForecast? {
        if let selected = forecasts[selectedCurrency] { return selected }
        let withData = forecasts.filter { $0.value.hasData }
        let candidates = withData.isEmpty ? forecasts : withData
        return candidates["USD"] ?? candidates["CNY"] ?? candidates.keys.sorted().first.flatMap { candidates[$0] }
    }
    private var dailyCost: [String: Double] {
        let currency = forecast?.currency ?? snapshot.primaryCurrency
        if scoped { return snapshot.dailyCostByDevice[scope.key]?[currency] ?? [:] }
        return snapshot.dailyCostByDevice.values.reduce(into: [String: Double]()) { result, perCurrency in
            for (day, cost) in perCurrency[currency] ?? [:] { result[day, default: 0] += cost }
        }
    }
    private var earliestDate: String? {
        guard scoped else { return snapshot.earliestDate }
        return snapshot.days.first { counts($0) }?.date
    }
    private var cacheHitRate: Double? {
        let a = visibleAggregate
        return a.ctx > 0 ? Double(a.cacheRead) / Double(a.ctx) : nil
    }
    /// 设备分组后的来源：本机在前，远程 / 挂载设备按名字排。
    private var sources: [String] {
        var keys = Set(visibleTotals.keys)
        if let host = remoteHost {
            for cli in ["Claude", "Codex", "OpenCode"] { keys.insert("\(cli) · \(host)") }
        } else {
            keys.formUnion(["Claude", "Codex"].filter { allows($0) })
        }
        let order = ["Claude", "Codex", "OpenCode"]
        return keys.filter { allows($0) }.sorted { a, b in
            let da = UsageHistory.device(of: a) ?? "", db = UsageHistory.device(of: b) ?? ""
            if da != db { return da < db }
            let pa = UsageHistory.isProxySource(a), pb = UsageHistory.isProxySource(b)
            if pa != pb { return !pa }
            let ia = order.firstIndex(of: UsageHistory.cli(of: a)) ?? 9, ib = order.firstIndex(of: UsageHistory.cli(of: b)) ?? 9
            return ia != ib ? ia < ib : a < b
        }
    }
    private var days: [Date] {
        let cal = Calendar.current, today = Calendar.current.startOfDay(for: Date())
        return (0..<42).map { cal.date(byAdding: .day, value: $0 - 41, to: today)! }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isScanning && snapshot.capturedAt == 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在汇总历史（\(snapshot.processedFiles)/\(snapshot.totalFiles) 个文件）…", "Summarizing history (\(snapshot.processedFiles)/\(snapshot.totalFiles) files)…")).font(VG.caption).foregroundStyle(.secondary)
                }
            }
            if !snapshot.error.isEmpty {
                Label(diagnosticText(snapshot.error), systemImage: "exclamationmark.triangle.fill")
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(snapshot.error)
            }
            trendTile
            modelsTile
            sourcesTile
            heatmap
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    todayCard
                    forecastCard
                    if let f = forecast { spendingForecast(f) }
                }.padding(.top, 6)
            } label: {
                Text(L("今日与预测 · 原记录", "Today & forecast · original records")).font(VG.body)
            }
            .tint(.secondary)
            .accessibilityIdentifier("stats.cost-trends")
            metrics
            modelPerformance
            if remoteHost == nil, let block = snapshot.claudeBlock, block.isActive {
                DisclosureGroup {
                    blockCard(block).padding(.top, 6)
                } label: {
                    HStack {
                        Text(L("Claude · 当前 5 小时块", "Claude · current 5-hour block"))
                        Spacer(minLength: 8)
                        Text(Fmt.money(block.cost, block.currency)).monospacedDigit()
                    }
                    .font(VG.body)
                }
                .tint(.secondary)
                .accessibilityIdentifier("stats.claude-block")
            }
            DisclosureGroup {
                VStack(spacing: 10) {
                    distribution
                    footnotes
                }
                .padding(.top, 6)
            } label: {
                Text(L("token 构成与口径", "Token breakdown & notes"))
                    .font(VG.body)
            }
            .tint(.secondary)
            .accessibilityIdentifier("stats.history")
            providers
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 可视化总览

    private static let palette: [Color] = [Glass.money, Glass.gpu, Glass.download, Glass.memory, Glass.latency, Glass.compressed]

    private var chartCurrency: String { forecast?.currency ?? snapshot.primaryCurrency }

    private var trendTile: some View {
        let f = forecast
        let values = f?.recentCosts ?? []
        let keys = f?.recentDays ?? []
        let currency = chartCurrency
        let total = values.reduce(0, +)
        let selected = selectedDay.flatMap { day in keys.firstIndex(of: day) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("近 14 天花费", "Last 14 days")).font(VG.caption).foregroundStyle(.secondary)
                Spacer()
                if let f, f.monthSoFar > 0 {
                    Text(L("本月 ", "Month ") + Fmt.money(f.monthSoFar, currency)).font(VG.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(values.isEmpty ? "—" : Fmt.money(total, currency))
                    .font(.system(size: 24 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [Glass.moneyEnd, Glass.money], startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let f, f.dailyAverage > 0 {
                    Text(L("日均 ", "avg ") + Fmt.money(f.dailyAverage, currency)).font(VG.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if let f {
                    // Yesterday is one click away instead of being hidden behind the day-by-day list.
                    Button { selectedDay = (selectedDay == yesterdayKey) ? nil : yesterdayKey } label: {
                        Text(L("昨天 ", "yesterday ") + Fmt.money(f.yesterday, currency))
                            .font(VG.caption).foregroundStyle(selectedDay == yesterdayKey ? .primary : .secondary)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stats.yesterday")
                    .help(L("查看昨天全天：点击下面的柱子也可以看任意一天", "Show yesterday; click any bar for another day"))
                }
            }
            if values.isEmpty {
                Text(snapshot.hasAnyPricing ? L("近 14 天没有可定价的用量", "No priced usage in the last 14 days") : L("价格表不可用，请查看模型价格", "Rates unavailable; check Model prices"))
                    .font(VG.caption).foregroundStyle(.secondary)
            } else {
                GlassBars(values: values, labels: (f?.recentDays ?? []).map(shortDate), tint: Glass.money, tintEnd: Glass.moneyEnd,
                          selected: selected, onSelect: { index in
                              guard keys.indices.contains(index) else { return }
                              selectedDay = (selectedDay == keys[index]) ? nil : keys[index]
                          },
                          format: { Fmt.money($0, currency) })
                    .frame(height: 64)
                    .accessibilityLabel(L("近 14 天费用", "Cost over the last 14 days"))
                HStack {
                    Text((f?.recentDays.first).map(shortDate) ?? "")
                    Spacer()
                    Text(L("横线为日均 · 原记录费用 · 点柱子看当天", "Line = daily average · recorded cost · tap a bar for a day"))
                    Spacer()
                    Text(L("今天", "Today"))
                }.font(.system(size: 9 * VG.scale)).foregroundStyle(.tertiary)
            }
            if let selectedDay, keys.contains(selectedDay) {
                daySummary(selectedDay)
            }
        }
        .glassTile(tint: Glass.moneyEnd)
    }

    private var todayKey: String { UsageHistory.dayKey(timestamp: Date().timeIntervalSince1970) }
    private var yesterdayKey: String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return UsageHistory.dayKey(timestamp: yesterday.timeIntervalSince1970)
    }

    /// One day in full: money, tokens, requests, where the tokens went and which device paid.
    /// Cost comes from the hourly ledger (so it matches the chart); tokens/requests come from the day buckets.
    private func daySummary(_ key: String) -> some View {
        let currency = chartCurrency
        let sources = (snapshot.days.first { $0.date == key }?.sources ?? [:])
            .filter { allows($0.key) && !UsageHistory.isProxySource($0.key) }
        let tokens = sources.values.reduce(Int64(0)) { $0 + $1.tokenTotal }
        let requests = sources.values.reduce(0) { $0 + $1.turns }
        let cost = dailyCost[key]
        let byTool = Dictionary(grouping: sources, by: { UsageHistory.cli(of: $0.key) })
            .mapValues { group in group.reduce(Int64(0)) { $0 + $1.value.tokenTotal } }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let devices = deviceCosts(for: key, currency: currency)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dayTitle(key)).font(VG.font(12, .semibold))
                if key == todayKey { Text(L("今天", "Today")).font(VG.caption).foregroundStyle(.tertiary) }
                else if key == yesterdayKey { Text(L("昨天", "Yesterday")).font(VG.caption).foregroundStyle(.tertiary) }
                Spacer(minLength: 4)
                Text(cost.map { Fmt.money($0, currency) } ?? "—").font(VG.font(12, .semibold)).monospacedDigit()
                Button { selectedDay = nil } label: { Image(systemName: "xmark.circle.fill").font(VG.caption) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel(L("关闭当天明细", "Close day details"))
            }
            Text(L("\(formatTokens(tokens)) token · \(requests) 次请求", "\(formatTokens(tokens)) tokens · \(requests) requests"))
                .font(VG.caption).foregroundStyle(.secondary).monospacedDigit()
            if !byTool.isEmpty {
                Text(byTool.map { name, value in
                    name + " " + String(format: "%.0f%%", Double(value) / Double(max(tokens, 1)) * 100)
                }.joined(separator: " · "))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if devices.count > 1 {
                Text(L("设备 ", "devices ") + devices.prefix(3).map { name, value in
                    deviceName(name) + " " + Fmt.money(value, currency)
                }.joined(separator: " · "))
                    .font(VG.caption).foregroundStyle(.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    /// Per-device cost for one day, in the chart currency, honouring the device scope.
    private func deviceCosts(for key: String, currency: String) -> [(String, Double)] {
        switch scope {
        case .local:
            return [("local", snapshot.dailyCostByDevice["local"]?[currency]?[key] ?? 0)]
        case .remote(let host):
            let id = "remote:\(host)"
            return [(id, snapshot.dailyCostByDevice[id]?[currency]?[key] ?? 0)]
        case .all:
            return snapshot.dailyCostByDevice.compactMap { id, currencies in
                currencies[currency]?[key].map { (id, $0) }
            }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        }
    }

    private func deviceName(_ id: String) -> String {
        if id == "local" { return L("本机", "Local") }
        if id.hasPrefix("remote:") { return RemoteCollector.displayName(for: String(id.dropFirst("remote:".count))) }
        return RemoteCollector.displayName(for: id)
    }

    private func dayTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter.string(from: date)
    }

    /// Where the recorded money went, by device and tool, in one currency.
    private var sourcesTile: some View {
        let currency = chartCurrency
        let rows = costBySource.filter { !UsageHistory.isProxySource($0.key) }
            .compactMap { source, perCurrency -> (String, Double)? in
                guard let value = perCurrency[currency], value > 0 else { return nil }
                return (source, value)
            }
            .sorted { $0.1 > $1.1 }
        let top = Array(rows.prefix(5))
        let rest = rows.dropFirst(5).reduce(0) { $0 + $1.1 }
        let total = rows.reduce(0) { $0 + $1.1 }
        let others = costBySource.values.flatMap { $0.keys }.filter { $0 != currency }
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("花在哪里 · 累计", "Where it went · all time")).font(VG.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.money(total, currency)).font(VG.caption.weight(.semibold)).monospacedDigit()
                    }
                    SegmentBar(parts: top.enumerated().map { index, row in
                        .init(id: row.0, value: row.1, tint: Self.palette[index % Self.palette.count])
                    } + (rest > 0 ? [.init(id: L("其他", "Other"), value: rest, tint: .secondary)] : []), total: total, height: 9)
                    ForEach(Array(top.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 6) {
                            Circle().fill(Self.palette[index % Self.palette.count]).frame(width: 7, height: 7)
                            Text(sourceTitle(row.0)).font(VG.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f%%", row.1 / max(total, 0.000_001) * 100)).font(VG.caption).foregroundStyle(.tertiary).monospacedDigit()
                            Text(Fmt.money(row.1, currency)).font(VG.callout).monospacedDigit()
                        }
                    }
                    if !others.isEmpty {
                        Text(L("另有 \(Set(others).sorted().joined(separator: "/")) 计价的记录单独保留", "Records priced in \(Set(others).sorted().joined(separator: "/")) are kept separately"))
                            .font(.system(size: 10 * VG.scale)).foregroundStyle(.tertiary)
                    }
                }
                .glassTile(tint: Glass.money)
            }
        }
    }

    private func sourceTitle(_ source: String) -> String {
        let cli = UsageHistory.cli(of: source)
        guard let device = UsageHistory.device(of: source) else { return cli + " · " + L("本机", "Local") }
        return cli + " · " + RemoteCollector.displayName(for: device)
    }

    // MARK: 模型 · token 分层

    private enum ModelPeriod: String, CaseIterable {
        case today, week, all
        var title: String {
            switch self {
            case .today: return L("今日", "Today")
            case .week: return L("7 天", "7 days")
            case .all: return L("全部", "All")
            }
        }
    }

    private struct ModelUsageRow: Identifiable {
        var id: String { model }
        var model: String
        var usage: UsageHistory.ModelTotals
        var requests: Int
        var costByCurrency: [String: Double]
        var unpricedRequests: Int
        var sources: Set<String>
        var tokenTotal: Int64 { usage.tokenTotal }
        var family: String { Brand.family(forModel: model) }
        var freshInput: Int64 { max(0, usage.ctx - usage.cacheRead - usage.cacheWrite) }
    }

    /// Days feeding the model tile. `selectedDay` follows the 14-day chart; otherwise the period picker.
    private var modelDays: Set<String>? {
        if let selectedDay { return [selectedDay] }
        switch modelPeriod {
        case .today:
            return [UsageHistory.dayKey(timestamp: Date().timeIntervalSince1970)]
        case .week:
            let calendar = Calendar.current
            return Set((0..<7).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: Date()).map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) }
            })
        case .all:
            return nil
        }
    }

    private func modelUsageRows() -> [ModelUsageRow] {
        var collected: [String: (use: UsageHistory.ModelUse, sources: Set<String>)] = [:]
        let days = modelDays
        for (day, sources) in snapshot.modelUsageDays {
            if let days, !days.contains(day) { continue }
            for (source, models) in sources where allows(source) && !UsageHistory.isProxySource(source) {
                for (model, use) in models {
                    collected[model, default: (UsageHistory.ModelUse(), [])].use.merge(use)
                    collected[model, default: (UsageHistory.ModelUse(), [])].sources.insert(source)
                }
            }
        }
        // One model can arrive under two names: its bare id from an agent's own logs and the
        // provider-qualified id the gateway recorded ("gpt-6.1-sol" and "codex/gpt-6.1-sol").
        // A model-usage tile wants one line per model, so fold the qualified ids into the bare
        // id whenever the bare one is present too; a real vendor path such as
        // "deepseek-ai/DeepSeek-V4.1-Flash-1017" has no bare twin and keeps its name.
        let ids = Set(collected.keys)
        var merged: [String: (use: UsageHistory.ModelUse, sources: Set<String>)] = [:]
        for (model, entry) in collected {
            let canonical = Self.canonicalModelId(model, among: ids)
            merged[canonical, default: (UsageHistory.ModelUse(), [])].use.merge(entry.use)
            merged[canonical, default: (UsageHistory.ModelUse(), [])].sources.formUnion(entry.sources)
        }
        return merged.map { model, entry in
            ModelUsageRow(model: model, usage: entry.use.usage, requests: entry.use.requests,
                          costByCurrency: entry.use.costByCurrency, unpricedRequests: entry.use.unpricedRequests,
                          sources: entry.sources)
        }
        .filter { $0.tokenTotal > 0 }
        .sorted { a, b in
            if a.tokenTotal != b.tokenTotal { return a.tokenTotal > b.tokenTotal }
            return a.model < b.model
        }
    }

    static func selfTest() {
        let ids: Set<String> = ["gpt-6.1-sol", "codex/gpt-6.1-sol", "chatgpt-web/gpt-6-sol",
                                "deepseek-ai/DeepSeek-V4.1-Flash-1017"]
        precondition(canonicalModelId("codex/gpt-6.1-sol", among: ids) == "gpt-6.1-sol",
                     "a qualified id folds into the bare id when both exist")
        precondition(canonicalModelId("chatgpt-web/gpt-6-sol", among: ids) == "chatgpt-web/gpt-6-sol",
                     "a qualified id with no bare twin keeps its provider name")
        precondition(canonicalModelId("deepseek-ai/DeepSeek-V4.1-Flash-1017", among: ids)
                     == "deepseek-ai/DeepSeek-V4.1-Flash-1017",
                     "a real vendor path is not mistaken for a provider prefix")
        precondition(canonicalModelId("plain-model", among: ids) == "plain-model")
    }

    /// The name a model is counted under in this tile: the bare id when it exists, so that
    /// "codex/gpt-6.1-sol" and "gpt-6.1-sol" are one line instead of two.
    static func canonicalModelId(_ model: String, among ids: Set<String>) -> String {
        var current = model
        var hops = 0
        while hops < 3, let slash = current.firstIndex(of: "/") {
            let suffix = String(current[current.index(after: slash)...])
            guard !suffix.isEmpty, ids.contains(suffix) else { break }
            current = suffix
            hops += 1
        }
        return current
    }

    private func modelMoney(_ costs: [String: Double]) -> String {
        guard !costs.isEmpty else { return L("未定价", "Unpriced") }
        return MoneyDisplay.format(costs, mode: .usd, quote: nil).text
    }

    /// One model line: tokens first (the question this tile answers), then where those tokens went.
    private func modelRow(_ row: ModelUsageRow, peak: Int64) -> some View {
        let tint = Brand.color(forFamily: row.family)
        let breakdown = L("输入 \(formatTokens(row.freshInput)) · 缓存 \(formatTokens(row.usage.cacheRead + row.usage.cacheWrite)) · 输出 \(formatTokens(row.usage.out))",
                          "in \(formatTokens(row.freshInput)) · cache \(formatTokens(row.usage.cacheRead + row.usage.cacheWrite)) · out \(formatTokens(row.usage.out))")
            + (row.usage.think > 0 ? L(" · 思考 \(formatTokens(row.usage.think))", " · think \(formatTokens(row.usage.think))") : "")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(row.model).font(VG.font(11.5, .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(formatTokens(row.tokenTotal)).font(VG.font(11.5, .semibold)).monospacedDigit()
                Text(modelMoney(row.costByCurrency)).font(VG.font(10)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(spacing: 5) {
                Text(breakdown).font(VG.font(9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(L("\(row.requests) 次", "\(row.requests) req")).font(VG.font(9)).foregroundStyle(.tertiary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: max(3, geo.size.width * CGFloat(Double(row.tokenTotal) / Double(max(peak, 1)))))
                }
            }.frame(height: 3)
        }
        .padding(.vertical, 2)
        .help(L("\(row.model) · \(breakdown) · \(row.requests) 次请求 · API 等价 \(modelMoney(row.costByCurrency))",
                "\(row.model) · \(breakdown) · \(row.requests) requests · API equivalent \(modelMoney(row.costByCurrency))")
              + (row.unpricedRequests > 0 ? "\n" + L("\(row.unpricedRequests) 次请求没有价格，金额偏低", "\(row.unpricedRequests) unpriced requests understate the cost") : ""))
    }

    /// Token totals grouped by recognisable brand, so the strip answers "which family ate the quota".
    private func familyParts(_ rows: [ModelUsageRow]) -> [SegmentBar.Part] {
        var byFamily: [String: Int64] = [:]
        for row in rows { byFamily[row.family, default: 0] += row.tokenTotal }
        let top = byFamily.sorted { $0.value > $1.value }
        let others = top.dropFirst(4).reduce(Int64(0)) { $0 + $1.value }
        var parts = top.prefix(4).map { family, tokens in
            SegmentBar.Part(id: family, value: Double(tokens), tint: Brand.color(forFamily: family))
        }
        if others > 0 { parts.append(.init(id: L("其他", "Other"), value: Double(others), tint: .secondary)) }
        return parts
    }

    private var modelsTile: some View {
        let rows = modelUsageRows()
        let shown = showAllModels ? rows : Array(rows.prefix(5))
        let totalTokens = rows.reduce(Int64(0)) { $0 + $1.tokenTotal }
        let totalCost = rows.reduce(into: [String: Double]()) { result, row in
            for (currency, value) in row.costByCurrency { result[currency, default: 0] += value }
        }
        let peak = rows.first?.tokenTotal ?? 1
        let label = selectedDay.map(shortDate) ?? modelPeriod.title
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(L("模型用量", "Model usage")).font(VG.caption).foregroundStyle(.secondary)
                VGInfoButton(title: L("模型 token 分层", "Model token breakdown"),
                             text: L("按模型汇总 token，而不是只按 Codex / Claude 两个来源。范围跟随统计页的设备筛选，并排除代理镜像（避免和 CLI 日志重复）。金额是按 API 官方价折算的等价花费：国产模型的人民币价会按参考汇率折成美元，DSH 账本的人民币实付也折算成美元；汇率不可用时保留原币。未定价模型只计 token，不计金额。",
                                     "Tokens are grouped by model, not only by the Codex / Claude source. The device filter applies and proxy mirrors are excluded to avoid double counting. Money is API-equivalent pricing; CNY-priced domestic models and DSH’s CNY ledger are converted at the reference rate, and stay in their original currency if no rate is available. Unpriced models still count tokens but not money."))
                Spacer(minLength: 4)
                if selectedDay != nil {
                    Button { selectedDay = nil } label: {
                        Text(L("跟随范围", "Follow range")).font(VG.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help(L("取消图表当天的选择", "Clear the chart’s day selection"))
                }
                Menu {
                    ForEach(ModelPeriod.allCases, id: \.rawValue) { period in
                        Button {
                            selectedDay = nil
                            modelPeriod = period
                        } label: {
                            if modelPeriod == period && selectedDay == nil { Label(period.title, systemImage: "checkmark") }
                            else { Text(period.title) }
                        }
                    }
                } label: {
                    GlassChipLabel(icon: "calendar", text: label)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("stats.modelRange")
            }
            if rows.isEmpty {
                Text(L("这个范围还没有模型用量记录", "No model usage in this range")).font(VG.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatTokens(totalTokens))
                        .font(.system(size: 20 * VG.scale, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(LinearGradient(colors: [Glass.gpu, Glass.moneyEnd], startPoint: .leading, endPoint: .trailing))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(L("token · \(rows.count) 个模型", "tokens · \(rows.count) models")).font(VG.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(modelMoney(totalCost)).font(VG.font(11, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }
                if rows.count > 1 {
                    SegmentBar(parts: familyParts(rows), height: 5)
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { row in modelRow(row, peak: peak) }
                }
                if rows.count > 5 {
                    Button { showAllModels.toggle() } label: {
                        HStack(spacing: 3) {
                            Text(showAllModels ? L("收起", "Show less") : L("全部 \(rows.count) 个模型", "All \(rows.count) models"))
                            Image(systemName: showAllModels ? "chevron.up" : "chevron.down")
                        }
                        .font(VG.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("stats.allModels")
                }
                if rows.contains(where: { $0.unpricedRequests > 0 }) {
                    Text(L("部分模型没有价格：token 计数完整，金额是下限。", "Some models have no rate: tokens are complete, money is a lower bound."))
                        .font(.system(size: 9 * VG.scale)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .glassTile(tint: Glass.gpu)
        .accessibilityIdentifier("stats.models")
    }

    // MARK: 今日模型表现

    private var modelPerformance: some View {
        let rows = PerformancePresentation.rows(snapshot: snapshot, scope: scope, hosts: hosts, now: Date().timeIntervalSince1970)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    Text(L("今日暂无模型记录", "No model records today")).font(VG.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.prefix(8))) { row in
                        performanceRow(row)
                        if row.id != rows.prefix(8).last?.id { Divider() }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(L("模型表现", "Model performance")).font(VG.body)
                Spacer(minLength: 4)
                Text(L("今日 · 前 8", "Today · top 8")).font(VG.caption).foregroundStyle(.secondary)
                VGInfoButton(title: L("模型统计", "Model statistics"),
                             text: L("按今日请求数排序。同模型同时有 CLI 与代理记录时，请求、上下文及缓存取 CLI 汇总；速度优先代理实测，否则标估算。TTFT、错误及 429 仅来自当前设备范围内的代理。速度分位数使用今日最近最多 500 条/来源/模型样本，其余汇总不截断。", "Sorted by today’s requests. For models in both logs, requests, context and cache use CLI totals. Speed prefers measured proxy data, otherwise it is estimated. TTFT, errors and 429s use only proxy records within the device scope. Speed percentiles use today’s most recent samples, capped at 500 per source/model; totals are uncapped."))
            }
        }
        .tint(.secondary)
        .accessibilityIdentifier("stats.models")
    }

    private func performanceRow(_ row: ModelPerformanceRow) -> some View {
        let source = row.estimated ? L("CLI 估算", "CLI estimate") : L("代理", "Proxy")
        let details = performanceDetails(row)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.model + " · " + source)
                    .font(VG.font(12, .medium)).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.model)
                Text(L("今日 \(row.totals.requests) 次", "\(row.totals.requests) today"))
                    .font(VG.caption).monospacedDigit().foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !details.isEmpty {
                Text(details).font(VG.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .help(row.proxyTotals.proxyRequests > 0
              ? L("\(row.proxyTotals.proxyRequests) 次有状态码的代理请求中：错误 \(row.proxyTotals.errors) 次，429 \(row.proxyTotals.rateLimits) 次。错误为 HTTP ≥ 400，已包含 429。", "\(row.proxyTotals.errors) errors and \(row.proxyTotals.rateLimits) 429s in \(row.proxyTotals.proxyRequests) proxy requests with a status code. Errors are HTTP ≥ 400 and include 429s.") : "")
    }

    private func performanceDetails(_ row: ModelPerformanceRow) -> String {
        var details: [String] = []
        let samples = row.speedSamples
        if let p50 = PerformanceStats.speed(samples), let p90 = PerformanceStats.speed(samples, percentile: 0.9) {
            details.append("tok/s p50/p90 \(PerformancePresentation.speed(p50)) / \(PerformancePresentation.speed(p90))")
        }
        if let p50 = PerformanceStats.ttft(row.samples), let p95 = PerformanceStats.ttft(row.samples, percentile: 0.95) {
            details.append("TTFT p50/p95 \(PerformancePresentation.latency(p50)) / \(PerformancePresentation.latency(p95))")
        }
        if row.totals.requests > 0, row.totals.context > 0 {
            let context = formatTokens(row.totals.context / Int64(row.totals.requests))
            details.append(L("平均上下文 \(context)", "Avg. context \(context)"))
            details.append(L("缓存命中 \(PerformancePresentation.cache(row.totals))", "Cache hit \(PerformancePresentation.cache(row.totals))"))
        }
        let proxy = row.proxyTotals
        if proxy.proxyRequests > 0 {
            let rates = String(format: "%.1f%% / %.1f%%", Double(proxy.errors) / Double(proxy.proxyRequests) * 100, Double(proxy.rateLimits) / Double(proxy.proxyRequests) * 100)
            details.append(L("错误/429 \(rates)", "Errors/429 \(rates)"))
        }
        return details.joined(separator: " · ")
    }

    // MARK: 今日费用与趋势

    private var todayCard: some View {
        let totals = todayEquivalent
        let currentDay = snapshot.capturedAt > 0 && Calendar.current.isDate(
            Date(timeIntervalSince1970: snapshot.capturedAt), inSameDayAs: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("今日 · API 等价费用", "Today · API-equivalent cost"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                VGInfoButton(title: L("今日费用范围", "Today’s cost coverage"),
                             text: L("按今日设备记录的 token 与参考 API 单价折算，包含订阅内调用，不等于实付账单。各币种独立保留；未定价请求不计入费用。未含云端 / Dot。", "Today’s device-recorded tokens valued at reference API rates, including subscription calls; not billed charges. Currencies are kept separate and unpriced requests are excluded. Cloud / Dot is excluded."))
            }
            Text(currentDay ? MoneyDisplay.format(totals.equivalentCostByCurrency, mode: .original, quote: nil).text : "—")
                .font(VG.number(22, .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("stats.today-cost")
            Text(!currentDay ? L("待刷新今日用量", "Waiting for today’s usage refresh")
                 : totals.requests > 0
                 ? L("\(formatTokens(totals.usage.tokenTotal)) token · \(totals.requests) 次请求", "\(formatTokens(totals.usage.tokenTotal)) tokens · \(totals.requests) requests")
                 : L("今日暂无设备用量记录", "No device usage recorded today"))
                .font(VG.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if currentDay && totals.unpricedRequests > 0 {
                Text(L("\(totals.unpricedRequests) 次请求未定价，未计入费用", "\(totals.unpricedRequests) unpriced requests excluded from costs"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .vgCard(padding: 10)
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("今日原记录费用", "Today · original recorded cost"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if forecasts.count > 1 {
                    Menu {
                        ForEach(forecasts.keys.sorted(), id: \.self) { currency in
                            Button { selectedCurrency = currency } label: {
                                if forecast?.currency == currency {
                                    Label(currency, systemImage: "checkmark")
                                } else { Text(currency) }
                            }
                        }
                    } label: {
                        Text(forecast?.currency ?? snapshot.primaryCurrency).font(VG.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 64 * VG.scale)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L("币种", "Currency"))
                    .accessibilityIdentifier("stats.currency")
                }
                VGInfoButton(title: L("费用范围", "Cost coverage"),
                             text: L("沿用历史记录的费用规则；订阅内调用在此可能为 0，与上方 API 等价用量不同。各币种独立显示，预测按时间外推，不代表额度容量。价格与来源见历史说明。未含云端 / Dot。", "Uses the original history cost rules: included subscription calls may be zero here, unlike API-equivalent usage above. Currencies remain separate. Forecasts extrapolate spending over time, not quota capacity. See history notes for rates and sources. Cloud / Dot is excluded."))
            }
            if let f = forecast {
                Text(Fmt.money(f.todaySoFar, f.currency))
                    .font(VG.number(22, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stats.recorded-today-cost")
                VGBarChart(values: f.recentCosts, labels: f.recentDays.map { shortDate($0) },
                           tint: .accentColor, height: 36,
                           format: { Fmt.money($0, f.currency) })
                    .accessibilityLabel(L("近 14 天费用", "Cost over the last 14 days"))
            } else {
                Text("—").font(VG.number(22, .semibold))
                Text(snapshot.hasAnyPricing
                     ? L("近 35 天没有可定价的用量", "No priced usage in the last 35 days")
                     : L("价格表不可用，请查看模型价格", "Rates unavailable; check Model prices"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !unpricedNames.isEmpty {
                Text(L("历史中 \(unpricedNames.count) 个模型未定价，未计入费用", "History: \(unpricedNames.count) unpriced models excluded from costs"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// These are time-based spending estimates, not quota capacity.
    private func spendingForecast(_ f: CostForecast) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                VGKeyValue(key: f.todayConfidence == .insufficient ? L("今日短时估计", "Today · short-term estimate") : L("今日全天参考", "Today · daily estimate"), value: Fmt.money(f.todayProjected, f.currency))
                VGKeyValue(key: L("今日区间", "Today’s range"), value: "\(Fmt.money(f.todayLow, f.currency)) – \(Fmt.money(f.todayHigh, f.currency))")
                VGProgress(value: f.todayHigh > 0 ? f.todaySoFar / f.todayHigh : 0, tint: .secondary, height: 5,
                           marker: f.todayHigh > 0 ? f.todayProjected / f.todayHigh : nil)
                VGKeyValue(key: L("近 1 小时", "Last hour"), value: "\(Fmt.money(f.lastHourCost, f.currency))/h")
                VGKeyValue(key: L("昨天", "Yesterday"), value: Fmt.money(f.yesterday, f.currency))
                VGKeyValue(key: L("本周", "This week"), value: Fmt.money(f.weekSoFar, f.currency))
                VGKeyValue(key: L("本月已计", "Month recorded"), value: Fmt.money(f.monthSoFar, f.currency))
                if f.monthConfidence != .insufficient {
                    VGKeyValue(key: L("本月参考", "Month estimate"), value: Fmt.money(f.monthProjected, f.currency))
                }
                Text(f.monthConfidence == .insufficient
                     ? L("\(forecastBasis(f)) · 近 14 天仅 \(f.historyDays) 日记录，暂不外推整月。", "\(forecastBasis(f)) · Only \(f.historyDays) recorded days in the last 14; monthly extrapolation is withheld.")
                     : L("\(forecastBasis(f)) · 本月波动范围 \(Fmt.money(f.monthLow, f.currency)) – \(Fmt.money(f.monthHigh, f.currency)) · \(f.historyDays) 日记录", "\(forecastBasis(f)) · Monthly variability \(Fmt.money(f.monthLow, f.currency)) – \(Fmt.money(f.monthHigh, f.currency)) · \(f.historyDays) recorded days"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).help(f.basis)
                ForEach(forecasts.keys.sorted().filter { $0 != f.currency }, id: \.self) { currency in
                    if let other = forecasts[currency], other.hasData {
                        VGKeyValue(key: currency, value: L("今日 \(Fmt.money(other.todaySoFar, currency)) · 本月已计 \(Fmt.money(other.monthSoFar, currency))", "Today \(Fmt.money(other.todaySoFar, currency)) · month recorded \(Fmt.money(other.monthSoFar, currency))"))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(L("支出预测", "Spending forecast")).font(VG.body)
        }
        .tint(.secondary)
        .accessibilityIdentifier("stats.forecast")
    }

    private func blockCard(_ b: BillingBlock) -> some View {
        let now = Date().timeIntervalSince1970
        let progress = (now - b.start) / max(1, b.end - b.start)
        return VStack(alignment: .leading, spacing: 7) {
            VGSectionHeader(title: L("本机 Claude · 当前 5 小时块", "Local Claude · current 5-hour block"), symbol: "timer", tint: .secondary) {
                Text(UIFormat.countdown(to: b.end, now: now).map { L("剩 \($0)", "\($0) remaining") } ?? "").font(VG.caption).foregroundStyle(.secondary)
            }
            VGKeyValue(key: L("已花 · \(b.requests) 次请求", "Spent · \(b.requests) requests"), value: Fmt.money(b.cost, b.currency))
            VGKeyValue(key: L("到块结束约", "Estimate at block end"), value: Fmt.money(b.projected, b.currency))
            VGProgress(value: progress, tint: .secondary, height: 5)
            Text(L("按块内速度 \(Fmt.money(b.perHour, b.currency))/小时推算（ccusage blocks 口径：首条请求整点起算，5 小时一块）", "Projected at \(Fmt.money(b.perHour, b.currency))/h. Uses ccusage blocks: five hours from the first request’s hour."))
                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .vgCard(padding: 10)
    }

    // MARK: 总览

    private var metrics: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if let earliestDate {
                    Text(L("自 \(earliestDate) 起", "Since \(earliestDate)"))
                        .font(VG.caption).foregroundStyle(.secondary)
                }
                VGKeyValue(key: L("累计 token", "Total tokens"), value: hasRecords ? formatTokens(visibleAggregate.tokenTotal) : "—")
                    .help(L("输入（含缓存）+ 输出", "Input (including cache) + output"))
                VGKeyValue(key: L("原记录费用", "Original recorded cost"), value: costText(costByCurrency))
                VGKeyValue(key: L("活跃天数", "Active days"), value: hasRecords ? "\(activeDays)" : "—")
                    .help(L("有 token 用量的日子", "Days with recorded usage"))
                VGKeyValue(key: L("缓存命中率", "Cache hit rate"), value: cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    .help(L("缓存读取 / 全部输入", "Cache reads / all input"))
            }
            .padding(.top, 6)
        } label: {
            Text(remoteHost.map { L("\($0) · 累计", "\($0) · all-time totals") } ?? L("累计 · 原记录", "All-time · original records"))
                .font(VG.body).fixedSize(horizontal: false, vertical: true)
        }
        .tint(.secondary)
        .accessibilityIdentifier("stats.totals")
    }

    private func costText(_ value: [String: Double]) -> String {
        guard snapshot.hasAnyPricing else { return L("未定价", "Unpriced") }
        return value.isEmpty ? "—" : Fmt.money(value)
    }

    private var heatmap: some View {
        let dates = days
        let keys = dates.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) }
        let values = keys.map { dailyTokens[$0] ?? 0 }
        let grades = UsageHistory.levels(values)
        return VStack(alignment: .leading, spacing: 7) {
            VGSectionHeader(title: L("每日强度 · 近 6 周", "Daily activity · last 6 weeks"), symbol: "square.grid.3x3.fill", tint: Glass.money) {
                Text(maxDayText).font(VG.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekday(dates[row])).font(VG.caption).foregroundStyle(.secondary).frame(width: 16, height: 15)
                    }
                }
                ForEach(0..<6, id: \.self) { column in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let i = column * 7 + row
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(grades[i] == 0 ? Color.primary.opacity(0.07) : Glass.money.opacity(0.22 + Double(grades[i]) * 0.15))
                                .frame(maxWidth: .infinity).frame(height: 15)
                                .help(L("\(keys[i]) · \(formatTokens(values[i])) token", "\(keys[i]) · \(formatTokens(values[i])) tokens") + (dailyCost[keys[i]].map { " · " + Fmt.money($0, forecast?.currency ?? snapshot.primaryCurrency) } ?? ""))
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer()
                Text(L("少", "Less")).font(VG.caption).foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Glass.money.opacity(0.22 + Double(level) * 0.15)).frame(width: 9, height: 9)
                }
                Text(L("多", "More")).font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .vgCard(padding: 10)
    }

    private var maxDayText: String {
        let visible = Set(days.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) })
        guard let day = dailyTokens.filter({ $0.value > 0 && visible.contains($0.key) }).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else { return "" }
        return L("最多：\(shortDate(day.key))", "Peak: \(shortDate(day.key))")
    }
    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : key
    }
    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter.string(from: date)
    }

    private var distribution: some View {
        let all = visibleAggregate
        let parts: [(String, Int64, Color)] = [(L("新输入", "Fresh input"), all.newInput, .secondary), (L("输出", "Output"), all.out, .primary), (L("缓存", "Cached"), all.cacheTotal, .secondary.opacity(0.5))]
        let total = max(1, all.newInput + all.out + all.cacheTotal)
        return VStack(alignment: .leading, spacing: 7) {
            VGSectionHeader(L("token 构成", "Token breakdown"), symbol: "chart.pie.fill", tint: .secondary)
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(0, geo.size.width * CGFloat(Double(part.1) / Double(total)) - 1.5))
                    }
                }.clipShape(Capsule())
            }.frame(height: 7)
            ForEach(parts.indices, id: \.self) { index in
                let part = parts[index]
                HStack(spacing: 6) {
                    Circle().fill(part.2).frame(width: 7, height: 7)
                    Text(part.0).font(VG.subheadline)
                    if index == 1, all.think > 0 { Text(L("含思考 \(formatTokens(all.think))", "Includes \(formatTokens(all.think)) reasoning")).font(VG.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(hasRecords ? formatTokens(part.1) : "—").font(VG.number(11, .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .vgCard(padding: 10)
    }

    // MARK: 各来源

    private var providers: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(sources, id: \.self) { source in
                    if source != sources.first { Divider().opacity(0.45) }
                    if let total = visibleTotals[source] {
                        providerRow(source, total)
                    } else {
                        HStack(spacing: 8) {
                            sourceIcon(source)
                            Text(source).font(VG.font(12, .medium))
                            Spacer()
                            Text(snapshot.sourceNotes[source].map { sourceNoteText($0) } ?? (snapshot.isScanning ? L("正在汇总…", "Summarizing…") : L("无记录", "No records")))
                                .font(VG.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(snapshot.sourceNotes[source] ?? "")
                        }
                        .padding(.vertical, 2)
                    }
                }
                if remoteHost == nil {
                    Divider().opacity(0.45)
                    HStack(spacing: 8) {
                        sourceIcon("Grok")
                        Text(L("Grok / Gemini", "Grok / Gemini")).font(VG.font(12, .medium))
                        Spacer()
                        Text(L("本地日志没有 token 统计", "Local logs have no token totals")).font(VG.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(L("各来源 · 原记录", "Sources · original records")).font(VG.body)
                Spacer(minLength: 4)
                Text(L("今天 · 累计", "Today · all time")).font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .accessibilityIdentifier("stats.sources")
    }

    private func sourceIcon(_ source: String) -> some View {
        let cli = UsageHistory.cli(of: source)
        let (symbol, tint): (String, Color) = {
            if source.hasPrefix("API") { return ("key.horizontal.fill", .gray) }
            switch cli {
            case "Claude": return ("sparkle", .secondary)
            case "Codex": return ("chevron.left.forwardslash.chevron.right", .secondary)
            case "OpenCode": return ("terminal.fill", .secondary)
            default: return ("circle.dashed", .gray)
            }
        }()
        return VGIcon(symbol: symbol, tint: tint, size: 18)
    }

    private func providerRow(_ source: String, _ totals: UsageHistory.Totals) -> some View {
        let ratio = visibleAggregate.tokenTotal > 0 ? Double(totals.tokenTotal) / Double(visibleAggregate.tokenTotal) : 0
        let today = snapshot.todayBySource[source]
        let todayCost = snapshot.todayCostBySource[source] ?? [:]
        let device = UsageHistory.device(of: source)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                sourceIcon(source)
                VStack(alignment: .leading, spacing: 3) {
                    Text(UsageHistory.cli(of: source)).font(VG.font(13, .medium))
                    if let device {
                        Text(device).font(VG.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if UsageHistory.isProxySource(source) {
                        Text(L("不计入总数", "Excluded from totals"))
                            .font(VG.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Text(costText(costBySource[source] ?? [:])).font(VG.number(12))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("今天 \(today.map { formatTokens($0.tokenTotal) } ?? "0") token · \(today?.turns ?? 0) 次", "Today \(today.map { formatTokens($0.tokenTotal) } ?? "0") tokens · \(today?.turns ?? 0) requests") + (todayCost.isEmpty ? "" : " · \(Fmt.money(todayCost))"))
                Text(L("累计 \(formatTokens(totals.tokenTotal)) · \(totals.sessions) 会话", "Total \(formatTokens(totals.tokenTotal)) · \(totals.sessions) sessions"))
            }
            .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VGProgress(value: UsageHistory.isProxySource(source) ? 0 : ratio, tint: .secondary, height: 4)
            if let note = snapshot.sourceNotes[source] { Text(sourceNoteText(note)).font(VG.caption).foregroundStyle(.secondary).help(note) }
            if unpricedBySource[source, default: 0] > 0 {
                let names = snapshot.unpricedNamesBySource[source, default: []].prefix(4).joined(separator: L("、", ", "))
                Text(L("未定价：\(names)（不计入成本）", "Unpriced: \(names) (excluded from costs)")).font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(priceNote)
            Text(L("总数与热力图只算 CLI 日志（Claude / Codex / opencode，含远程与挂载设备）；经记账代理的 API 调用多半已在 CLI 日志里，单列不重复计入。思考包含在输出中。", "Totals and the heatmap use CLI logs (Claude / Codex / opencode, including remote and mounted devices). Proxy API requests are shown separately to avoid counting CLI usage twice. Reasoning is included in output."))
            if snapshot.cumulativeTurns > 0 {
                Text(L("\(snapshot.cumulativeTurns) 次旧格式 Codex 记录按累计差归桶，跨日精度受事件时间限制。", "\(snapshot.cumulativeTurns) legacy Codex records use cumulative deltas; daily accuracy depends on event timestamps."))
            }
            if snapshot.replayedTurns > 0 {
                Text(L("已跳过 \(snapshot.replayedTurns) 条 fork 会话重放的父会话用量。", "Skipped \(snapshot.replayedTurns) parent-usage records replayed by forked sessions."))
            }
            if snapshot.skippedRecords > 0 {
                Text(L("\(snapshot.skippedRecords) 条记录缺少有效时间或用量，未计入。", "Excluded \(snapshot.skippedRecords) records with missing timestamps or usage.")).foregroundStyle(.secondary)
            }
        }
        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    private func forecastBasis(_ forecast: CostForecast) -> String {
        if forecast.basis == "按近 \(forecast.profileDays) 个活跃日的作息曲线" {
            return L(forecast.basis, "Based on activity across \(forecast.profileDays) recent active days")
        }
        if forecast.basis == "历史不足 3 天，按近 1 小时速度" {
            return L(forecast.basis, "Under 3 days of history; using the last hour’s rate")
        }
        return diagnosticText(forecast.basis)
    }

    private func sourceNoteText(_ note: String) -> String {
        switch note {
        case "未检测到本机会话日志": return L(note, "No local session logs detected")
        case "日志已移除，显示已缓存历史": return L(note, "Logs removed; showing retained history")
        case "未检测到 opencode 用量记录": return L(note, "No opencode usage records detected")
        case "未检测到 opencode 数据库": return L(note, "No opencode database detected")
        default: return diagnosticText(note)
        }
    }

    private func diagnosticText(_ text: String) -> String {
        guard text.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return text }
        return L(text, "Collection details available on hover")
    }

    private var priceNote: String {
        var parts: [String] = []
        if !snapshot.builtinPriceAsOf.isEmpty { parts.append(L("内置参考目录（\(snapshot.builtinPriceAsOf)），各模型来源见价格页", "Built-in reference catalog (\(snapshot.builtinPriceAsOf)); see Rates for individual sources")) }
        if snapshot.hasPriceTable { parts.append(L("你的 prices.json 优先", "Your prices.json takes priority")) }
        let head = parts.isEmpty ? L("未配置价格", "No rates configured") : parts.joined(separator: L("，", "; "))
        return head + L("；内置模型按支持的缓存、长上下文与 Fast 规则计算，自定义价按你的覆盖规则。API 等价估算不等于订阅账单。", "; built-in models use supported cache, long-context and Fast rules; custom rates follow your overrides. API estimates are not subscription bills.")
    }
}
