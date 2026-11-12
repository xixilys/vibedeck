import Foundation

/// Account bookkeeping uses API-equivalent values; it never changes subscription billing totals.
public struct AccountUsagePoint: Equatable {
    public var timestamp: TimeInterval
    public var source: String
    public var model: String
    public var account: AccountIdentity?
    public var pool: String
    public var usage: UsageHistory.ModelTotals
    public var requests: Int
    public var unpricedRequests: Int
    public var exactRequestID: String?
    public var origin: String
    public var timestampResolution: TimeInterval = 0
    /// One request is billed in exactly one currency. Keeping a dictionary per point allocated ~590k
    /// one-entry dictionaries on a 600k-row ledger; currency + value carries the same information.
    public var costCurrency: String = ""
    public var costValue: Double = 0

    public var equivalentCostByCurrency: [String: Double] {
        get { costCurrency.isEmpty ? [:] : [costCurrency: costValue] }
        set {
            if let entry = newValue.first { costCurrency = entry.key; costValue = entry.value }
            else { costCurrency = ""; costValue = 0 }
        }
    }

    /// Zero-allocation convenience for the collectors, which already hold the cost as a single pair.
    public init(timestamp: TimeInterval, source: String, model: String, account: AccountIdentity?, pool: String,
                usage: UsageHistory.ModelTotals, requests: Int, cost: (value: Double, currency: String)?,
                unpricedRequests: Int, exactRequestID: String?, origin: String, timestampResolution: TimeInterval = 0) {
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.account = account
        self.pool = pool
        self.usage = usage
        self.requests = requests
        self.unpricedRequests = unpricedRequests
        self.exactRequestID = exactRequestID
        self.origin = origin
        self.timestampResolution = timestampResolution
        self.costCurrency = cost?.currency ?? ""
        self.costValue = cost?.value ?? 0
    }

    public init(timestamp: TimeInterval, source: String, model: String, account: AccountIdentity?, pool: String,
                usage: UsageHistory.ModelTotals, requests: Int, equivalentCostByCurrency: [String: Double],
                unpricedRequests: Int, exactRequestID: String?, origin: String, timestampResolution: TimeInterval = 0) {
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.account = account
        self.pool = pool
        self.usage = usage
        self.requests = requests
        self.unpricedRequests = unpricedRequests
        self.exactRequestID = exactRequestID
        self.origin = origin
        self.timestampResolution = timestampResolution
        self.costCurrency = ""
        self.costValue = 0
        if let entry = equivalentCostByCurrency.first { costCurrency = entry.key; costValue = entry.value }
    }
}

public struct AccountUsageTotals: Equatable {
    public var usage = UsageHistory.ModelTotals()
    public var requests = 0
    public var equivalentCostByCurrency: [String: Double] = [:]
    public var unpricedRequests = 0
    public init() {}
    init(usage: UsageHistory.ModelTotals, requests: Int, equivalentCostByCurrency: [String: Double], unpricedRequests: Int) {
        self.usage = usage; self.requests = requests
        self.equivalentCostByCurrency = equivalentCostByCurrency; self.unpricedRequests = unpricedRequests
    }
    mutating func add(_ point: AccountUsagePoint) {
        usage.add(point.usage); requests += point.requests; unpricedRequests += point.unpricedRequests
        if !point.costCurrency.isEmpty { equivalentCostByCurrency[point.costCurrency, default: 0] += point.costValue }
    }
    mutating func merge(_ other: AccountUsageTotals) {
        usage.add(other.usage); requests += other.requests; unpricedRequests += other.unpricedRequests
        for (currency, value) in other.equivalentCostByCurrency { equivalentCostByCurrency[currency, default: 0] += value }
    }
    mutating func subtract(_ other: AccountUsageTotals) {
        usage.subtract(other.usage); requests -= other.requests; unpricedRequests -= other.unpricedRequests
        for (currency, value) in other.equivalentCostByCurrency {
            let left = (equivalentCostByCurrency[currency] ?? 0) - value
            if abs(left) < 0.000_000_1 { equivalentCostByCurrency[currency] = nil } else { equivalentCostByCurrency[currency] = left }
        }
    }
    mutating func subtract(_ point: AccountUsagePoint) {
        usage.subtract(point.usage); requests -= point.requests; unpricedRequests -= point.unpricedRequests
        guard !point.costCurrency.isEmpty else { return }
        let left = (equivalentCostByCurrency[point.costCurrency] ?? 0) - point.costValue
        if abs(left) < 0.000_000_1 { equivalentCostByCurrency[point.costCurrency] = nil }
        else { equivalentCostByCurrency[point.costCurrency] = left }
    }
}

public struct AccountUsageGroup: Equatable, Identifiable {
    public var id: String
    public var account: AccountIdentity?
    public var totals = AccountUsageTotals()
    /// Accounting planes: native CLI logs, the CPA relay (other machines on the same login) and the local proxy.
    /// CLI + CPA are added — they record different requests; the proxy plane mirrors CLI calls and stays separate.
    public var byOrigin: [String: AccountUsageTotals] = [:]
    public var primaryOrigin = "cli"
    /// Device/tool totals retain each device's observation, even if account totals deduplicate a copied request.
    public var bySource: [String: AccountUsageTotals] = [:]
    public var firstObservedAt: TimeInterval
    public var lastObservedAt: TimeInterval
}

/// All published snapshots share one ledger object. Without this, each UI/state snapshot kept its own
/// 146 MB array, and three generations of snapshots meant three full ledgers in the process.
public final class AccountPointLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountUsagePoint]

    public init(_ points: [AccountUsagePoint] = []) { storage = points }

    public var points: [AccountUsagePoint] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}

public struct AccountUsageSnapshot: Equatable {
    public var groups: [AccountUsageGroup] = []
    /// One shared ledger, not a per-snapshot copy. Mutating scans replace the ledger contents in place.
    public var ledger = AccountPointLedger()
    public var points: [AccountUsagePoint] {
        get { ledger.points }
        set { ledger.points = newValue }
    }
    public var unassigned = AccountUsageTotals()
    /// Today's observed device/tool usage, API-equivalent valued. Each source selects cli, then cpa, then proxy
    /// (a source is one tool on one machine, so its planes describe the same requests). Original currencies and
    /// unpriced requests are retained.
    public var todayBySource: [String: AccountUsageTotals] = [:]
    /// Same selection as todayBySource, bucketed by local hour: source → currency → 24 API-equivalent amounts.
    public var todayHourlyBySource: [String: [String: [Double]]] = [:]
    /// Observed collection baseline, max across known devices; only published while their collection is healthy.
    /// This is coverage of collected devices, not proof that no other device uses the provider account.
    public var coverageStartByAccount: [String: TimeInterval] = [:]
    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groups == rhs.groups && lhs.points == rhs.points && lhs.unassigned == rhs.unassigned
            && lhs.todayBySource == rhs.todayBySource && lhs.todayHourlyBySource == rhs.todayHourlyBySource
            && lhs.coverageStartByAccount == rhs.coverageStartByAccount
    }
    public static func aggregate(points: [AccountUsagePoint], duplicates: [AccountUsagePoint] = [],
                                 alreadyDeduplicated: Bool = false,
                                 now: Date = Date(), calendar: Calendar = .current) -> Self {
        var result = Self()
        let today = calendar.dateInterval(of: .day, for: now)
        let asOf = now.timeIntervalSince1970
        var todayByOrigin: [String: [String: AccountUsageTotals]] = [:]
        var hourlyByOrigin: [String: [String: [String: [Double]]]] = [:]
        var sourceOrigins: [String: Set<String>] = [:]
        result.points = alreadyDeduplicated ? points : AccountUsage.deduplicated(points)
        // Per-device detail answers where tokens were observed; account total answers unique known requests.
        // Raw observations = the folded ledger plus the copies that lost the dedup, so device totals keep
        // every device's own observation without a second full copy of the ledger.
        var groups: [String: AccountUsageGroup] = [:]
        func observe(_ point: AccountUsagePoint) {
            let key = point.account?.key ?? "unassigned:" + point.source
            groups[key]?.bySource[point.source, default: AccountUsageTotals()].add(point)
            sourceOrigins[point.source, default: []].insert(point.origin)
            if let today, point.timestamp.isFinite, point.timestamp >= today.start.timeIntervalSince1970,
               point.timestamp < today.end.timeIntervalSince1970, point.timestamp <= asOf {
                todayByOrigin[point.source, default: [:]][point.origin, default: AccountUsageTotals()].add(point)
                let hour = max(0, min(23, Int((point.timestamp - today.start.timeIntervalSince1970) / 3600)))
                if !point.costCurrency.isEmpty, point.costValue.isFinite {
                    hourlyByOrigin[point.source, default: [:]][point.origin, default: [:]][point.costCurrency, default: Array(repeating: 0, count: 24)][hour] += point.costValue
                }
            }
        }
        // Folded ledger with nothing dropped: the raw observations are exactly those rows, so one pass can
        // build both account and per-device views instead of walking 600k structs twice.
        let combined = alreadyDeduplicated && duplicates.isEmpty
        for point in result.points {
            let key = point.account?.key ?? "unassigned:" + point.source
            var group = groups[key] ?? AccountUsageGroup(id: key, account: point.account,
                firstObservedAt: point.timestamp, lastObservedAt: point.timestamp)
            group.byOrigin[point.origin, default: AccountUsageTotals()].add(point)
            group.firstObservedAt = min(group.firstObservedAt, point.timestamp)
            group.lastObservedAt = max(group.lastObservedAt, point.timestamp)
            groups[key] = group
            if point.account == nil && point.origin == "cli" { result.unassigned.add(point) }
            if combined { observe(point) }
        }
        if !combined {
            for point in points { observe(point) }
            for point in duplicates { observe(point) }
        }
        for (source, origins) in sourceOrigins {
            let primary = ["cli", "cpa", "proxy"].first { origins.contains($0) } ?? origins.sorted().first ?? "cli"
            if let totals = todayByOrigin[source]?[primary] { result.todayBySource[source] = totals }
            if let hourly = hourlyByOrigin[source]?[primary] { result.todayHourlyBySource[source] = hourly }
        }
        for key in groups.keys {
            let origins = groups[key]!.byOrigin
            let primary = ["cli", "cpa", "proxy"].first { origins[$0] != nil } ?? origins.keys.sorted().first ?? "cli"
            groups[key]?.primaryOrigin = primary
            // One login can be used from a machine's CLI logs and from the CPA relay; those are different requests
            // of the same account and are added. The local proxy mirrors CLI traffic, so that plane stays out.
            var total = AccountUsageTotals()
            for origin in ["cli", "cpa"] where origins[origin] != nil { total.merge(origins[origin]!) }
            groups[key]?.totals = total.requests > 0 ? total : (origins[primary] ?? AccountUsageTotals())
        }
        result.groups = groups.values.sorted { a, b in
            if (a.account != nil) != (b.account != nil) { return a.account != nil }
            if a.totals.usage.tokenTotal != b.totals.usage.tokenTotal { return a.totals.usage.tokenTotal > b.totals.usage.tokenTotal }
            return a.id < b.id
        }
        return result
    }

    /// Fold historical groups into the snapshot produced from the recent ledger without recounting recent rows.
    public mutating func mergeHistorical(_ historical: [AccountUsageGroup], unassigned historicalUnassigned: AccountUsageTotals) {
        guard !historical.isEmpty || historicalUnassigned.requests > 0 else { return }
        var byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for row in historical {
            if var group = byID[row.id] {
                for (origin, totals) in row.byOrigin { group.byOrigin[origin, default: AccountUsageTotals()].merge(totals) }
                for (source, totals) in row.bySource { group.bySource[source, default: AccountUsageTotals()].merge(totals) }
                group.firstObservedAt = min(group.firstObservedAt, row.firstObservedAt)
                group.lastObservedAt = max(group.lastObservedAt, row.lastObservedAt)
                byID[row.id] = group
            } else { byID[row.id] = row }
        }
        groups = byID.values.map { original in
            var group = original
            let origins = group.byOrigin
            let primary = ["cli", "cpa", "proxy"].first { origins[$0] != nil } ?? origins.keys.sorted().first ?? "cli"
            group.primaryOrigin = primary
            var total = AccountUsageTotals()
            for origin in ["cli", "cpa"] where origins[origin] != nil { total.merge(origins[origin]!) }
            group.totals = total.requests > 0 ? total : (origins[primary] ?? AccountUsageTotals())
            return group
        }.sorted { a, b in
            if (a.account != nil) != (b.account != nil) { return a.account != nil }
            if a.totals.usage.tokenTotal != b.totals.usage.tokenTotal { return a.totals.usage.tokenTotal > b.totals.usage.tokenTotal }
            return a.id < b.id
        }
        unassigned.merge(historicalUnassigned)
    }
}

public struct AccountQuotaObservation: Codable, Equatable, Identifiable {
    public var account: AccountIdentity?
    public var source: String
    public var provider: String
    public var pool: String
    public var window: String
    public var startedAt: TimeInterval?
    public var resetAt: TimeInterval?
    public var capturedAt: TimeInterval
    public var usedPercent: Double
    public var trusted: Bool
    /// Devices/tools whose quota snapshots identify this same account/window. Never attributes their usage.
    public var associatedSources: [String]? = nil
    /// Oldest sampled reading of this same window (see QuotaWindow.baselineAt), for recent full-value estimates.
    public var baselineAt: TimeInterval? = nil
    public var baselinePercent: Double? = nil
    public init(account: AccountIdentity?, source: String, provider: String, pool: String, window: String,
                startedAt: TimeInterval? = nil, resetAt: TimeInterval? = nil, capturedAt: TimeInterval,
                usedPercent: Double, trusted: Bool = true, associatedSources: [String]? = nil,
                baselineAt: TimeInterval? = nil, baselinePercent: Double? = nil) {
        self.account = account; self.source = source; self.provider = provider; self.pool = pool; self.window = window
        self.startedAt = startedAt; self.resetAt = resetAt; self.capturedAt = capturedAt
        self.usedPercent = usedPercent; self.trusted = trusted; self.associatedSources = associatedSources
        self.baselineAt = baselineAt; self.baselinePercent = baselinePercent
    }
    public var id: String {
        [account?.key ?? "unassigned:" + source, provider, pool, window,
         startedAt.map { String($0) } ?? "?", resetAt.map { String($0) } ?? "?"].joined(separator: "\u{1e}")
    }
    var ownerKey: String { [source, provider, pool, window].joined(separator: "\u{1e}") }
}

public struct AccountCycleUsage: Equatable, Identifiable {
    public var id: String { observation.id }
    public var observation: AccountQuotaObservation
    /// Recorded spend for the whole cycle [start, min(now, reset)), including requests after the quota capture.
    public var consumed: AccountUsageTotals
    /// Matched spend at quota capture; only this value may be divided by that captured percentage.
    public var consumedAsOfCapture: AccountUsageTotals
    public var capacityUSD: Double?
    /// Coverage of the capacity numerator at capture: complete / partial / unknown.
    public var coverage: String
    public var isCurrent: Bool
}

/// Money view of one quota window, shown next to the official percentage.
/// `consumed` answers "how much of this refill is already gone" (API-equivalent, all accounting planes) and
/// `capacity` is the estimated value of the complete window. Percentages stay official; money is an estimate.
public struct QuotaWindowValue: Equatable {
    public var pool: String
    public var window: String
    /// Spend recorded inside this cycle [start, now), adding every accounting plane.
    public var consumedByCurrency: [String: Double] = [:]
    public var consumedRequests = 0
    public var consumedTokens: Int64 = 0
    /// Requests in the window whose model has no price; the money figures are a lower bound then.
    public var unpricedRequests = 0
    /// Spend inside this cycle per accounting plane (cli / cpa / proxy). The window total adds the planes, because
    /// this setup never routes a local CLI through the CPA relay, so no request is recorded on two planes.
    public var consumedByOrigin: [String: [String: Double]] = [:]
    /// Estimated value of the complete window in the same currencies.
    public var capacityByCurrency: [String: Double] = [:]
    /// Range covered by the per-device baseline estimates (tooltip only).
    public var estimateLowByCurrency: [String: Double] = [:]
    public var estimateHighByCurrency: [String: Double] = [:]
    /// "cycle" = whole window recorded; "recent" = median of baseline samples; "" = not estimable.
    public var basis = ""
    /// The plane that observed the most of the window (cli / cpa / proxy); the totals add the others.
    public var origin = "cli"
    public var usedPercent: Double = 0
    public var capturedAt: TimeInterval = 0
    public var startedAt: TimeInterval? = nil
    public var resetAt: TimeInterval? = nil
    /// The collection baseline covers this whole window. A partial cycle only proves a lower bound.
    public var covered = false
    /// Independent baseline samples that fed the estimate.
    public var samples = 0
    public var hasCapacity: Bool { capacityByCurrency.values.contains { $0.isFinite && $0 > 0 } }
}


public enum AccountUsage {
    /// All-time groups built from frozen buckets without materialising a second 500k-point array.
    /// Frozen rows are older than the rolling 7-day raw window, so they only feed lifetime totals and
    /// per-device detail; quota windows (5 h / week) never include them. Exact request IDs still fold
    /// copies across devices, exactly like `merge`.
    public struct HistoricalGroupBuilder {
        private var groups: [String: AccountUsageGroup] = [:]
        private var unassigned = AccountUsageTotals()
        private var seen: [DedupKey: (group: String, origin: String, usage: UsageHistory.ModelTotals, requests: Int,
                                     unpriced: Int, currency: String, cost: Double)] = [:]

        public init() {}

        public mutating func add(_ point: AccountUsagePoint) {
            let key = point.account?.key ?? "unassigned:" + point.source
            var group = groups[key] ?? AccountUsageGroup(id: key, account: point.account,
                firstObservedAt: point.timestamp, lastObservedAt: point.timestamp)
            group.bySource[point.source, default: AccountUsageTotals()].add(point)
            group.firstObservedAt = min(group.firstObservedAt, point.timestamp)
            group.lastObservedAt = max(group.lastObservedAt, point.timestamp)
            if point.account == nil && point.origin == "cli" { unassigned.add(point) }
            guard let account = point.account, let id = point.exactRequestID else {
                group.byOrigin[point.origin, default: AccountUsageTotals()].add(point)
                groups[key] = group
                return
            }
            let dedup = DedupKey(account: account.key, origin: point.origin,
                                 cli: UsageHistory.cli(of: point.source), pool: point.pool, id: id)
            if let old = seen[dedup] {
                let wins = point.usage.tokenTotal > old.usage.tokenTotal
                    || (point.usage.tokenTotal == old.usage.tokenTotal && point.unpricedRequests < old.unpriced)
                if wins {
                    // Replace the old winner in its own group/origin; the losing observation stays in bySource.
                    let previous = AccountUsageTotals(usage: old.usage, requests: old.requests,
                                                      equivalentCostByCurrency: old.currency.isEmpty ? [:] : [old.currency: old.cost],
                                                      unpricedRequests: old.unpriced)
                    if var oldGroup = groups[old.group], var totals = oldGroup.byOrigin[old.origin] {
                        totals.subtract(previous)
                        oldGroup.byOrigin[old.origin] = totals
                        groups[old.group] = oldGroup
                    }
                    group.byOrigin[point.origin, default: AccountUsageTotals()].add(point)
                    seen[dedup] = (key, point.origin, point.usage, point.requests, point.unpricedRequests,
                                   point.costCurrency, point.costValue)
                }
            } else {
                group.byOrigin[point.origin, default: AccountUsageTotals()].add(point)
                seen[dedup] = (key, point.origin, point.usage, point.requests, point.unpricedRequests,
                               point.costCurrency, point.costValue)
            }
            groups[key] = group
        }

        public mutating func finish() -> (groups: [AccountUsageGroup], unassigned: AccountUsageTotals) {
            for key in groups.keys {
                var group = groups[key]!
                let origins = group.byOrigin
                let primary = ["cli", "cpa", "proxy"].first { origins[$0] != nil } ?? origins.keys.sorted().first ?? "cli"
                group.primaryOrigin = primary
                // Same rule as aggregate: CLI and CPA record different requests of one login and are added;
                // the local proxy mirrors CLI traffic and stays a separate plane.
                var total = AccountUsageTotals()
                for origin in ["cli", "cpa"] where origins[origin] != nil { total.merge(origins[origin]!) }
                group.totals = total.requests > 0 ? total : (origins[primary] ?? AccountUsageTotals())
                groups[key] = group
            }
            let sorted = groups.values.sorted { a, b in
                if (a.account != nil) != (b.account != nil) { return a.account != nil }
                if a.totals.usage.tokenTotal != b.totals.usage.tokenTotal { return a.totals.usage.tokenTotal > b.totals.usage.tokenTotal }
                return a.id < b.id
            }
            return (sorted, unassigned)
        }
    }

    public static func pool(model: String, source: String) -> String {
        if CostEngine.isSubscriptionIncluded(model) { return "chatgpt-web" }
        let tool = UsageHistory.cli(of: source).lowercased()
        if tool == "codex" { return "codex" }
        // A CLIProxyAPI relay spends the same pools as the CLIs whose accounts it holds.
        if tool == "cpa" { return model.lowercased().contains("claude") ? "claude" : "codex" }
        if tool == "claude" { return "claude" }
        return tool
    }

    /// Only real provider request/response IDs may cross devices. Offsets and fallback UUIDs remain local.
    public static func exactRequestID(_ raw: String, source: String) -> String? {
        var id = raw
        let tool = UsageHistory.cli(of: source).lowercased()
        if id.hasPrefix(tool + ":") { id = String(id.dropFirst(tool.count + 1)) }
        if tool == "codex", id.hasPrefix("resp"), !id.hasPrefix("resp-off-") { return id }
        if tool == "claude", id.hasPrefix("req_") || id.hasPrefix("msg_") { return id }
        return nil
    }

    /// Identity used to fold copied requests. A struct key hashes without allocating a joined string —
    /// the old sort + string join over every identified row dominated the 2-minute ledger rebuild.
    struct DedupKey: Hashable {
        let account: String
        let origin: String
        let cli: String
        let pool: String
        let id: String
    }

    /// Appends one file's points into the ledger, folding duplicates as it goes. Building all points first
    /// and deduplicating into a second array kept two full 564k-row copies alive during every rebuild.
    /// `duplicates` keeps the losing observations so per-device totals stay raw.
    static func merge<S: Sequence>(_ chunk: S, into points: inout [AccountUsagePoint],
                                   indices: inout [DedupKey: Int], duplicates: inout [AccountUsagePoint])
    where S.Element == AccountUsagePoint {
        for point in chunk {
            guard let account = point.account, let id = point.exactRequestID else { points.append(point); continue }
            // CPA has no proven ID correlation with native CLI, so origins deliberately remain independent.
            let key = DedupKey(account: account.key, origin: point.origin,
                               cli: UsageHistory.cli(of: point.source), pool: point.pool, id: id)
            if let index = indices[key] {
                let old = points[index]
                if point.usage.tokenTotal > old.usage.tokenTotal ||
                    (point.usage.tokenTotal == old.usage.tokenTotal && point.unpricedRequests < old.unpricedRequests) {
                    points[index] = point
                    duplicates.append(old)
                } else {
                    duplicates.append(point)
                }
            } else { indices[key] = points.count; points.append(point) }
        }
    }

    public static func deduplicated(_ points: [AccountUsagePoint]) -> [AccountUsagePoint] {
        var kept: [AccountUsagePoint] = [], indices: [DedupKey: Int] = [:], droppedRows: [AccountUsagePoint] = []
        kept.reserveCapacity(points.count)
        indices.reserveCapacity(points.count)
        merge(points, into: &kept, indices: &indices, duplicates: &droppedRows)
        return kept
    }

    public static func cycle(observation: AccountQuotaObservation, points: [AccountUsagePoint],
                             coverageStart: TimeInterval? = nil, origin: String = "cli",
                             now: TimeInterval = Date().timeIntervalSince1970) -> AccountCycleUsage {
        let q = observation
        var result = AccountCycleUsage(observation: q, consumed: AccountUsageTotals(), consumedAsOfCapture: AccountUsageTotals(), capacityUSD: nil,
                                       coverage: "unknown", isCurrent: q.resetAt.map { now < $0 } ?? false)
        guard let identity = q.account, identity.provider == q.provider,
              let start = q.startedAt, let reset = q.resetAt, start.isFinite, reset.isFinite,
              start < reset, q.capturedAt.isFinite, q.capturedAt >= start, q.capturedAt < reset,
              q.capturedAt <= now, q.usedPercent.isFinite, q.usedPercent >= 0, q.usedPercent <= 100 else { return result }
        let end = min(now, reset)
        for point in deduplicated(points) where point.account == identity && point.pool == q.pool &&
            point.origin == origin && point.timestamp >= start {
            // Half-open reset boundaries put a request exactly at reset into the next cycle only.
            // A coarse bucket is included only if its complete time range fits the relevant interval.
            if point.timestamp < end && point.timestamp + point.timestampResolution <= end {
                result.consumed.add(point)
            }
            if point.timestamp + point.timestampResolution <= q.capturedAt {
                result.consumedAsOfCapture.add(point)
            }
        }
        let hasAmbiguousBoundary = points.contains {
            $0.account == identity && $0.pool == q.pool && $0.origin == origin && $0.timestampResolution > 0 &&
            $0.timestamp <= q.capturedAt && $0.timestamp + $0.timestampResolution > start &&
            ($0.timestamp < start || $0.timestamp + $0.timestampResolution > q.capturedAt)
        }
        // Unknown-account usage from a device/tool already contributing to this account may belong to it.
        // Unknown activity on unrelated devices or another accounting plane does not invalidate this account.
        let knownSources = Set(points.filter { $0.account == identity && $0.pool == q.pool && $0.origin == origin }.map { $0.source })
        let quotaSources = Set((q.associatedSources ?? []) + [q.source])
        let relatedSources = knownSources.union(quotaSources)
        // The scalar collection baseline covers usage sources. A quota-only device has no proven usage
        // collection baseline yet, so it keeps the account partial until attributed collection exists there.
        let quotaSourcesCovered = quotaSources.isSubset(of: knownSources)
        let hasUnassignedCandidate = points.contains {
            $0.account == nil && relatedSources.contains($0.source) && $0.pool == q.pool && $0.origin == origin &&
            $0.timestamp <= q.capturedAt && ($0.timestamp >= start || $0.timestamp + $0.timestampResolution > start)
        }
        let complete = coverageStart.map { $0 <= start } == true && !hasAmbiguousBoundary && !hasUnassignedCandidate && quotaSourcesCovered &&
            result.consumedAsOfCapture.unpricedRequests == 0 &&
            result.consumedAsOfCapture.equivalentCostByCurrency.keys.allSatisfy { $0 == "USD" }
        result.coverage = complete ? "complete" : "partial"
        guard complete, q.trusted, result.isCurrent, now - q.capturedAt <= 600, q.usedPercent > 0,
              let usd = result.consumedAsOfCapture.equivalentCostByCurrency["USD"], usd.isFinite, usd >= 0 else { return result }
        result.capacityUSD = usd / (q.usedPercent / 100)
        return result
    }

    /// sub2api-style full-value estimate: what the requests made since the window's baseline sample cost at
    /// API prices, divided by how many percent they used. Needs ≥ 3 points of movement over ≥ 15 minutes,
    /// so one rounding step can't swing it wildly. Original currencies are kept.
    /// `points` must already be deduplicated (`deduplicated(_:)`); callers do that once for all tiles.
    /// `origin` selects one accounting plane for callers that need a single channel (the whole-cycle ratio below
    /// sums every plane instead, because local CLIs never route through the CPA relay in this setup).
    public static func recentCapacity(_ q: AccountQuotaObservation, points: [AccountUsagePoint],
                                      origin: String = "cli") -> [String: Double]? {
        guard let start = q.baselineAt, let base = q.baselinePercent, start.isFinite, q.capturedAt - start >= 900,
              q.usedPercent.isFinite else { return nil }
        let delta = q.usedPercent - base
        guard delta >= 3 else { return nil }
        var spent: [String: Double] = [:]
        for point in points where point.origin == origin && point.timestamp > start && point.timestamp <= q.capturedAt {
            guard matchesQuota(point, quota: q) else { continue }
            if !point.costCurrency.isEmpty, point.costValue.isFinite { spent[point.costCurrency, default: 0] += point.costValue }
        }
        guard spent.values.reduce(0, +) > 0 else { return nil }
        return spent.mapValues { $0 / (delta / 100) }
    }

    /// One request's participation in a quota window: an identified account's pool, or an anonymous coding plan's
    /// shared key. Quota identity never attributes someone else's requests.
    ///
    /// Claude CLI logs carry no account id at all (every Claude row is anonymous), so the quota's own device is the
    /// only identity that can be proved: that device's anonymous requests join the account's spend, while another
    /// device's anonymous requests stay out. Without this fallback an identified Claude quota matches nothing.
    static func matchesQuota(_ point: AccountUsagePoint, quota: AccountQuotaObservation) -> Bool {
        if let account = quota.account {
            if point.account == account { return point.pool == quota.pool }
            return point.account == nil && point.pool == quota.pool && point.source == quota.source
        }
        // A coding plan's key is shared by every tool and device that calls its models.
        if quota.pool == "glm", point.model.lowercased().contains("glm") { return true }
        guard point.account == nil else { return false }
        if point.source == quota.source { return point.pool == quota.pool }
        // Same tool on the same device ("Codex" vs "Codex · wsl" are different devices).
        return point.pool == quota.pool &&
            UsageHistory.device(of: point.source) == UsageHistory.device(of: quota.source)
    }

    /// Provider reset jitter splits one physical window across samples; 10 minutes is the same cycle.
    static func sameQuotaCycle(_ a: TimeInterval?, _ b: TimeInterval?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return abs(x - y) <= 600
        case (nil, nil): return true
        default: return false
        }
    }

    public static func quotaWindowKey(pool: String, window: String) -> String {
        pool + "\u{1e}" + window
    }

    /// Lookup key for one window's money view. Accounts never share a key even when they share a pool.
    public static func valueKey(account: AccountIdentity?, pool: String, window: String) -> String {
        (account?.key ?? "\u{1f}anonymous") + "\u{1f}" + quotaWindowKey(pool: pool, window: window)
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Money view of one quota window: how much this cycle has consumed so far, and what the complete window is
    /// estimated to be worth. `consumed` covers [window start, now), so it answers "how much of this refill is
    /// gone" in API-equivalent money next to the official percentage. `capacity` prefers whole-cycle evidence
    /// (the whole window recorded → spend ÷ percent used); otherwise it is the median of the sub2api-style
    /// baseline estimates reported by every device that saw this same cycle, which keeps one noisy reading or
    /// one rounding step from moving the tile. Percentages are official; money is an estimate at API prices.
    public static func windowValues(quotas: [AccountQuotaObservation], points: [AccountUsagePoint],
                                    coverageStart: TimeInterval? = nil,
                                    alreadyDeduplicated: Bool = false,
                                    now: TimeInterval = Date().timeIntervalSince1970) -> [String: QuotaWindowValue] {
        guard !quotas.isEmpty else { return [:] }
        // The ledger snapshot is already deduplicated; re-sorting hundreds of thousands of rows per tile was the
        // expensive part of opening the panel.
        let unique = alreadyDeduplicated ? points : deduplicated(points)
        var grouped: [String: [AccountQuotaObservation]] = [:]
        for q in quotas where q.usedPercent.isFinite && q.usedPercent >= 0 && q.usedPercent <= 100
            && (q.resetAt.map { $0 > now } ?? true) {
            grouped[quotaWindowKey(pool: q.pool, window: q.window), default: []].append(q)
        }
        var result: [String: QuotaWindowValue] = [:]
        for (key, group) in grouped {
            // Newest trusted reading speaks for the tile; older readings still contribute their own baselines.
            guard let head = group.sorted(by: { a, b in
                if a.trusted != b.trusted { return !a.trusted }
                return a.capturedAt < b.capturedAt
            }).last else { continue }
            var value = QuotaWindowValue(pool: head.pool, window: head.window, usedPercent: head.usedPercent,
                                         capturedAt: head.capturedAt, startedAt: head.startedAt, resetAt: head.resetAt)
            let start = head.startedAt ?? group.compactMap(\.startedAt).filter(\.isFinite).min()
            let end = min(now, head.resetAt ?? now)
            func fits(_ point: AccountUsagePoint, from: TimeInterval, to: TimeInterval) -> Bool {
                point.timestamp.isFinite && point.timestamp >= from && point.timestamp < to &&
                    point.timestamp + max(0, point.timestampResolution) <= to
            }
            // A physical window is one provider reset. Another device can hold a *different* cycle of the same
            // account/pool (different reset), and its spend must not be attributed to this one.
            let cycle = group.filter { sameQuotaCycle($0.resetAt, head.resetAt) }
            // Match once; every later step (planes, coverage, capacity, baseline samples) reads the same set.
            // Indices keep hundreds of thousands of request structs from being copied again.
            var matched: [Int] = []
            for (index, point) in unique.enumerated() where cycle.contains(where: { matchesQuota(point, quota: $0) }) {
                matched.append(index)
            }
            // One plane for the whole window: the one that observed the most of its spend. Planes overlap, so
            // adding CLI and CPA records would charge the same requests twice; the relay is reported separately.
            var perOrigin: [String: (spend: [String: Double], requests: Int, tokens: Int64, unpriced: Int)] = [:]
            if let start {
                for index in matched where fits(unique[index], from: start, to: end) {
                    let point = unique[index]
                    var bucket = perOrigin[point.origin] ?? ([:], 0, 0, 0)
                    if !point.costCurrency.isEmpty, point.costValue.isFinite {
                        bucket.spend[point.costCurrency, default: 0] += point.costValue
                    }
                    bucket.requests += point.requests
                    bucket.tokens += point.usage.tokenTotal
                    bucket.unpriced += point.unpricedRequests
                    perOrigin[point.origin] = bucket
                }
            }
            let planeOrder = ["cli", "cpa", "proxy"]
            func rank(_ bucket: (spend: [String: Double], requests: Int, tokens: Int64, unpriced: Int)) -> (Int, Double, Int) {
                (bucket.spend["USD"] == nil ? 0 : 1,
                 bucket.spend["USD"] ?? bucket.spend.values.reduce(0, +), bucket.requests)
            }
            if let dominant = perOrigin.keys.sorted(by: { a, b in
                let ra = rank(perOrigin[a]!), rb = rank(perOrigin[b]!)
                if ra.0 != rb.0 { return ra.0 > rb.0 }
                if ra.1 != rb.1 { return ra.1 > rb.1 }
                if ra.2 != rb.2 { return ra.2 > rb.2 }
                return (planeOrder.firstIndex(of: a) ?? 9, a) < (planeOrder.firstIndex(of: b) ?? 9, b)
            }).first {
                // Local CLI traffic never goes through the CPA relay here, so the planes describe different
                // requests and are added. The breakdown stays visible in the tooltip and the detail page.
                value.origin = dominant
                for (origin, bucket) in perOrigin {
                    value.consumedByOrigin[origin] = bucket.spend
                    for (currency, amount) in bucket.spend where amount.isFinite {
                        value.consumedByCurrency[currency, default: 0] += amount
                    }
                    value.consumedRequests += bucket.requests
                    value.consumedTokens += bucket.tokens
                    value.unpricedRequests += bucket.unpriced
                }
            }
            // Coverage: the declared collection baseline, or (when a source has no account marker, as Claude's
            // logs have none) the oldest request this window's sources already carry. A window that predates all
            // of that only proves a lower bound, and its whole-cycle ratio must not be published.
            let declared = coverageStart
            let observedFirst = declared == nil ? matched.map { unique[$0].timestamp }.min() : nil
            value.covered = start.flatMap { windowStart in
                (declared ?? observedFirst).map { $0 > 0 && $0 <= windowStart }
            } ?? false
            // A stale reading is still a valid measurement of that moment: the whole-cycle ratio does not depend on
            // how recently the device reported. Falling back to a 6-hour baseline sample instead produced numbers
            // like a $6 weekly quota next to an 82%-used reading.
            if let start, value.covered, head.trusted, head.usedPercent > 0, head.capturedAt >= start,
               now >= head.capturedAt {
                var spent: [String: Double] = [:]
                for index in matched where fits(unique[index], from: start, to: min(end, head.capturedAt)) {
                    let sample = unique[index]
                    if !sample.costCurrency.isEmpty, sample.costValue.isFinite {
                        spent[sample.costCurrency, default: 0] += sample.costValue
                    }
                }
                // The whole-cycle ratio keeps "used" and "full" consistent with the official percentage. Unpriced
                // requests still count as zero spend; the tile then says the money is a lower bound.
                if spent.values.contains(where: { $0 > 0 }) {
                    value.capacityByCurrency = spent.mapValues { $0 / (head.usedPercent / 100) }
                    value.basis = "cycle"
                    value.samples = 1
                }
            }
            // Multi-endpoint evidence: each device's own baseline sample is an independent estimate. The median
            // survives one bad reading; the range makes the uncertainty visible in the tooltip. The spend is read
            // from the already-matched set, so hundreds of thousands of rows are not re-matched per sample.
            func baselineEstimate(_ q: AccountQuotaObservation) -> [String: Double]? {
                guard let base = q.baselineAt, let basePercent = q.baselinePercent, base.isFinite,
                      q.capturedAt - base >= 900, q.usedPercent.isFinite else { return nil }
                let delta = q.usedPercent - basePercent
                guard delta >= 3 else { return nil }
                var spent: [String: Double] = [:]
                for index in matched {
                    let point = unique[index]
                    guard point.timestamp > base, point.timestamp <= q.capturedAt else { continue }
                    if !point.costCurrency.isEmpty, point.costValue.isFinite {
                        spent[point.costCurrency, default: 0] += point.costValue
                    }
                }
                guard spent.values.reduce(0, +) > 0 else { return nil }
                return spent.mapValues { $0 / (delta / 100) }
            }
            var estimates: [String: [Double]] = [:]
            for q in cycle {
                // An anonymous twin of the same physical window (same source, pool and reset) still has a baseline.
                if q.account == nil, head.account != nil, q.source != head.source { continue }
                guard let found = baselineEstimate(q) else { continue }
                for (currency, amount) in found where amount.isFinite && amount > 0 {
                    estimates[currency, default: []].append(amount)
                }
            }
            if !estimates.isEmpty {
                value.samples = max(value.samples, estimates.values.map(\.count).max() ?? 0)
                for (currency, list) in estimates {
                    let sorted = list.sorted()
                    value.estimateLowByCurrency[currency] = sorted.first
                    value.estimateHighByCurrency[currency] = sorted.last
                    if value.capacityByCurrency.isEmpty, let middle = median(sorted) {
                        value.capacityByCurrency[currency] = middle
                        value.basis = "recent"
                    }
                }
            }
            result[key] = value
        }
        return result
    }

    /// Tooltip form of the estimate: the basis, plus the range when several baselines disagreed.
    public static func estimateDetail(_ value: QuotaWindowValue, format: ([String: Double]) -> String) -> String {
        guard value.hasCapacity else { return "" }
        switch value.basis {
        case "cycle":
            return L("整个额度 = 本周期从开始到读数时的用量 ÷ 已用百分比（这个周期从开始就有记录）。",
                     "Whole quota = spend from the cycle start to the reading ÷ percent used (recorded since the cycle began).")
        case "recent":
            let low = value.estimateLowByCurrency, high = value.estimateHighByCurrency
            let spread = value.samples > 1 && low != high
                ? "\n" + L("\(value.samples) 个设备样本：", "\(value.samples) device samples: ") + format(low) + " – " + format(high)
                : ""
            return L("按最近几小时的额度变化折算：这段时间按 API 价花了多少 ÷ 额度涨了几个百分点。",
                     "From the last few hours of quota movement: API-priced spend ÷ percentage points used.") + spread
        default:
            return ""
        }
    }

    public static func mergedQuotas(_ observations: [AccountQuotaObservation]) -> [AccountQuotaObservation] {
        var unique: [String: AccountQuotaObservation] = [:]
        var associated: [String: Set<String>] = [:]
        for q in observations where q.capturedAt.isFinite && q.capturedAt > 0 && q.usedPercent.isFinite && q.usedPercent >= 0 && q.usedPercent <= 100 {
            associated[q.id, default: []].formUnion(((q.associatedSources ?? []) + [q.source]).filter { !$0.isEmpty })
            if let old = unique[q.id] {
                if old.trusted && !q.trusted { continue }
                if old.trusted == q.trusted && old.capturedAt >= q.capturedAt { continue }
            }
            unique[q.id] = q
        }
        return unique.values.map { quota in
            var q = quota
            q.associatedSources = associated[q.id]?.sorted()
            return q
        }.sorted { $0.id < $1.id }
    }

    /// Quota identity proves that a device is related; it does not fill missing usage identity or coverage.
    public static func quotaSourceCoverageSelfTest() {
        let a = AccountIdentity(provider: "openai", accountID: "fixture-a")!
        let local = AccountUsagePoint(timestamp: 150, source: "Codex", model: "fixture", account: a, pool: "codex",
            usage: UsageHistory.ModelTotals(ctx: 100, out: 20), requests: 1,
            equivalentCostByCurrency: ["USD": 120], unpricedRequests: 0, exactRequestID: "resp_local", origin: "cli")
        var unknownRemote = local
        unknownRemote.source = "Codex · WSL"; unknownRemote.account = nil
        unknownRemote.equivalentCostByCurrency = ["USD": 80]; unknownRemote.exactRequestID = nil
        let remoteQuota = AccountQuotaObservation(account: a, source: unknownRemote.source, provider: "openai", pool: "codex",
            window: "5h", startedAt: 100, resetAt: 300, capturedAt: 200, usedPercent: 30)
        let direct = cycle(observation: remoteQuota, points: [local, unknownRemote], coverageStart: 100, now: 210)
        precondition(direct.coverage == "partial" && direct.capacityUSD == nil && direct.consumed.equivalentCostByCurrency["USD"] == 120)
        var localQuota = remoteQuota; localQuota.source = local.source; localQuota.capturedAt = 201
        let merged = mergedQuotas([remoteQuota, localQuota])[0]
        precondition(Set(merged.associatedSources ?? []) == [local.source, unknownRemote.source])
        precondition(cycle(observation: merged, points: [local, unknownRemote], coverageStart: 100, now: 210).capacityUSD == nil,
                     "Quota-source associations survive selecting the latest account snapshot")
        precondition(cycle(observation: merged, points: [local], coverageStart: 100, now: 210).capacityUSD == nil,
                     "No usage baseline has been proved for the quota-only associated device")
        precondition(unknownRemote.account == nil, "Quota identity must not be assigned to historical unknown usage")
        var unrelated = unknownRemote; unrelated.source = "Codex · unrelated"
        precondition(cycle(observation: localQuota, points: [local, unrelated], coverageStart: 100, now: 210).capacityUSD == 400)
        do {
            let restored = try JSONDecoder().decode(AccountQuotaObservation.self, from: JSONEncoder().encode(merged))
            precondition(restored.associatedSources == merged.associatedSources)
        } catch { preconditionFailure("Quota source association round-trip: \(error)") }
    }

    /// The display day is supplied by the caller's calendar, not UTC or a fixed 86400-second subtraction.
    public static func todayBySourceSelfTest() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 0, minute: 5))!
        let midnight = calendar.startOfDay(for: now).timeIntervalSince1970
        var local = AccountUsagePoint(timestamp: midnight, source: "Codex", model: "chatgpt-web/fixture", account: nil,
            pool: "chatgpt-web", usage: UsageHistory.ModelTotals(ctx: 100, out: 20), requests: 1,
            equivalentCostByCurrency: ["USD": 2], unpricedRequests: 0, exactRequestID: nil, origin: "cli")
        var previous = local; previous.timestamp = midnight - 1; previous.equivalentCostByCurrency = ["USD": 100]
        var nextDay = local; nextDay.timestamp = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: midnight))!.timeIntervalSince1970
        var unpriced = local; unpriced.timestamp += 1; unpriced.model = "unknown"; unpriced.equivalentCostByCurrency = [:]; unpriced.unpricedRequests = 1
        var remote = local; remote.source = "Claude · WSL"; remote.model = "fixture"; remote.pool = "claude"; remote.equivalentCostByCurrency = ["CNY": 3]
        var overlappingCPA = local; overlappingCPA.origin = "cpa"; overlappingCPA.equivalentCostByCurrency = ["USD": 999]
        var future = local; future.timestamp = now.timeIntervalSince1970 + 1
        let points = [previous, local, unpriced, remote, overlappingCPA, nextDay, future]
        let result = AccountUsageSnapshot.aggregate(points: points, now: now, calendar: calendar)
        precondition(result.todayBySource["Codex"]?.requests == 2 && result.todayBySource["Codex"]?.usage.tokenTotal == 240)
        precondition(result.todayBySource["Codex"]?.equivalentCostByCurrency == ["USD": 2] && result.todayBySource["Codex"]?.unpricedRequests == 1,
                     "Today's API-equivalent value excludes yesterday, future points and overlapping CPA, retaining unknown pricing")
        precondition(result.todayBySource[remote.source]?.equivalentCostByCurrency == ["CNY": 3] && result.todayBySource[remote.source]?.requests == 1,
                     "Device/tool sources and original currencies stay independent")
        let beforeMidnight = Date(timeIntervalSince1970: midnight - 0.5)
        precondition(AccountUsageSnapshot.aggregate(points: points, now: beforeMidnight, calendar: calendar).todayBySource["Codex"]?.equivalentCostByCurrency == ["USD": 100])
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(AccountUsageSnapshot.aggregate(points: points, now: now, calendar: utc).todayBySource["Codex"]?.equivalentCostByCurrency == ["USD": 102],
                     "Calendar injection controls the midnight boundary consistently")
        // An older native record establishes the source's native plane even if only overlapping CPA is present today.
        local.timestamp = midnight - 1
        precondition(AccountUsageSnapshot.aggregate(points: [local, overlappingCPA], now: now, calendar: calendar).todayBySource["Codex"] == nil)
    }

    /// One window's money view: every accounting plane added, whole-cycle evidence first, multi-endpoint median otherwise.
    static func windowValueSelfTest(account a: AccountIdentity) {
        func point(_ at: TimeInterval, _ usd: Double, _ origin: String = "cli", _ source: String = "Claude") -> AccountUsagePoint {
            AccountUsagePoint(timestamp: at, source: source, model: "claude-opus-5", account: a, pool: "claude",
                              usage: UsageHistory.ModelTotals(ctx: 100, out: 20), requests: 1,
                              equivalentCostByCurrency: ["USD": usd], unpricedRequests: 0,
                              exactRequestID: "id-\(Int(at))", origin: origin)
        }
        let q1 = AccountQuotaObservation(account: a, source: "Claude", provider: "anthropic", pool: "claude",
                                         window: "week", startedAt: 100, resetAt: 100_000, capturedAt: 2000,
                                         usedPercent: 30, baselineAt: 100, baselinePercent: 10)
        var q2 = q1
        q2.source = "Claude · fixture"; q2.capturedAt = 1999; q2.baselineAt = 1000; q2.baselinePercent = 20
        let points = [point(150, 120), point(1800, 30), point(1900, 30)]
        // Partial cycle: no whole-cycle evidence, so two device baselines are combined by median (900 / 600 → 750).
        let partial = windowValues(quotas: [q1, q2], points: points, now: 2000)
        let value = partial[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(value.basis == "recent" && value.samples == 2)
        precondition(abs((value.capacityByCurrency["USD"] ?? 0) - 750) < 0.001, "Two device baselines join by median")
        precondition(value.estimateLowByCurrency["USD"] == 600 && value.estimateHighByCurrency["USD"] == 900)
        precondition(value.consumedByCurrency["USD"] == 180 && value.consumedRequests == 3,
                     "Partial cycles still show recorded spend inside the window")
        precondition(!value.covered && value.origin == "cli")
        // A whole recorded cycle beats the noisy recent estimates.
        let complete = windowValues(quotas: [q1, q2], points: points, coverageStart: 100, now: 2000)
        let whole = complete[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(whole.covered && whole.basis == "cycle" && abs((whole.capacityByCurrency["USD"] ?? 0) - 600) < 0.001,
                     "Whole-cycle capacity = spend at capture ÷ percent used")
        // The same requests seen by the CPA relay are a second plane, never an addition.
        let overlap = points + [point(150, 90, "cpa")]
        let doubled = windowValues(quotas: [q1], points: overlap, now: 2000)
        let summed = doubled[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(summed.consumedByCurrency["USD"] == 270,
                     "Planes are added: this setup has no request recorded on both the CLI log and the CPA relay")
        precondition(summed.consumedByOrigin["cli"]?["USD"] == 180 && summed.consumedByOrigin["cpa"]?["USD"] == 90,
                     "The per-plane breakdown survives for the tooltip")
        let cpaOnly = windowValues(quotas: [q1], points: [point(150, 90, "cpa"), point(160, 30, "cpa")], now: 2000)
        let cpaValue = cpaOnly[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(cpaValue.origin == "cpa" && cpaValue.consumedByCurrency["USD"] == 120,
                     "A CPA-only account still reports this cycle's spend")
        precondition(abs((cpaValue.capacityByCurrency["USD"] ?? 0) - 600) < 0.001,
                     "The baseline estimate follows the selected CPA plane")
        // Windows that already reset leave the current tile; spend before the start is never this cycle's.
        var ended = q1; ended.resetAt = 1500
        precondition(windowValues(quotas: [ended], points: points, now: 2000).isEmpty)
        var lateWindow = q1; lateWindow.startedAt = 1000
        let late = windowValues(quotas: [lateWindow], points: points, now: 2000)
        let lateValue = late[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(lateValue.consumedByCurrency["USD"] == 60, "Spend before the window start does not count")
        // A source with records older than the window counts as covered, so this window gets a whole-cycle value.
        precondition(lateValue.covered && lateValue.basis == "cycle" && abs((lateValue.capacityByCurrency["USD"] ?? 0) - 200) < 0.001,
                     "Records older than the window start make the whole-cycle ratio usable")
        precondition(quotaWindowKey(pool: "a", window: "5h") != quotaWindowKey(pool: "a", window: "week"))
        precondition(median([1, 2, 3]) == 2 && median([1, 2]) == 1.5 && median([]) == nil)
        // Claude logs carry no account id. Only the quota's own device may supply that anonymous spend; another
        // device's anonymous requests stay out instead of leaking into this account.
        func anonymousPoint(_ at: TimeInterval, _ usd: Double, _ source: String) -> AccountUsagePoint {
            var point = point(at, usd); point.account = nil; point.source = source; point.exactRequestID = nil
            return point
        }
        var deviceQuota = q1
        deviceQuota.source = "Claude · fixture"; deviceQuota.capturedAt = 1900
        deviceQuota.usedPercent = 20; deviceQuota.baselineAt = 1000; deviceQuota.baselinePercent = 10
        let anonymousSpend = [anonymousPoint(1200, 40, "Claude · fixture"), anonymousPoint(1250, 900, "Claude · other")]
        let deviceScoped = windowValues(quotas: [deviceQuota], points: anonymousSpend, now: 2000)
        let scoped = deviceScoped[quotaWindowKey(pool: "claude", window: "week")]!
        precondition(scoped.consumedByCurrency["USD"] == 40,
                     "Anonymous spend is attributed by the quota's own device, never pool-wide")
        precondition(abs((scoped.capacityByCurrency["USD"] ?? 0) - 400) < 0.001,
                     "The same device-scoped spend feeds the baseline estimate")
    }

    public static func selfTest() {
        todayBySourceSelfTest()
        quotaSourceCoverageSelfTest()
        AccountCycleStore.persistenceSelfTest()
        let a = AccountIdentity(provider: "openai", accountID: "fixture-a")!
        let b = AccountIdentity(provider: "openai", accountID: "fixture-b")!
        let u = UsageHistory.ModelTotals(ctx: 100, out: 20)
        let p = AccountUsagePoint(timestamp: 150, source: "Codex", model: "fixture", account: a, pool: "codex",
                                  usage: u, requests: 1, equivalentCostByCurrency: ["USD": 120], unpricedRequests: 0,
                                  exactRequestID: "resp_1", origin: "cli")
        var remote = p; remote.source = "Codex · fixture"
        precondition(AccountUsageSnapshot.aggregate(points: [p, remote]).groups[0].totals.usage.tokenTotal == 120)
        remote.exactRequestID = "resp_2"
        precondition(AccountUsageSnapshot.aggregate(points: [p, remote]).groups[0].totals.requests == 2)
        remote.exactRequestID = "resp_1"; remote.account = b
        precondition(AccountUsageSnapshot.aggregate(points: [p, remote]).groups.count == 2)
        remote.account = a; remote.origin = "cpa"
        let separate = AccountUsageSnapshot.aggregate(points: [p, remote]).groups[0]
        precondition(separate.totals.requests == 2 && separate.byOrigin["cpa"]?.requests == 1 && separate.primaryOrigin == "cli",
                     "CLI and CPA are the same login on different machines, so the account total adds both planes")
        var q = AccountQuotaObservation(account: a, source: "Codex", provider: "openai", pool: "codex", window: "5h",
                                        startedAt: 100, resetAt: 300, capturedAt: 200, usedPercent: 30)
        precondition(cycle(observation: q, points: [p], coverageStart: 100, now: 210).capacityUSD == 400)
        precondition(cycle(observation: q, points: [p], now: 210).capacityUSD == nil)
        var sampled = q; sampled.capturedAt = 2000; sampled.baselineAt = 100; sampled.baselinePercent = 10
        precondition(recentCapacity(sampled, points: [p]) == ["USD": 600], "$120 for 20 points → $600 full")
        sampled.baselinePercent = 28
        precondition(recentCapacity(sampled, points: [p]) == nil, "under 3 points of movement is too noisy")
        var future = p; future.timestamp = 201; future.exactRequestID = "resp_future"
        let afterCapture = cycle(observation: q, points: [p, future], coverageStart: 100, now: 210)
        precondition(afterCapture.capacityUSD == 400 && afterCapture.consumedAsOfCapture.equivalentCostByCurrency["USD"] == 120)
        precondition(afterCapture.consumed.equivalentCostByCurrency["USD"] == 240 && afterCapture.consumed.requests == 2,
                     "Current-cycle spend includes requests after the quota capture without changing capacity")
        var atReset = p; atReset.timestamp = 300; atReset.exactRequestID = "resp_reset"
        let ended = cycle(observation: q, points: [p, future, atReset], coverageStart: 100, now: 310)
        precondition(ended.consumed.equivalentCostByCurrency["USD"] == 240 && ended.consumedAsOfCapture.requests == 1 && ended.capacityUSD == nil,
                     "Ended cycles retain post-capture spend but exclude requests exactly at reset")
        var nextWindow = q; nextWindow.startedAt = 300; nextWindow.resetAt = 500; nextWindow.capturedAt = 301
        let nextCycle = cycle(observation: nextWindow, points: [p, future, atReset], coverageStart: 100, now: 310)
        precondition(nextCycle.consumed.requests == 1 && nextCycle.consumedAsOfCapture.requests == 1 && nextCycle.capacityUSD == 400,
                     "A request exactly at reset belongs only to the next cycle")
        var unknownAccount = p; unknownAccount.timestamp = 175; unknownAccount.account = nil; unknownAccount.exactRequestID = nil
        precondition(cycle(observation: q, points: [p, unknownAccount], coverageStart: 100, now: 210).capacityUSD == nil,
                     "Unassigned usage on a contributing source prevents claiming a complete account cycle")
        unknownAccount.source = "Codex · unrelated"
        precondition(cycle(observation: q, points: [p, unknownAccount], coverageStart: 100, now: 210).capacityUSD == 400,
                     "Unassigned usage on an unrelated device does not block this account")
        unknownAccount.source = p.source; unknownAccount.origin = "cpa"
        precondition(cycle(observation: q, points: [p, unknownAccount], coverageStart: 100, now: 210).capacityUSD == 400,
                     "Unassigned CPA usage does not invalidate native CLI coverage")
        var web = p; web.pool = "chatgpt-web"; web.exactRequestID = "resp_web"
        precondition(cycle(observation: q, points: [p, web], coverageStart: 100, now: 210).capacityUSD == 400)
        var unpriced = p; unpriced.unpricedRequests = 1
        precondition(cycle(observation: q, points: [unpriced], coverageStart: 100, now: 210).capacityUSD == nil)
        unpriced = p; unpriced.equivalentCostByCurrency = ["CNY": 120]
        precondition(cycle(observation: q, points: [unpriced], coverageStart: 100, now: 210).capacityUSD == nil)
        q.usedPercent = 0
        precondition(cycle(observation: q, points: [p], coverageStart: 100, now: 210).capacityUSD == nil)
        q.usedPercent = 30
        precondition(cycle(observation: q, points: [p], coverageStart: 100, now: 300).capacityUSD == nil)
        q.resetAt = nil
        precondition(cycle(observation: q, points: [p], coverageStart: 100, now: 210).coverage == "unknown")
        q.resetAt = 300
        windowValueSelfTest(account: a)
        let store = AccountCycleStore(path: nil)
        store.record([q]); var switched = q; switched.account = b
        store.record([switched])
        precondition(store.observations.count == 1 && store.observations[0].account == a)
        var offline = q; offline.trusted = false
        store.record([offline]); precondition(store.observations.first?.trusted == false)
        var healthy = q; healthy.source = "Codex · fixture"
        store.record([healthy]); precondition(store.observations.first?.trusted == true)
        switched.capturedAt = 201; store.record([switched])
        precondition(store.observations.count == 2)
        var next = q; next.startedAt = 300; next.resetAt = 500; next.capturedAt = 301
        store.record([next]); precondition(store.observations.count == 3)
        let t = TurnLatencySample(turnID: "turn", source: "Codex", timestamp: 150, milliseconds: 10)
        var failed = t; failed.turnID = "failed"; failed.failed = true; failed.milliseconds = 1000
        var child = t; child.turnID = "child"; child.milliseconds = 30
        precondition(PerformanceStats.turnTTFT([t, t, child, failed], since: 100, until: 200) == 20)
        precondition(PerformanceStats.turnTTFT([t], since: 151, until: 200) == nil)
    }
}

/// Small durable quota history; raw usage continues to belong to UsageHistory. `nil` path is fixture-safe.
public final class AccountCycleStore {
    public private(set) var observations: [AccountQuotaObservation] = []
    /// Per-device observations of the same cycle, before merging. Each one carries its own baseline sample,
    /// so the estimator can combine independent evidence instead of trusting a single reading.
    public var perSourceObservations: [AccountQuotaObservation] {
        sourceObservations.filter { $0.usedPercent.isFinite && $0.capturedAt.isFinite && $0.capturedAt > 0 }
    }
    public private(set) var persistenceError: String?
    private let path: String?
    private var sourceObservations: [AccountQuotaObservation] = []
    private var readFailed = false
    private var pendingWrite = false
    public init(path: String?) {
        self.path = path
        if let path, FileManager.default.fileExists(atPath: path) {
            do {
                sourceObservations = try JSONDecoder().decode([AccountQuotaObservation].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                observations = AccountUsage.mergedQuotas(sourceObservations)
            }
            catch { readFailed = true; persistenceError = "Cannot read account cycle history: \(error.localizedDescription)" }
        }
    }
    public func record(_ incoming: [AccountQuotaObservation]) {
        var ownerLatest: [String: AccountQuotaObservation] = [:]
        for q in sourceObservations where q.capturedAt >= (ownerLatest[q.ownerKey]?.capturedAt ?? 0) { ownerLatest[q.ownerKey] = q }
        var accepted: [AccountQuotaObservation] = []
        for q in incoming.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            if let old = ownerLatest[q.ownerKey], old.account != q.account, q.capturedAt <= old.capturedAt { continue }
            accepted.append(q)
            if q.capturedAt >= (ownerLatest[q.ownerKey]?.capturedAt ?? 0) { ownerLatest[q.ownerKey] = q }
        }
        var bySource: [String: AccountQuotaObservation] = [:]
        for q in sourceObservations + accepted {
            let key = q.id + "\u{1d}" + q.source
            if let old = bySource[key], old.capturedAt > q.capturedAt { continue }
            bySource[key] = q
        }
        let sources = bySource.values.sorted { ($0.id, $0.source) < ($1.id, $1.source) }
        if sources != sourceObservations {
            sourceObservations = sources
            observations = AccountUsage.mergedQuotas(sources)
            pendingWrite = true
        }
        guard pendingWrite, let path else { return }
        // Failed reads protect the original archive. Failed writes retain pending state and retry on a later scan.
        guard !readFailed else { return }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(sourceObservations).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            pendingWrite = false
            persistenceError = nil
        } catch { persistenceError = "Cannot save account cycle history: \(error.localizedDescription)" }
    }
    public static func persistenceSelfTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibedeck-cycle-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let blockedParent = root.appendingPathComponent("blocked")
            try Data("fixture blocker".utf8).write(to: blockedParent)
            let destination = blockedParent.appendingPathComponent("cycles.json")
            let a = AccountIdentity(provider: "openai", accountID: "fixture-a")!
            let q = AccountQuotaObservation(account: a, source: "Codex", provider: "openai", pool: "codex", window: "5h",
                startedAt: 100, resetAt: 300, capturedAt: 200, usedPercent: 30)
            let retryable = AccountCycleStore(path: destination.path)
            retryable.record([q])
            precondition(retryable.persistenceError != nil && retryable.observations.count == 1)
            try FileManager.default.removeItem(at: blockedParent)
            try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)
            retryable.record([q]) // The same ordinary sample retries pending writes, even without changed quota values.
            precondition(retryable.persistenceError == nil)
            let restored = AccountCycleStore(path: destination.path)
            precondition(restored.persistenceError == nil && restored.observations.count == 1 && restored.observations[0].account == a)
            let corrupt = root.appendingPathComponent("unreadable.json")
            let original = Data("preserve unreadable original".utf8)
            try original.write(to: corrupt)
            let protected = AccountCycleStore(path: corrupt.path)
            precondition(protected.persistenceError != nil)
            protected.record([q]); protected.record([q])
            let retained = try Data(contentsOf: corrupt)
            precondition(retained == original && protected.persistenceError != nil,
                         "A load failure still protects the original archive from replacement")
        } catch { preconditionFailure("Cycle save recovery self-test: \(error)") }
    }

    public func cycles(points: [AccountUsagePoint], coverageStartByAccount: [String: TimeInterval] = [:],
                       origin: String = "cli", now: TimeInterval = Date().timeIntervalSince1970) -> [AccountCycleUsage] {
        observations.map { q in AccountUsage.cycle(observation: q, points: points,
            coverageStart: q.account.flatMap { coverageStartByAccount[$0.key] }, origin: origin, now: now) }
            .sorted { ($0.observation.resetAt ?? 0) > ($1.observation.resetAt ?? 0) }
    }
}

public extension AccountUsage {
    /// Pure equivalent of the existing UI trust rules; no UI-module dependency.
    static func quotaTrusted(_ quota: QuotaWindow, runtime: DetectedLLMRuntime,
                             status: RemoteDeviceStatus?, isRemote: Bool, now: TimeInterval) -> Bool {
        guard let capture = quota.capturedAt, capture.isFinite, capture > 0,
              capture <= now + 60, now - capture <= 600,
              !runtime.quotaNote.contains("未取得新额度"), !runtime.quotaNote.contains("Quota missing;") else { return false }
        if let reset = quota.resetsAt, !reset.isFinite || reset > 253402300799 || reset <= now { return false }
        if isRemote {
            guard let status, status.error.isEmpty, let success = status.lastSuccess,
                  success <= now + 60, now - success <= 600 else { return false }
        }
        return true
    }

    static func quotaObservations(report: ScanReport, now: TimeInterval = Date().timeIntervalSince1970, mergingAccounts: Bool = true) -> [AccountQuotaObservation] {
        var observations: [AccountQuotaObservation] = []
        func collect(_ runtime: DetectedLLMRuntime, host: String?) {
            let source = runtime.name + (host.map { " · " + $0 } ?? "")
            let lower = runtime.name.lowercased()
            let pool = lower.contains("codex") ? "codex" : (lower.contains("claude") ? "claude" : lower)
            func append(_ quota: QuotaWindow?, window: String, account: AccountIdentity?, pool: String) {
                guard let quota, let captured = quota.capturedAt else { return }
                let start: TimeInterval? = quota.windowSeconds > 0 ? quota.resetsAt.map { $0 - quota.windowSeconds } : nil
                observations.append(AccountQuotaObservation(account: account, source: source,
                    provider: account?.provider ?? (lower.contains("codex") ? "openai" : lower.contains("claude") ? "anthropic" : lower),
                    pool: pool, window: window, startedAt: start, resetAt: quota.resetsAt,
                    capturedAt: captured, usedPercent: quota.accountingUsedPercent, trusted: quotaTrusted(quota, runtime: runtime,
                        status: host.flatMap { report.remoteDeviceStatus[$0] }, isRemote: host != nil, now: now),
                    baselineAt: quota.baselineAt, baselinePercent: quota.baselinePct.map(Double.init)))
            }
            append(runtime.fiveHour, window: "5h", account: runtime.account, pool: pool)
            append(runtime.sevenDay, window: "week", account: runtime.account, pool: pool)
            let secondary = pool + ":" + runtime.secondaryPoolName.lowercased()
            append(runtime.secondaryFiveHour, window: "5h", account: runtime.secondaryAccount, pool: secondary)
            append(runtime.secondarySevenDay, window: "week", account: runtime.secondaryAccount, pool: secondary)
        }
        for runtime in report.detectedLLMs { collect(runtime, host: nil) }
        for (host, runtimes) in report.remoteLLMs { for runtime in runtimes { collect(runtime, host: host) } }
        return mergingAccounts ? mergedQuotas(observations) : observations
    }
}
