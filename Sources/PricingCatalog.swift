import Foundation

/// 随 App 分发的 API 参考价（`prices.builtin.json`）；具体来源和核实日期见资源元数据。
/// 已核实的 OpenAI / Claude 模型以官方文档为准；其他模型保留已有参考价，用户价永远优先。
/// 用户 prices.json 里有的行永远优先 —— 内置价只是「没配也能看到金额」的兜底，面板一律标「估算」。
public enum PricingCatalog {
    /// 一套单价（USD / 百万 token）。
    public struct Rate: Equatable {
        public var input = 0.0
        public var output = 0.0
        public var cacheRead: Double? = nil
        public var cacheWrite: Double? = nil
        public var cacheWrite1h: Double? = nil
    }

    public struct Entry: Equatable {
        public var base = Rate()
        /// 长上下文档：整次请求的输入超过门槛，整单按这一档算（不是边际计价）。
        public var longThreshold: Int64 = 0
        public var long: Rate? = nil
        /// OpenAI priority（Codex fast mode）明码价。
        public var priority: Rate? = nil
        /// 没有明码 priority 价时的倍率（Claude fast / 部分 GPT）。1 = 不加价。
        public var fastMultiplier = 1.0
    }

    public struct Catalog {
        public var entries: [String: Entry] = [:]
        public var aliases: [String: String] = [:]
        public var asOf = ""
        public var source = ""
        public var verifiedOpenAIAsOf = ""
        public var verifiedOpenAISources: [String: String] = [:]
        public var verifiedAnthropicAsOf = ""
        public var verifiedAnthropicSources: [String: String] = [:]
        public var verifiedSources: [String: String] {
            verifiedOpenAISources.merging(verifiedAnthropicSources) { current, _ in current }
        }
        public var isEmpty: Bool { entries.isEmpty }
    }

    private static let lock = NSLock()
    private static var cached: Catalog?
    private static let loadLock = NSLock()

    /// Display readers use only this snapshot; a cold bundle load never holds its lock.
    public static var cachedBuiltin: Catalog? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 随 App 分发的内置价。读不到（例如脱离 bundle 跑）就是空表，调用方回落到「未定价」。
    public static var builtin: Catalog {
        if let c = cachedBuiltin { return c }
        loadLock.lock(); defer { loadLock.unlock() }
        if let c = cachedBuiltin { return c }
        var c = Catalog()
        if let url = Bundle.main.url(forResource: "prices.builtin", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            c = parse(json)
        }
        lock.lock()
        cached = c
        lock.unlock()
        return c
    }

    /// 纯函数：解析内置价 JSON（自测也走这里）。
    public static func parse(_ json: [String: Any]) -> Catalog {
        var c = Catalog()
        c.asOf = json["_asof"] as? String ?? ""
        c.source = json["_source"] as? String ?? ""
        c.verifiedOpenAIAsOf = json["_verified_openai_asof"] as? String ?? ""
        c.verifiedOpenAISources = json["_verified_openai_sources"] as? [String: String] ?? [:]
        c.verifiedAnthropicAsOf = json["_verified_anthropic_asof"] as? String ?? ""
        c.verifiedAnthropicSources = json["_verified_anthropic_sources"] as? [String: String] ?? [:]
        for (k, v) in (json["_aliases"] as? [String: String]) ?? [:] { c.aliases[k.lowercased()] = v.lowercased() }
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func rate(_ d: [String: Any], fallback: Rate? = nil) -> Rate {
            var r = Rate()
            r.input = num(d, "in") ?? fallback?.input ?? 0
            r.output = num(d, "out") ?? fallback?.output ?? 0
            r.cacheRead = num(d, "cr") ?? fallback?.cacheRead
            r.cacheWrite = num(d, "cw") ?? fallback?.cacheWrite
            r.cacheWrite1h = num(d, "cw1h") ?? fallback?.cacheWrite1h
            return r
        }
        for (key, raw) in json where !key.hasPrefix("_") {
            guard let d = raw as? [String: Any] else { continue }
            var e = Entry()
            e.base = rate(d)
            guard e.base.input > 0 || e.base.output > 0 else { continue }
            if let lc = d["lc"] as? [String: Any], let threshold = num(lc, "threshold"), threshold > 0 {
                e.longThreshold = Int64(threshold)
                var long = rate(lc, fallback: e.base)
                if let cw1h = e.base.cacheWrite1h, let base = e.base.cacheWrite, let lcw = long.cacheWrite, base > 0 {
                    long.cacheWrite1h = cw1h * lcw / base
                }
                e.long = long
            }
            if let p = d["pri"] as? [String: Any] { e.priority = rate(p, fallback: nil) }
            e.fastMultiplier = num(d, "fast") ?? 1
            c.entries[key.lowercased()] = e
        }
        return c
    }

    // Only the pure string conversion is memoized; prices and catalog lookups
    // remain live. NSCache is thread-safe and can discard results under pressure.
    private static let normalizationCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4096
        cache.totalCostLimit = 1024 * 1024
        return cache
    }()

    /// 把日志里的各种写法归一：去 provider 前缀、`[1m]`、`@区域`、日期后缀；Claude 的 `4.5` 写成 `4-5`。
    public static func normalize(_ raw: String) -> String {
        let key = raw as NSString
        if let normalized = normalizationCache.object(forKey: key) { return normalized as String }
        var m = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        if let at = m.firstIndex(of: "@") { m = String(m[..<at]) }
        if m.hasPrefix("claude") { m = m.replacingOccurrences(of: ".", with: "-") }
        for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-v\d+(:\d+)?$"#] {
            if let r = m.range(of: pattern, options: .regularExpression) { m.removeSubrange(r) }
        }
        normalizationCache.setObject(m as NSString, forKey: key, cost: (raw.utf16.count + m.utf16.count) * 2)
        return m
    }

    static func normalizationSelfTest() {
        let fixtures = [
            ("anthropic/claude-opus-4.5-20251101[1m]", "claude-opus-4-5"),
            ("  OPENAI/GPT-6.1-SOL@us-east  ", "gpt-6.1-sol"),
            ("provider/custom-model-2026-10-23", "custom-model"),
            ("provider/custom-model-v12:3", "custom-model"),
            ("unknown-model-high", "unknown-model-high"),
            ("", ""), ("  ", ""), ("厂商/自定义模型", "自定义模型")
        ]
        for (raw, expected) in fixtures {
            precondition(normalize(raw) == expected)
            precondition(normalize(raw) == expected, "Cached normalization must preserve the original result")
        }
        let model = "normalization-price-fixture"
        var catalog = Catalog()
        catalog.entries[model] = Entry(base: Rate(input: 1, output: 2))
        var engine = CostEngine(catalog: catalog)
        func value(_ engine: CostEngine) -> Double? {
            engine.cost(model: model, ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0)?.value
        }
        precondition(value(engine) == 1)
        engine.catalog.entries[model]?.base.input = 3
        precondition(value(engine) == 3, "Warm model names must not retain an old catalog price")
        engine.user = ProcessScanner.PriceTable(json: ["_currency": "CNY", model: ["in": 7, "out": 2]])
        precondition(value(engine) == 7)
        engine.user = ProcessScanner.PriceTable(json: ["_currency": "CNY", model: ["in": 11, "out": 2]])
        precondition(value(engine) == 11, "Warm model names must not retain an old user price")
        let unknown = "normalization-unknown-fixture"
        precondition(entry(for: unknown, in: catalog) == nil)
        catalog.entries[unknown] = Entry(base: Rate(input: 5, output: 2))
        precondition(entry(for: unknown, in: catalog)?.base.input == 5, "Unknown names must not cache a missing price")
    }

    /// 查价：别名 → 精确 → 日志里的已知模式后缀。独立模型不能借用同族价格。
    public static func entry(for model: String, in catalog: Catalog = builtin) -> Entry? {
        guard !catalog.isEmpty else { return nil }
        var m = normalize(model)
        if let alias = catalog.aliases[m] { m = alias }
        if let exact = catalog.entries[m] { return exact }
        let modes = ["low", "medium", "high", "xhigh", "max", "fast", "thinking", "thinking-max"]
        let hit = catalog.entries.keys.filter { key in
            guard m.hasPrefix(key + "-") else { return false }
            let suffix = String(m.dropFirst(key.count + 1))
            return modes.contains(suffix) || (key.hasPrefix("gemini-") && suffix == "preview")
        }.max { $0.count < $1.count }
        return hit.flatMap { catalog.entries[$0] }
    }

    /// 一次请求的 API 等价成本（USD）。ctx = 全部输入（新鲜 + 缓存读 + 缓存写，缓存写含 1h 那部分）。
    /// tier：Codex 的 `priority`/`fast`、Claude 的 `fast`；其他值按标准价。
    public static func cost(_ e: Entry, ctx: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64 = 0,
                            out: Int64, tier: String? = nil) -> Double {
        let longContext = e.long != nil && e.longThreshold > 0 && ctx > e.longThreshold
        var r = longContext ? (e.long ?? e.base) : e.base
        var multiplier = 1.0
        let fast = ["priority", "fast"].contains((tier ?? "").lowercased())
        if fast {
            if let p = e.priority {
                // 明码 Fast 价已经包含加价；仅叠加各项长上下文比例，不能再乘 fastMultiplier。
                let inputFactor = p.input / max(e.base.input, 1e-12)
                let outputFactor = p.output / max(e.base.output, 1e-12)
                func cacheRate(_ standard: Double?, _ base: Double?, _ priority: Double?) -> Double? {
                    guard let standard else { return nil }
                    if let priority, let base, base > 0 { return standard * priority / base }
                    return standard * inputFactor
                }
                r = Rate(input: r.input * inputFactor, output: r.output * outputFactor,
                         cacheRead: cacheRate(r.cacheRead, e.base.cacheRead, p.cacheRead),
                         cacheWrite: cacheRate(r.cacheWrite, e.base.cacheWrite, p.cacheWrite),
                         cacheWrite1h: cacheRate(r.cacheWrite1h, e.base.cacheWrite1h, p.cacheWrite1h))
            } else {
                multiplier = e.fastMultiplier
            }
        }
        let w1h = max(0, min(cacheWrite1h, cacheWrite))
        let w5m = max(0, cacheWrite - w1h)
        let fresh = max(0, ctx - cacheRead - cacheWrite)
        let cr = r.cacheRead ?? r.input
        let cw = r.cacheWrite ?? r.input
        let cw1h = r.cacheWrite1h ?? r.input * 2
        let usd = Double(fresh) * r.input + Double(cacheRead) * cr + Double(w5m) * cw + Double(w1h) * cw1h + Double(out) * r.output
        return usd / 1_000_000 * multiplier
    }
}

/// 定价引擎：用户 prices.json（手填 / models.dev 同步）优先，其次内置官方价。
/// 返回 nil = 两边都没有，面板显示「未定价」，绝不瞎估。
public struct CostEngine {
    public var user: ProcessScanner.PriceTable
    public var catalog: PricingCatalog.Catalog

    public init(user: ProcessScanner.PriceTable = ProcessScanner.PriceTable(), catalog: PricingCatalog.Catalog = PricingCatalog.builtin) {
        self.user = user
        self.catalog = catalog
    }

    public enum Origin { case user, builtin }

    public func origin(for model: String) -> Origin? {
        if user.cost(model: model, ctx: 0, cacheRead: 0, cacheWrite: 0, out: 0) != nil { return .user }
        if PricingCatalog.entry(for: model, in: catalog) != nil { return .builtin }
        return nil
    }

    /// ChatGPT 网页订阅里的请求（chatgpt-web/*）：包含在订阅费里，没有按量成本，记 0 而不是「未定价」。
    public static func isSubscriptionIncluded(_ model: String) -> Bool { model.lowercased().hasPrefix("chatgpt-web/") }

    public func isPriced(_ model: String) -> Bool { Self.isSubscriptionIncluded(model) || origin(for: model) != nil }

    public func cost(model: String, ctx: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64 = 0,
                     out: Int64, tier: String? = nil, at: Date? = nil) -> (value: Double, currency: String)? {
        if Self.isSubscriptionIncluded(model) { return (0, "USD") }
        if let v = user.cost(model: model, ctx: ctx, cacheRead: cacheRead, cacheWrite: cacheWrite, out: out, at: at, tier: tier) {
            return (v, user.currency(for: model))
        }
        guard let e = PricingCatalog.entry(for: model, in: catalog) else { return nil }
        return (PricingCatalog.cost(e, ctx: ctx, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h,
                                    out: out, tier: tier), "USD")
    }
}

public extension CostEngine {
    /// API-equivalent value is independent of subscription billing (whose existing cost remains zero).
    /// Unknown models remain unknown; no family substitution or implicit currency conversion.
    func equivalentCost(model: String, ctx: Int64, cacheRead: Int64, cacheWrite: Int64,
                        cacheWrite1h: Int64 = 0, out: Int64, tier: String? = nil,
                        at: Date? = nil) -> (value: Double, currency: String)? {
        let apiModel = Self.isSubscriptionIncluded(model) ? String(model.dropFirst("chatgpt-web/".count)) : model
        if let value = user.cost(model: model, ctx: ctx, cacheRead: cacheRead, cacheWrite: cacheWrite, out: out, at: at, tier: tier) {
            return (value, user.currency(for: model))
        }
        if apiModel != model, let value = user.cost(model: apiModel, ctx: ctx, cacheRead: cacheRead, cacheWrite: cacheWrite, out: out, at: at, tier: tier) {
            return (value, user.currency(for: apiModel))
        }
        guard let entry = PricingCatalog.entry(for: apiModel, in: catalog) else { return nil }
        return (PricingCatalog.cost(entry, ctx: ctx, cacheRead: cacheRead, cacheWrite: cacheWrite,
                                    cacheWrite1h: cacheWrite1h, out: out, tier: tier), "USD")
    }
}
