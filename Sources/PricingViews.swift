import SwiftUI
import AppKit

/// 同一份定价引擎的可查看界面：实际命中的覆盖价、缓存价和来源都能追溯。
struct PricingDetailView: View {
    let history: UsageHistory.Snapshot
    var syncPrices: (@escaping (String, Bool) -> Void) -> Void

    @State private var query = ""
    @State private var showAll = false
    @State private var expanded: Set<String> = []
    @State private var user = ProcessScanner.PriceTable()
    @State private var automatic: Set<String> = []
    @State private var syncedAt = ""
    @State private var references: [String: String] = [:]
    @State private var referenceDates: [String: String] = [:]
    @State private var calendarYear: Int?
    @State private var loadError = ""
    @State private var isLoadingUserPrices = true
    @State private var hasLoadedUserPrices = false
    @State private var priceLoadGeneration = 0
    @State private var syncing = false
    @State private var syncMessage = ""
    @State private var syncFailed = false

    private var catalog: PricingCatalog.Catalog { PricingCatalog.cachedBuiltin ?? PricingCatalog.Catalog() }
    private var catalogIsLoading: Bool { PricingCatalog.cachedBuiltin == nil }
    private var used: Set<String> {
        Set(history.totals.values.flatMap { $0.models.keys })
    }
    private var names: [String] {
        var names = used.union(["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-6-astra"])
        if showAll { names.formUnion(catalog.entries.keys); names.formUnion(user.rows.keys) }
        return names.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                if a == "gpt-6.1-sol" { return b != a }
                if b == "gpt-6.1-sol" { return false }
                return a < b
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(L("模型单价", "Model prices")).font(VG.headline)
                    Spacer(minLength: 4)
                    Button(action: beginSync) {
                        HStack(spacing: 4) {
                            if syncing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.triangle.2.circlepath") }
                            Text(syncing ? L("同步中…", "Syncing…") : L("同步", "Sync"))
                        }
                        .font(VG.caption)
                    }
                    .buttonStyle(.plain).disabled(syncing)
                    .accessibilityIdentifier("pricing.sync")
                    .help(L("补齐缺失并刷新自动价格，保留自定义覆盖价", "Fill missing rates and refresh synced prices; keep custom overrides"))
                    VGInfoButton(title: L("来源与计价", "Sources & pricing"), text: pricingSources)
                }
                HStack(spacing: 8) {
                    TextField(L("搜索模型", "Search models"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(VG.body)
                        .accessibilityIdentifier("pricing.search")
                    Menu {
                        Button { showAll = false } label: {
                            Text(L("我的模型", "My models"))
                        }
                        .accessibilityIdentifier("pricing.scope.mine")
                        Button { showAll = true } label: {
                            Text(L("全部价格", "All rates"))
                        }
                        .accessibilityIdentifier("pricing.scope.all")
                    } label: {
                        Text(showAll ? L("全部价格", "All rates") : L("我的模型", "My models"))
                            .font(VG.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 104 * VG.scale)
                    .accessibilityLabel(L("价格范围", "Rate scope"))
                    .help(showAll ? L("浏览全部价格目录", "Browse the full catalog") : L("我的用量与新模型", "My usage & new models"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("每百万 token · 币种独立", "Per million tokens · separate currencies"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(L("\(names.count) 个模型", "\(names.count) models"))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(VG.caption).foregroundStyle(.secondary)
                if !syncMessage.isEmpty {
                    Label(syncDisplayMessage, systemImage: syncFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(VG.caption).foregroundStyle(syncFailed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true).help(syncMessage)
                }
                if !loadError.isEmpty {
                    Text(loadError).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isLoadingUserPrices || catalogIsLoading {
                    Label(L("正在读取价格…", "Loading rates…"), systemImage: "hourglass")
                        .font(VG.caption).foregroundStyle(.secondary)
                }
            }

            if names.isEmpty {
                Label((!hasLoadedUserPrices || catalogIsLoading)
                      ? L("正在读取可用价格…", "Loading available rates…")
                      : L("没有匹配的模型", "No matching models"),
                      systemImage: (!hasLoadedUserPrices || catalogIsLoading) ? "hourglass" : "magnifyingglass")
                    .font(VG.body).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            if !names.isEmpty && hasLoadedUserPrices {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(names, id: \.self) { model in
                        if model != names.first { Divider().opacity(0.4) }
                        modelRow(model).padding(.vertical, 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reload() }
    }

    private var pricingSources: String {
        var lines = [L("自定义价格优先。内置官方模型按请求的缓存、长上下文与 Fast 档计算；其他目录条目是参考价。金额是 API 等价估算。", "Custom rates take priority. Verified built-in models account for caches, long context and Fast mode; other catalog entries are reference rates. Costs are API-equivalent estimates.")]
        if !syncedAt.isEmpty {
            lines.append(L("自动价格同步于 \(syncedAt)", "Automatic rates synced \(syncedAt)"))
        }
        if !catalog.verifiedOpenAIAsOf.isEmpty {
            lines.append(L("OpenAI 核实于 \(catalog.verifiedOpenAIAsOf)", "OpenAI verified \(catalog.verifiedOpenAIAsOf)"))
        }
        if !catalog.verifiedAnthropicAsOf.isEmpty {
            lines.append(L("Claude 核实于 \(catalog.verifiedAnthropicAsOf)", "Claude verified \(catalog.verifiedAnthropicAsOf)"))
        }
        return lines.joined(separator: "\n")
    }

    private func modelRow(_ model: String) -> some View {
        let custom = user.row(for: model)
        let builtin = PricingCatalog.entry(for: model, in: catalog)
        let subscription = CostEngine.isSubscriptionIncluded(model)
        let userKey = user.rows.keys.filter { model.lowercased().hasPrefix($0) }.max { $0.count < $1.count }
        let auto = userKey.map { automatic.contains($0) } ?? false
        let currency = custom?.currency ?? "USD"
        let isOpen = expanded.contains(model)
        let normalized = PricingCatalog.normalize(model)
        let sourceKey = catalog.verifiedSources.keys.filter {
            normalized == $0 || normalized.hasPrefix($0 + "-")
        }.max { $0.count < $1.count }
        let officialURL = sourceKey.flatMap { catalog.verifiedSources[$0] }.flatMap(URL.init(string:))
        let origin = catalogIsLoading ? L("读取中", "Loading") : subscription ? L("订阅内", "Included") : custom != nil ? (auto ? L("自动同步", "Synced") : L("覆盖价", "Override"))
            : builtin != nil ? (officialURL != nil ? L("官方", "Official") : L("参考价", "Reference")) : L("未定价", "Unpriced")
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOpen { expanded.remove(model) } else { expanded.insert(model) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(model).font(VG.font(13, .medium)).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).help(model)
                        Text(origin).font(VG.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(VG.caption).foregroundStyle(.secondary)
                    }
                    if catalogIsLoading {
                        Text(L("正在读取内置价格…", "Loading bundled rates…"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    } else if subscription {
                        Text(L("订阅内用量 · 无按量 API 费用", "Included usage · no metered API charge"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    } else if let r = custom?.peak {
                        Text(L("输入 \(rate(r.input, currency)) · 输出 \(rate(r.output, currency))", "Input \(rate(r.input, currency)) · output \(rate(r.output, currency))"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    } else if let r = builtin?.base, !subscription {
                        Text(L("输入 \(rate(r.input, currency)) · 输出 \(rate(r.output, currency))", "Input \(rate(r.input, currency)) · output \(rate(r.output, currency))"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pricing.model." + model)
            .accessibilityValue(isOpen ? L("已展开", "Expanded") : L("已折叠", "Collapsed"))
            if isOpen {
                Divider().opacity(0.5)
                if catalogIsLoading {
                    Text(L("正在读取内置价格…", "Loading bundled rates…"))
                        .font(VG.caption).foregroundStyle(.secondary)
                } else if subscription {
                    Text(L("网页订阅调用没有按量 API 费用，应用按订阅内用量记录。", "Web subscription calls have no metered API charge and are recorded as included usage."))
                        .font(VG.caption).foregroundStyle(.secondary)
                } else if let r = custom?.peak {
                    rateGrid(input: r.input, read: r.cacheRead, write: r.cacheWrite, output: r.output, currency: currency)
                    Text(auto ? L("models.dev · \(syncedAt) · 自动参考价", "models.dev · \(syncedAt) · synced reference rates")
                         : L("按你的覆盖单价与 Fast 规则计算，不额外继承内置长上下文倍率。", "Uses your custom rates and Fast rule, without inheriting built-in long-context multipliers."))
                        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let factor = custom?.fastMultiplier, factor > 1 {
                        Text(L("Fast / priority ×\(String(format: "%g", factor)) · 峰时与非峰时均适用", "Fast / priority ×\(String(format: "%g", factor)) · applies to peak and off-peak rates"))
                            .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        rateGrid(input: r.input * factor, read: r.cacheRead * factor,
                                 write: r.cacheWrite * factor, output: r.output * factor, currency: currency)
                    } else {
                        Text(L("Fast 不额外加价（当前覆盖规则）", "No additional Fast surcharge under this override"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    }
                    if let off = custom?.offpeak {
                        Text(L("非峰时", "Off-peak")).font(VG.caption).foregroundStyle(.secondary)
                        rateGrid(input: off.input, read: off.cacheRead, write: off.cacheWrite, output: off.output, currency: currency)
                        Text(L("峰谷时区：\(user.peak.timeZone.identifier)", "Peak-rate timezone: \(user.peak.timeZone.identifier)"))
                            .font(VG.caption).foregroundStyle(.secondary)
                        if user.peak.weekdays == Set([2, 3, 4, 5, 6]) {
                            Text(L("仅周一至周五的配置窗口为峰时；周末和例外日为空闲价。", "Peak windows apply Monday–Friday; weekends and configured exceptions use off-peak rates."))
                                .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let calendarYear {
                            Text(L("节假日例外日历：\(calendarYear) 年放假安排", "Holiday exceptions: \(calendarYear) public-holiday calendar"))
                                .font(VG.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let key = userKey, let raw = references[key], let source = URL(string: raw) {
                        Link(L("参考来源 · \(referenceDates[key] ?? "")", "Reference source · \(referenceDates[key] ?? "")"), destination: source).font(VG.caption)
                    } else if let officialURL {
                        Link(L("对照官方参考价（当前仍按覆盖价）", "Compare official rates (your override still applies)"), destination: officialURL).font(VG.caption)
                    }
                } else if let e = builtin {
                    rateGrid(input: e.base.input, read: e.base.cacheRead ?? e.base.input,
                             write: e.base.cacheWrite ?? e.base.input, output: e.base.output, currency: currency)
                    if let oneHour = e.base.cacheWrite1h {
                        Text(L("1 小时缓存写：\(rate(oneHour, currency)) / 百万 token", "1-hour cache write: \(rate(oneHour, currency)) / million tokens"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    }
                    if let long = e.long {
                        Text(L("输入超过 \(formatTokens(e.longThreshold))：整次请求按长上下文价计算。", "Above \(formatTokens(e.longThreshold)) input tokens, the full request uses long-context rates."))
                            .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        rateGrid(input: long.input, read: long.cacheRead ?? long.input,
                                 write: long.cacheWrite ?? long.input, output: long.output, currency: currency)
                    }
                    if e.priority != nil || e.fastMultiplier != 1 {
                        Text(L("Fast / priority · 短上下文", "Fast / priority · short context"))
                            .font(VG.caption).foregroundStyle(.secondary)
                        rateGrid(input: PricingCatalog.cost(e, ctx: 1, cacheRead: 0, cacheWrite: 0, out: 0, tier: "fast") * 1_000_000,
                                 read: PricingCatalog.cost(e, ctx: 1, cacheRead: 1, cacheWrite: 0, out: 0, tier: "fast") * 1_000_000,
                                 write: PricingCatalog.cost(e, ctx: 1, cacheRead: 0, cacheWrite: 1, out: 0, tier: "fast") * 1_000_000,
                                 output: PricingCatalog.cost(e, ctx: 0, cacheRead: 0, cacheWrite: 0, out: 1, tier: "fast") * 1_000_000,
                                 currency: currency)
                        Text(L("Fast / priority 使用对应加速价，长上下文规则仍适用。", "Fast / priority uses accelerated rates and still applies long-context rules."))
                            .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let officialURL {
                        Link(L("查看官方定价", "Official pricing"), destination: officialURL).font(VG.caption)
                    } else {
                        Text(L("社区参考目录 · \(catalog.asOf)", "Community reference catalog · \(catalog.asOf)"))
                            .font(VG.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("没有可确认的单价，未计入费用。可通过同步补齐，或填写自定义价格。", "No confirmed rate; excluded from cost totals. Try syncing or add a custom rate."))
                        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rateGrid(input: Double, read: Double, write: Double, output: Double, currency: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: VG.scale > 1.1 ? 2 : 4), alignment: .leading, spacing: 8) {
            rateCell(L("输入", "Input"), input, currency)
            rateCell(L("缓存读", "Cache read"), read, currency)
            rateCell(L("缓存写", "Cache write"), write, currency)
            rateCell(L("输出", "Output"), output, currency)
        }
    }

    private func rateCell(_ title: String, _ value: Double, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(VG.caption).foregroundStyle(.secondary)
            Text(rate(value, currency)).font(VG.number(11)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ value: Double, _ currency: String) -> String {
        let number = String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return (currency == "USD" ? "$" : currency == "CNY" ? "¥" : currency + " ") + number
    }

    private struct UserPriceSnapshot {
        var table: ProcessScanner.PriceTable
        var automatic: Set<String>
        var syncedAt: String
        var references: [String: String]
        var referenceDates: [String: String]
        var calendarYear: Int?
        var loadError: String
    }

    /// Disk IO and JSON/PriceTable parsing stay off the menu's main thread.
    private static func loadUserPrices(at path: String) -> UserPriceSnapshot {
        let exists = FileManager.default.fileExists(atPath: path)
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let table = json.map { ProcessScanner.PriceTable(json: $0) } ?? ProcessScanner.PriceTable()
        let sync = json?["_sync"] as? [String: Any] ?? [:]
        let rows = sync["rows"] as? [String: Any] ?? [:]
        let automatic = Set(rows.keys.filter { key in
            guard sync["source"] as? String == PriceSync.sourceName,
                  let current = json?[key] as? [String: Any], let original = rows[key] as? [String: Any] else { return false }
            return NSDictionary(dictionary: current).isEqual(to: original)
        }.map { $0.lowercased() })
        var references: [String: String] = [:]
        var referenceDates: [String: String] = [:]
        for (model, raw) in json ?? [:] where !model.hasPrefix("_") {
            guard let row = raw as? [String: Any] else { continue }
            if let source = row["source"] as? String, URL(string: source)?.scheme == "https" { references[model.lowercased()] = source }
            if let date = row["asof"] as? String { referenceDates[model.lowercased()] = date }
        }
        return UserPriceSnapshot(
            table: table,
            automatic: automatic,
            syncedAt: String((sync["at"] as? String ?? "").prefix(10)),
            references: references,
            referenceDates: referenceDates,
            calendarYear: (json?["_peak"] as? [String: Any])?["calendar_year"] as? Int,
            loadError: exists && json == nil
                ? L("自定义价表读不到，暂用内置参考价。", "Custom rates could not be read; showing built-in reference rates.")
                : ""
        )
    }

    private func reload(force: Bool = false) {
        guard force || priceLoadGeneration == 0 else { return }
        priceLoadGeneration += 1
        let generation = priceLoadGeneration
        isLoadingUserPrices = true
        let path = PriceSync.pricesPath(home: FileManager.default.homeDirectoryForCurrentUser.path)
        DispatchQueue.global(qos: .utility).async {
            _ = PricingCatalog.builtin
            let snapshot = Self.loadUserPrices(at: path)
            DispatchQueue.main.async {
                guard self.priceLoadGeneration == generation else { return }
                self.user = snapshot.table
                self.automatic = snapshot.automatic
                self.syncedAt = snapshot.syncedAt
                self.references = snapshot.references
                self.referenceDates = snapshot.referenceDates
                self.calendarYear = snapshot.calendarYear
                self.loadError = snapshot.loadError
                self.hasLoadedUserPrices = true
                self.isLoadingUserPrices = false
            }
        }
    }

    private var syncDisplayMessage: String {
        guard syncMessage.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return syncMessage }
        return L(syncMessage, syncFailed ? "Price sync failed; see details on hover" : "Price sync completed; see details on hover")
    }

    private func beginSync() {
        syncing = true
        syncMessage = ""
        syncPrices { message, succeeded in
            syncing = false
            syncFailed = !succeeded
            syncMessage = message
            reload(force: true)
        }
    }
}
