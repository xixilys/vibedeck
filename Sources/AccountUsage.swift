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
    public var equivalentCostByCurrency: [String: Double]
    public var unpricedRequests: Int
    public var exactRequestID: String?
    public var origin: String
    public var timestampResolution: TimeInterval = 0
}

public struct AccountUsageTotals: Equatable {
    public var usage = UsageHistory.ModelTotals()
    public var requests = 0
    public var equivalentCostByCurrency: [String: Double] = [:]
    public var unpricedRequests = 0
    public init() {}
    mutating func add(_ point: AccountUsagePoint) {
        usage.add(point.usage); requests += point.requests; unpricedRequests += point.unpricedRequests
        for (currency, value) in point.equivalentCostByCurrency { equivalentCostByCurrency[currency, default: 0] += value }
    }
}

public struct AccountUsageGroup: Equatable, Identifiable {
    public var id: String
    public var account: AccountIdentity?
    public var totals = AccountUsageTotals()
    /// Independent accounting planes: native CLI and CPA may overlap and are never added together.
    public var byOrigin: [String: AccountUsageTotals] = [:]
    public var primaryOrigin = "cli"
    /// Device/tool totals retain each device's observation, even if account totals deduplicate a copied request.
    public var bySource: [String: AccountUsageTotals] = [:]
    public var firstObservedAt: TimeInterval
    public var lastObservedAt: TimeInterval
}

public struct AccountUsageSnapshot: Equatable {
    public var groups: [AccountUsageGroup] = []
    public var points: [AccountUsagePoint] = []
    public var unassigned = AccountUsageTotals()
    /// Today's observed device/tool usage, API-equivalent valued. Each source selects cli, then cpa, then proxy;
    /// overlapping accounting planes are never added. Original currencies and unpriced requests are retained.
    public var todayBySource: [String: AccountUsageTotals] = [:]
    /// Same selection as todayBySource, bucketed by local hour: source → currency → 24 API-equivalent amounts.
    public var todayHourlyBySource: [String: [String: [Double]]] = [:]
    /// Observed collection baseline, max across known devices; only published while their collection is healthy.
    /// This is coverage of collected devices, not proof that no other device uses the provider account.
    public var coverageStartByAccount: [String: TimeInterval] = [:]
    public init() {}
    public static func aggregate(points: [AccountUsagePoint], now: Date = Date(), calendar: Calendar = .current) -> Self {
        var result = Self()
        let today = calendar.dateInterval(of: .day, for: now)
        let asOf = now.timeIntervalSince1970
        var todayByOrigin: [String: [String: AccountUsageTotals]] = [:]
        var hourlyByOrigin: [String: [String: [String: [Double]]]] = [:]
        var sourceOrigins: [String: Set<String>] = [:]
        result.points = AccountUsage.deduplicated(points)
        var groups: [String: AccountUsageGroup] = [:]
        for point in result.points {
            let key = point.account?.key ?? "unassigned:" + point.source
            var group = groups[key] ?? AccountUsageGroup(id: key, account: point.account,
                firstObservedAt: point.timestamp, lastObservedAt: point.timestamp)
            group.byOrigin[point.origin, default: AccountUsageTotals()].add(point)
            group.firstObservedAt = min(group.firstObservedAt, point.timestamp)
            group.lastObservedAt = max(group.lastObservedAt, point.timestamp)
            groups[key] = group
            if point.account == nil && point.origin == "cli" { result.unassigned.add(point) }
        }
        // Per-device detail answers where tokens were observed; account total answers unique known requests.
        for point in points {
            let key = point.account?.key ?? "unassigned:" + point.source
            groups[key]?.bySource[point.source, default: AccountUsageTotals()].add(point)
            sourceOrigins[point.source, default: []].insert(point.origin)
            if let today, point.timestamp.isFinite, point.timestamp >= today.start.timeIntervalSince1970,
               point.timestamp < today.end.timeIntervalSince1970, point.timestamp <= asOf {
                todayByOrigin[point.source, default: [:]][point.origin, default: AccountUsageTotals()].add(point)
                let hour = max(0, min(23, Int((point.timestamp - today.start.timeIntervalSince1970) / 3600)))
                for (currency, value) in point.equivalentCostByCurrency where value.isFinite {
                    hourlyByOrigin[point.source, default: [:]][point.origin, default: [:]][currency, default: Array(repeating: 0, count: 24)][hour] += value
                }
            }
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
            groups[key]?.totals = origins[primary] ?? AccountUsageTotals()
        }
        result.groups = groups.values.sorted { a, b in
            if (a.account != nil) != (b.account != nil) { return a.account != nil }
            if a.totals.usage.tokenTotal != b.totals.usage.tokenTotal { return a.totals.usage.tokenTotal > b.totals.usage.tokenTotal }
            return a.id < b.id
        }
        return result
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

public enum AccountUsage {
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

    static func deduplicated(_ points: [AccountUsagePoint]) -> [AccountUsagePoint] {
        var kept: [AccountUsagePoint] = [], indices: [String: Int] = [:]
        for point in points.sorted(by: { ($0.source, $0.timestamp, $0.model) < ($1.source, $1.timestamp, $1.model) }) {
            guard let account = point.account, let id = point.exactRequestID else { kept.append(point); continue }
            // CPA has no proven ID correlation with native CLI, so origins deliberately remain independent.
            let key = [account.key, point.origin, UsageHistory.cli(of: point.source), point.pool, id].joined(separator: "\u{1e}")
            if let index = indices[key] {
                let old = kept[index]
                if point.usage.tokenTotal > old.usage.tokenTotal ||
                    (point.usage.tokenTotal == old.usage.tokenTotal && point.unpricedRequests < old.unpricedRequests) {
                    kept[index] = point
                }
            } else { indices[key] = kept.count; kept.append(point) }
        }
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
    public static func recentCapacity(_ q: AccountQuotaObservation, points: [AccountUsagePoint]) -> [String: Double]? {
        guard let start = q.baselineAt, let base = q.baselinePercent, start.isFinite, q.capturedAt - start >= 900,
              q.usedPercent.isFinite else { return nil }
        let delta = q.usedPercent - base
        guard delta >= 3 else { return nil }
        var spent: [String: Double] = [:]
        for point in deduplicated(points) where point.origin == "cli" && point.timestamp > start && point.timestamp <= q.capturedAt {
            let matches: Bool
            if let account = q.account { matches = point.account == account && point.pool == q.pool }
            // A coding plan's key is shared by every tool and device that calls its models.
            else if q.pool == "glm" { matches = point.model.lowercased().contains("glm") }
            else { matches = point.account == nil && UsageHistory.cli(of: point.source).lowercased() == q.pool }
            guard matches else { continue }
            for (currency, value) in point.equivalentCostByCurrency where value.isFinite { spent[currency, default: 0] += value }
        }
        guard spent.values.reduce(0, +) > 0 else { return nil }
        return spent.mapValues { $0 / (delta / 100) }
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
        precondition(separate.totals.requests == 1 && separate.byOrigin["cpa"]?.requests == 1 && separate.primaryOrigin == "cli")
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
