import Foundation
import CoreFoundation
import CryptoKit
import os

/// 只缓存用量字段，不保存对话正文；按文件保留贡献，才能在日志重写后撤销旧账。
///
/// 口径（对齐 ccusage 的做法）：
/// · Claude：同一 requestId 在日志里会写多行（流式分块），取 token 最多的那条；跨文件再去重（--fork-session 会复制历史）。
///   `cache_creation.ephemeral_1h_input_tokens` 单独记，1 小时缓存写入按 2× 输入价算；`usage.speed == "fast"` 记为 fast 档。
/// · Codex：新版每次请求写一条 `token_usage_record`（带 response_id，天然去重）；旧版回退到 `token_count`
///   的 `last_token_usage`（累计值没前进就不算）。`thread_settings_applied.service_tier` 记下 priority/fast 档。
///   同一个 rollout 文件出现在 sessions/ 和 archived_sessions/ 里只算一次。
/// · 远程主机：ssh 跑采集脚本拿逐条记录（Claude / Codex / opencode），挂载目录（如 WSL 的家目录）当成另一台设备直接读。
public final class UsageHistory {
    public static let shared = UsageHistory(cachePath: ProcessInfo.processInfo.environment["VIBEGAUGE_HISTORY_CACHE"])

    public struct ModelTotals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var tokenTotal: Int64 { ctx + out }
        mutating func add(_ other: ModelTotals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think
        }
    }

    public struct Totals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var turns = 0
        public var sessions = 0
        public var models: [String: ModelTotals] = [:]
        public var tokenTotal: Int64 { ctx + out }
        public var newInput: Int64 { max(0, ctx - cacheRead - cacheWrite) }
        public var cacheTotal: Int64 { cacheRead + cacheWrite }
        public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100 : 0 }

        mutating func add(_ record: Record) {
            let u = record.usage
            ctx += u.ctx; cacheRead += u.cacheRead; cacheWrite += u.cacheWrite
            out += u.out; think += u.think; turns += 1
            models[record.model, default: ModelTotals()].add(u)
        }
        mutating func merge(_ other: Totals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think; turns += other.turns; sessions += other.sessions
            for (model, usage) in other.models { models[model, default: ModelTotals()].add(usage) }
        }
    }

    public struct Day: Codable, Equatable, Identifiable {
        public var id: String { date }
        public let date: String
        public var sources: [String: Totals]
        public var total: Totals { sources.values.reduce(into: Totals()) { $0.merge($1) } }
    }

    public struct Snapshot: Equatable {
        public var performance: [PerformanceSample] = []
        public var accountUsage = AccountUsageSnapshot()
        public var turnLatencies: [TurnLatencySample] = []
        public var turnLatencyCoverageNote = "24h; recent files, final 32 MiB/file; up to 5000 samples/source"
        public var todayModels: [String: [String: PerformanceTotals]] = [:]
        public var recentBySource: [String: RecentUsage] = [:]
        public var days: [Day] = []
        public var dailyTokens: [String: Int64] = [:]
        public var totals: [String: Totals] = [:]
        public var aggregate = Totals()
        public var earliestDate: String?
        public var activeDays = 0
        public var isScanning = false
        public var processedFiles = 0
        public var totalFiles = 0
        public var error = ""
        public var sourceNotes: [String: String] = [:]
        /// 用户自己配了 prices.json（手填或 models.dev 同步）
        public var hasPriceTable = false
        public var priceCurrency = ""
        /// 内置官方价的日期（空 = 内置价读不到）
        public var builtinPriceAsOf = ""
        public var hasAnyPricing: Bool { hasPriceTable || !builtinPriceAsOf.isEmpty }
        /// 按币种分桶：国产模型 ¥、外国模型 $，不做汇率换算，各显各的
        public var costByCurrency: [String: Double] = [:]
        public var costBySource: [String: [String: Double]] = [:]
        public var costByModel: [String: [String: Double]] = [:]
        public var todayCostBySource: [String: [String: Double]] = [:]
        public var todayBySource: [String: Totals] = [:]
        /// 每日花费（主币种），给热力图 tooltip / 柱状图
        public var dailyCost: [String: Double] = [:]
        public var primaryCurrency = "USD"
        public var forecasts: [String: CostForecast] = [:]
        /// 设备作用域 → 币种 → 预测；键为 local / remote:<host>，不把其他设备的曲线带入筛选页。
        public var forecastsByDevice: [String: [String: CostForecast]] = [:]
        public var dailyCostByDevice: [String: [String: [String: Double]]] = [:]
        public var forecast: CostForecast? { forecasts[primaryCurrency] }
        public var claudeBlock: BillingBlock?
        public var unpricedModels = 0
        public var unpricedBySource: [String: Int] = [:]
        public var unpricedNames: [String] = []
        public var unpricedNamesBySource: [String: [String]] = [:]
        public var cumulativeTurns = 0
        public var replayedTurns = 0
        public var skippedRecords = 0
        public var capturedAt: TimeInterval = 0
        public var tokenTotal: Int64 { aggregate.tokenTotal }
        public var ctx: Int64 { aggregate.ctx }
        public var cacheRead: Int64 { aggregate.cacheRead }
        public var cacheHitRate: Double? { ctx > 0 ? Double(cacheRead) / Double(ctx) : nil }
        public init() {}

        /// 零点后的下一次扫描前，不把昨日缓存继续显示成今日用量。
        public func currentDaySources(at now: TimeInterval = Date().timeIntervalSince1970,
                                      timeZone: TimeZone = .current) -> [String: Totals] {
            guard capturedAt > 0,
                  UsageHistory.dayKey(timestamp: capturedAt, timeZone: timeZone) == UsageHistory.dayKey(timestamp: now, timeZone: timeZone)
            else { return [:] }
            return todayBySource
        }
    }

    /// 经记账代理的上游（"API · GLM" 这类）：同一请求多半已在 CLI 日志里，不进总数
    public static func isProxySource(_ source: String) -> Bool { source.hasPrefix("API") }

    /// 来源属于哪台设备：`X · <设备>` 的后缀；本机来源没有后缀（API 记账也算本机）。
    public static func device(of source: String) -> String? {
        guard !isProxySource(source), let r = source.range(of: " · ", options: .backwards) else { return nil }
        return String(source[r.upperBound...])
    }

    /// 来源的 CLI 名（去掉设备后缀）。
    public static func cli(of source: String) -> String {
        guard !isProxySource(source), let r = source.range(of: " · ", options: .backwards) else { return source }
        return String(source[..<r.lowerBound])
    }

    /// 同值同档，零日留空；档位只由非零日的最近秩分位数决定。
    public static func levels(_ values: [Int64]) -> [Int] {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return values.map { _ in 0 } }
        let thresholds = (1...4).map { positive[max(0, Int(ceil(Double(positive.count) * Double($0) / 5)) - 1)] }
        return values.map { value in value <= 0 ? 0 : 1 + thresholds.filter { value > $0 }.count }
    }

    public static func dayKey(timestamp: TimeInterval, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Many records share a civil day. Resolve its real Calendar interval once, including DST,
    /// then look it up without rebuilding Calendar/components/format strings for every record.
    struct DayKeyCache {
        private let calendar: Calendar
        private var days: [(start: TimeInterval, end: TimeInterval, key: String)] = []
        init(timeZone: TimeZone = .current) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.calendar = calendar
        }
        mutating func key(_ timestamp: TimeInterval) -> String {
            var low = 0, high = days.count
            while low < high {
                let mid = (low + high) / 2
                if timestamp < days[mid].start { high = mid }
                else if timestamp >= days[mid].end { low = mid + 1 }
                else { return days[mid].key }
            }
            let key = UsageHistory.dayKey(timestamp: timestamp, timeZone: calendar.timeZone)
            if let interval = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: timestamp)) {
                days.insert((interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970, key), at: low)
            }
            return key
        }
    }

    public static func codexLastTokenUsage(_ fields: [String: Int64]) -> ModelTotals {
        ModelTotals(ctx: fields["input_tokens"] ?? 0, cacheRead: fields["cached_input_tokens"] ?? 0,
                    cacheWrite: fields["cache_write_input_tokens"] ?? 0, out: fields["output_tokens"] ?? 0,
                    think: fields["reasoning_output_tokens"] ?? 0)
    }

    /// 累计值回退时只建立新基线；不把负差变成零，也不把整个重置值再记一次。
    public static func codexCumulativeDelta(previous: [String: Int64]?, current: [String: Int64]) -> ModelTotals? {
        var delta: [String: Int64] = [:]
        for key in tokenKeys {
            let now = current[key] ?? 0, old = previous?[key] ?? 0
            guard now >= old else { return nil }
            delta[key] = now - old
        }
        let result = codexLastTokenUsage(delta)
        return result.tokenTotal > 0 ? result : nil
    }

    /// 同一累计快照可被额度刷新重复写入；不同请求即便单次 token 完全相同，也不能被去重。
    static func codexUsage(info: [String: Any], previous: inout [String: Int64]?) -> (usage: ModelTotals, cumulative: Bool)? {
        let total = tokenFields(info["total_token_usage"])
        let last = tokenFields(info["last_token_usage"])
        let old = previous
        if let total { previous = total }
        if let total, total == old { return nil }
        if let last { return (codexLastTokenUsage(last), false) }
        guard let total, let delta = codexCumulativeDelta(previous: old, current: total) else { return nil }
        return (delta, true)
    }

    struct Record: Codable, Equatable {
        var id: String
        var source: String
        var timestamp: TimeInterval
        var model: String
        var usage: ModelTotals
        var cumulative = false
        /// 多会话来源（opencode / 远程）的会话键。nil 时沿用旧口径：按日志文件路径计会话。
        /// 必须是可选：老缓存里没有这个键，可选字段才能被 decodeIfPresent 兼容，不必升版本丢历史。
        var session: String? = nil
        /// 1 小时缓存写入（已含在 usage.cacheWrite 里），单独计价。
        var cw1h: Int64? = nil
        /// 服务档：Codex "priority"/"fast"、Claude "fast"；nil = 标准。
        var tier: String? = nil
        var timing: PerformanceTiming? = nil
        var account: AccountIdentity? = nil
        /// Cost the tool itself reported (DSH ledger, Grok's costUsdTicks, free relay models = 0). When set it
        /// replaces the price-table estimate for both billed and API-equivalent value.
        var billed: BilledCost? = nil
    }

    struct BilledCost: Codable, Equatable {
        var value: Double
        var currency: String
    }

    /// 文件内同 requestId 取 token 最多的那条（流式分块会先写一个不完整的 usage），跨文件同理。
    static func deduplicateClaude(_ files: [String: [Record]]) -> [String: Record] {
        var result: [String: Record] = [:]
        for path in files.keys.sorted() {
            for record in files[path] ?? [] {
                if let old = result[record.id], !prefer(record, over: old) { continue }
                result[record.id] = record
            }
        }
        return result
    }

    static func prefer(_ candidate: Record, over existing: Record) -> Bool {
        if candidate.usage.tokenTotal != existing.usage.tokenTotal { return candidate.usage.tokenTotal > existing.usage.tokenTotal }
        if candidate.timestamp != existing.timestamp { return candidate.timestamp > existing.timestamp }
        return existing.timing == nil && candidate.timing != nil
    }

    /// Frozen accounting keeps tokens, request counts and pricing dimensions, never text or request IDs.
    /// 7–35 day buckets retain exact time for the rolling 35-day forecast boundary; older ones coalesce by hour.
    private struct FrozenBucket: Codable, Equatable {
        var source: String
        var model: String
        var tier: String?
        var timestamp: TimeInterval
        var peak: Bool
        var longContext: Bool
        var usage = ModelTotals()
        var fresh: Int64 = 0
        var cw1h: Int64 = 0
        var turns = 0
        var cumulative = 0
        var minContext: Int64
        var maxContext: Int64
        var account: AccountIdentity? = nil
        // Retain genuine IDs for known accounts so exact cross-device dedup survives compaction.
        var exactRequestID: String? = nil
        var billed: BilledCost? = nil
    }

    private static let legacyCacheEncoding = CodingUserInfoKey(rawValue: "historyLegacyJSON")!

    /// The disk archive packs hot arrays into fixed-width little-endian rows. This avoids hundreds
    /// of thousands of keyed Codable containers on startup; all values remain lossless.
    private struct PackedRows: Codable {
        var strings: [String]
        var rows: Data

        static func records(_ records: [String: Record]) -> PackedRows {
            var strings: [String] = [], indices: [String: UInt64] = [:], data = Data()
            data.reserveCapacity(records.count * 13 * 8)
            func text(_ s: String?) -> UInt64 {
                guard let s else { return 0 }
                if let i = indices[s] { return i }
                strings.append(s); let i = UInt64(strings.count); indices[s] = i; return i
            }
            func word(_ n: UInt64) { var x = n.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
            for r in records.values {
                for x in [text(r.id), text(r.source), text(r.model), text(r.session), text(r.tier), r.timestamp.bitPattern,
                          UInt64(bitPattern: r.usage.ctx), UInt64(bitPattern: r.usage.cacheRead), UInt64(bitPattern: r.usage.cacheWrite),
                          UInt64(bitPattern: r.usage.out), UInt64(bitPattern: r.usage.think), r.cumulative ? 1 : 0,
                          r.cw1h.map { UInt64(bitPattern: $0) } ?? UInt64.max] { word(x) }
            }
            return PackedRows(strings: strings, rows: data)
        }
        static func frozen(_ buckets: [FrozenBucket]) -> PackedRows {
            var strings: [String] = [], indices: [String: UInt64] = [:], data = Data()
            data.reserveCapacity(buckets.count * 18 * 8)
            func text(_ s: String?) -> UInt64 {
                guard let s else { return 0 }
                if let i = indices[s] { return i }
                strings.append(s); let i = UInt64(strings.count); indices[s] = i; return i
            }
            func word(_ n: UInt64) { var x = n.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
            for b in buckets {
                for x in [text(b.source), text(b.model), text(b.tier), b.timestamp.bitPattern, b.peak ? 1 : 0, b.longContext ? 1 : 0,
                          UInt64(bitPattern: b.usage.ctx), UInt64(bitPattern: b.usage.cacheRead), UInt64(bitPattern: b.usage.cacheWrite),
                          UInt64(bitPattern: b.usage.out), UInt64(bitPattern: b.usage.think), UInt64(bitPattern: b.fresh), UInt64(bitPattern: b.cw1h),
                          UInt64(b.turns), UInt64(b.cumulative), UInt64(bitPattern: b.minContext), UInt64(bitPattern: b.maxContext)] { word(x) }
            }
            return PackedRows(strings: strings, rows: data)
        }
        func records() throws -> [String: Record] {
            let width = 13 * 8
            guard rows.count % width == 0 else { throw CocoaError(.fileReadCorruptFile) }
            var result: [String: Record] = [:]
            result.reserveCapacity(rows.count / width)
            try rows.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                func word(_ row: Int, _ column: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: row + column * 8, as: UInt64.self)) }
                func text(_ x: UInt64) throws -> String? {
                    guard x <= UInt64(strings.count) else { throw CocoaError(.fileReadCorruptFile) }
                    return x == 0 ? nil : strings[Int(x - 1)]
                }
                for row in stride(from: 0, to: rows.count, by: width) {
                    guard let id = try text(word(row, 0)), let source = try text(word(row, 1)), let model = try text(word(row, 2)),
                          word(row, 11) <= 1 else { throw CocoaError(.fileReadCorruptFile) }
                    let timestamp = TimeInterval(bitPattern: word(row, 5))
                    guard timestamp.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    let usage = ModelTotals(ctx: Int64(bitPattern: word(row, 6)), cacheRead: Int64(bitPattern: word(row, 7)),
                                            cacheWrite: Int64(bitPattern: word(row, 8)), out: Int64(bitPattern: word(row, 9)), think: Int64(bitPattern: word(row, 10)))
                    let cw = word(row, 12)
                    result[id] = Record(id: id, source: source, timestamp: timestamp, model: model, usage: usage, cumulative: word(row, 11) == 1,
                                        session: try text(word(row, 3)), cw1h: cw == UInt64.max ? nil : Int64(bitPattern: cw), tier: try text(word(row, 4)))
                }
            }
            return result
        }
        func frozen() throws -> [FrozenBucket] {
            let width = 17 * 8
            guard rows.count % width == 0 else { throw CocoaError(.fileReadCorruptFile) }
            var result: [FrozenBucket] = []
            result.reserveCapacity(rows.count / width)
            try rows.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                func word(_ row: Int, _ column: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: row + column * 8, as: UInt64.self)) }
                func text(_ x: UInt64) throws -> String? {
                    guard x <= UInt64(strings.count) else { throw CocoaError(.fileReadCorruptFile) }
                    return x == 0 ? nil : strings[Int(x - 1)]
                }
                for row in stride(from: 0, to: rows.count, by: width) {
                    guard let source = try text(word(row, 0)), let model = try text(word(row, 1)), word(row, 4) <= 1, word(row, 5) <= 1,
                          word(row, 13) <= UInt64(Int.max), word(row, 14) <= UInt64(Int.max) else { throw CocoaError(.fileReadCorruptFile) }
                    let timestamp = TimeInterval(bitPattern: word(row, 3))
                    guard timestamp.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    let usage = ModelTotals(ctx: Int64(bitPattern: word(row, 6)), cacheRead: Int64(bitPattern: word(row, 7)),
                                            cacheWrite: Int64(bitPattern: word(row, 8)), out: Int64(bitPattern: word(row, 9)), think: Int64(bitPattern: word(row, 10)))
                    result.append(FrozenBucket(source: source, model: model, tier: try text(word(row, 2)), timestamp: timestamp,
                                               peak: word(row, 4) == 1, longContext: word(row, 5) == 1, usage: usage,
                                               fresh: Int64(bitPattern: word(row, 11)), cw1h: Int64(bitPattern: word(row, 12)), turns: Int(word(row, 13)),
                                               cumulative: Int(word(row, 14)), minContext: Int64(bitPattern: word(row, 15)), maxContext: Int64(bitPattern: word(row, 16))))
                }
            }
            return result
        }
    }

    private struct FileState: Codable, Equatable {
        var source: String
        var model = "?"
        var size: UInt64 = 0
        var mtime: TimeInterval = 0
        var offset: UInt64 = 0
        var head = ""
        var previousTotal: [String: Int64]?
        var records: [String: Record] = [:]
        var skipped = 0
        var frozen: [FrozenBucket]? = nil
        var frozenBefore: TimeInterval? = nil
        /// Sessions include duplicate Claude records, just as the v3 accounting did.
        var frozenSessions: [String: [String: Set<String>]]? = nil // day → source → sessions
        var frozenRecordCount: Int? = nil
        /// Only local Claude needs cross-file request deduplication after compaction.
        var frozenClaudeIDs: Set<String>? = nil
        var frozenPeakDefinition: String? = nil
        /// 远程来源专用：上次拉到的最大 time_updated / 文件 mtime（毫秒），下次只拉比它更新的。
        var cursor: Int64? = nil
        /// 远程来源专用：上次全量拉取时刻；超过一天就强制全量，把远端删掉的会话清出去。
        var fullAt: TimeInterval? = nil
        /// 远程计时首次补采是否成功；可选，兼容没有计时字段的旧缓存。
        var timingFetched: Bool? = nil
        // ---- 以下为 parser 2 新增，全部可选，老缓存照样能解 ----
        var tier: String? = nil
        var hasUsageRecords: Bool? = nil
        var forked: Bool? = nil
        var burstLast: TimeInterval? = nil
        var burstFirstId: String? = nil
        var burstDone: Bool? = nil
        var replayed: Int? = nil
        var ancestors: [String: TimeInterval]? = nil
        var previousEventAt: TimeInterval? = nil
        var latestResponseID: String? = nil
        var account: AccountIdentity? = nil
        var metadataVersion: Int? = nil
        var turnLatencies: [TurnLatencySample]? = nil
        var turnModels: [String: String]? = nil
        var failedTurns: Set<String>? = nil
        /// Remote sources only: 1 once DSH / Grok records had their one-time full pull.
        var toolsVersion: Int? = nil

        init(source: String, records: [String: Record] = [:]) { self.source = source; self.records = records }
        private enum CodingKeys: String, CodingKey {
            case source, model, size, mtime, offset, head, previousTotal, skipped, cursor, fullAt, tier, hasUsageRecords, forked, burstLast, burstFirstId, burstDone, replayed, frozenBefore, frozenSessions, frozenRecordCount, frozenClaudeIDs, frozenPeakDefinition
            case records, frozen, recordsPacked, frozenPacked, timings, ancestors, previousEventAt, latestResponseID, timingFetched
            case account, recordAccounts, frozenAccounts, frozenRequestIDs, metadataVersion, turnLatencies, turnModels, failedTurns
            case recordCosts, frozenCosts, toolsVersion
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            account = try c.decodeIfPresent(AccountIdentity.self, forKey: .account)
            metadataVersion = try c.decodeIfPresent(Int.self, forKey: .metadataVersion)
            turnLatencies = try c.decodeIfPresent([TurnLatencySample].self, forKey: .turnLatencies)
            turnModels = try c.decodeIfPresent([String: String].self, forKey: .turnModels)
            failedTurns = try c.decodeIfPresent(Set<String>.self, forKey: .failedTurns)
            ancestors = try c.decodeIfPresent([String: TimeInterval].self, forKey: .ancestors)
            previousEventAt = try c.decodeIfPresent(TimeInterval.self, forKey: .previousEventAt)
            latestResponseID = try c.decodeIfPresent(String.self, forKey: .latestResponseID)
            source = try c.decode(String.self, forKey: .source)
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? "?"
            size = try c.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
            mtime = try c.decodeIfPresent(TimeInterval.self, forKey: .mtime) ?? 0
            offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
            head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
            previousTotal = try c.decodeIfPresent([String: Int64].self, forKey: .previousTotal)
            skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
            cursor = try c.decodeIfPresent(Int64.self, forKey: .cursor)
            fullAt = try c.decodeIfPresent(TimeInterval.self, forKey: .fullAt)
            timingFetched = try c.decodeIfPresent(Bool.self, forKey: .timingFetched)
            tier = try c.decodeIfPresent(String.self, forKey: .tier)
            hasUsageRecords = try c.decodeIfPresent(Bool.self, forKey: .hasUsageRecords)
            forked = try c.decodeIfPresent(Bool.self, forKey: .forked)
            burstLast = try c.decodeIfPresent(TimeInterval.self, forKey: .burstLast)
            burstFirstId = try c.decodeIfPresent(String.self, forKey: .burstFirstId)
            burstDone = try c.decodeIfPresent(Bool.self, forKey: .burstDone)
            replayed = try c.decodeIfPresent(Int.self, forKey: .replayed)
            frozenBefore = try c.decodeIfPresent(TimeInterval.self, forKey: .frozenBefore)
            frozenSessions = try c.decodeIfPresent([String: [String: Set<String>]].self, forKey: .frozenSessions)
            frozenRecordCount = try c.decodeIfPresent(Int.self, forKey: .frozenRecordCount)
            frozenClaudeIDs = try c.decodeIfPresent(Set<String>.self, forKey: .frozenClaudeIDs)
            frozenPeakDefinition = try c.decodeIfPresent(String.self, forKey: .frozenPeakDefinition)
            if let packed = try c.decodeIfPresent(PackedRows.self, forKey: .recordsPacked) { records = try packed.records() }
            else { records = try c.decodeIfPresent([String: Record].self, forKey: .records) ?? [:] }
            if let packed = try c.decodeIfPresent(PackedRows.self, forKey: .frozenPacked) { frozen = try packed.frozen() }
            else { frozen = try c.decodeIfPresent([FrozenBucket].self, forKey: .frozen) }
            for (id, timing) in try c.decodeIfPresent([String: PerformanceTiming].self, forKey: .timings) ?? [:] { records[id]?.timing = timing }
            for (id, identity) in try c.decodeIfPresent([String: AccountIdentity].self, forKey: .recordAccounts) ?? [:] { records[id]?.account = identity }
            for (index, identity) in try c.decodeIfPresent([String: AccountIdentity].self, forKey: .frozenAccounts) ?? [:] {
                if let i = Int(index), frozen?.indices.contains(i) == true { frozen?[i].account = identity }
            }
            for (index, id) in try c.decodeIfPresent([String: String].self, forKey: .frozenRequestIDs) ?? [:] {
                if let i = Int(index), frozen?.indices.contains(i) == true { frozen?[i].exactRequestID = id }
            }
            toolsVersion = try c.decodeIfPresent(Int.self, forKey: .toolsVersion)
            for (id, cost) in try c.decodeIfPresent([String: BilledCost].self, forKey: .recordCosts) ?? [:] { records[id]?.billed = cost }
            for (index, cost) in try c.decodeIfPresent([String: BilledCost].self, forKey: .frozenCosts) ?? [:] {
                if let i = Int(index), frozen?.indices.contains(i) == true { frozen?[i].billed = cost }
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(account, forKey: .account)
            try c.encodeIfPresent(metadataVersion, forKey: .metadataVersion)
            try c.encodeIfPresent(turnLatencies, forKey: .turnLatencies)
            try c.encodeIfPresent(turnModels, forKey: .turnModels)
            try c.encodeIfPresent(failedTurns, forKey: .failedTurns)
            let recordAccounts = records.compactMapValues { $0.account }
            if !recordAccounts.isEmpty { try c.encode(recordAccounts, forKey: .recordAccounts) }
            var frozenAccounts: [String: AccountIdentity] = [:], frozenRequestIDs: [String: String] = [:]
            for (i, b) in (frozen ?? []).enumerated() { frozenAccounts[String(i)] = b.account; frozenRequestIDs[String(i)] = b.exactRequestID }
            if !frozenAccounts.isEmpty { try c.encode(frozenAccounts, forKey: .frozenAccounts) }
            if !frozenRequestIDs.isEmpty { try c.encode(frozenRequestIDs, forKey: .frozenRequestIDs) }
            try c.encodeIfPresent(toolsVersion, forKey: .toolsVersion)
            let recordCosts = records.compactMapValues { $0.billed }
            if !recordCosts.isEmpty { try c.encode(recordCosts, forKey: .recordCosts) }
            var frozenCosts: [String: BilledCost] = [:]
            for (i, b) in (frozen ?? []).enumerated() { frozenCosts[String(i)] = b.billed }
            if !frozenCosts.isEmpty { try c.encode(frozenCosts, forKey: .frozenCosts) }
            try c.encodeIfPresent(ancestors, forKey: .ancestors)
            try c.encodeIfPresent(previousEventAt, forKey: .previousEventAt)
            try c.encodeIfPresent(latestResponseID, forKey: .latestResponseID)
            let timings = records.compactMapValues { $0.timing }
            if !timings.isEmpty { try c.encode(timings, forKey: .timings) }
            try c.encode(source, forKey: .source)
            try c.encode(model, forKey: .model)
            try c.encode(size, forKey: .size)
            try c.encode(mtime, forKey: .mtime)
            try c.encode(offset, forKey: .offset)
            try c.encode(head, forKey: .head)
            try c.encodeIfPresent(previousTotal, forKey: .previousTotal)
            try c.encode(skipped, forKey: .skipped)
            try c.encodeIfPresent(cursor, forKey: .cursor)
            try c.encodeIfPresent(timingFetched, forKey: .timingFetched)
            try c.encodeIfPresent(fullAt, forKey: .fullAt)
            try c.encodeIfPresent(tier, forKey: .tier)
            try c.encodeIfPresent(hasUsageRecords, forKey: .hasUsageRecords)
            try c.encodeIfPresent(forked, forKey: .forked)
            try c.encodeIfPresent(burstLast, forKey: .burstLast)
            try c.encodeIfPresent(burstFirstId, forKey: .burstFirstId)
            try c.encodeIfPresent(burstDone, forKey: .burstDone)
            try c.encodeIfPresent(replayed, forKey: .replayed)
            try c.encodeIfPresent(frozenBefore, forKey: .frozenBefore)
            try c.encodeIfPresent(frozenSessions, forKey: .frozenSessions)
            try c.encodeIfPresent(frozenRecordCount, forKey: .frozenRecordCount)
            try c.encodeIfPresent(frozenClaudeIDs, forKey: .frozenClaudeIDs)
            try c.encodeIfPresent(frozenPeakDefinition, forKey: .frozenPeakDefinition)
            if encoder.userInfo[UsageHistory.legacyCacheEncoding] as? Bool == true {
                try c.encode(records, forKey: .records)
                try c.encodeIfPresent(frozen, forKey: .frozen)
            } else {
                try c.encode(PackedRows.records(records), forKey: .recordsPacked)
                if let frozen { try c.encode(PackedRows.frozen(frozen), forKey: .frozenPacked) }
            }
        }
    }
    private struct AccountCoverage: Codable {
        var accountKey: String
        var source: String
        var pool: String
        var startedAt: TimeInterval
        var lastSuccess: TimeInterval
    }
    private struct DiskCache: Codable {
        var version = 4
        var files: [String: FileState] = [:]
        var days: [Day] = []
        var updatedAt: TimeInterval = 0
        /// 解析器版本：升级后仍在磁盘上的日志重解析一次（已删除日志的历史保留）。
        var parser: Int? = nil
        var accountCoverage: [String: AccountCoverage]? = nil
    }
    /// LZFSE keeps the precise 7–35 day timestamps without paying JSON's repeated-key cost.
    /// The payload is still the full versioned DiskCache plist, including every legacy field.
    private struct CompressedCache: Codable {
        var version = 4
        var compression = "lzfse"
        var archive: Data
    }
    private static let parserVersion = 2

    private enum Kind { case claude, codex, opencode, api, remote }
    private static func kind(of source: String) -> Kind {
        if source.hasPrefix("Claude") { return .claude }
        if source.hasPrefix("Codex") { return .codex }
        if source.hasPrefix("OpenCode") { return .opencode }
        if source.hasPrefix("Remote") { return .remote }
        return .api
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "io.github.xixilys.vibedeck.usage-history", qos: .utility)
    private let log = Logger(subsystem: "io.github.xixilys.vibedeck", category: "usage-history")
    private let home: String
    private let cachePath: String
    private let opencodeDB: String
    private let catalogOverride: PricingCatalog.Catalog?
    private var remoteStatus: [String: Bool] = [:]
    private var remoteError: [String: String] = [:]
    private var remoteCLIStatus: [String: String] = [:]
    private var remotePulledAt: [String: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?
    private var started = false
    private var loaded = false
    private var errors: Set<String> = []
    private struct TimingRef {
        var id: String
        var source: String
        var model: String
        var timestamp: TimeInterval
    }
    private var timingIndex: [String: [TimingRef]] = [:]
    private var performanceCutoff = Date().timeIntervalSince1970 - 86400
    private var cache = DiskCache()
    private var cached = Snapshot()
    /// 仅保存最近七天的原始记录；更早的按计价维度冻结。有变化才写，至少隔 30 分钟。
    /// 下次从旧 offset 重读，记录按 requestId/行偏移做键，重复读不会重复计数。
    private var dirty = false
    private var summaryDirty = Set<String>()
    private var nextFreezeAt: [String: TimeInterval] = [:]
    private var fileSummaries: [String: FileSummary] = [:]
    private var priceData: Data?
    private var summaryTimeZone = ""
    private var summaryPricesLoaded = false
    private var pricingWarnings = Set<String>()
    private var migrationPending = false
    private var freezingEnabled = true
    private var migrationError: String?
    private var frozenClaudeIDs: [String: Set<String>] = [:]
    private static let rawWindow: TimeInterval = 7 * 86400
    private static let forecastWindow: TimeInterval = 35 * 86400
    private var savedAt: TimeInterval = 0
    private static let saveEvery: TimeInterval = 1800
    private static let scanEvery: TimeInterval = 120
    private static let remoteEvery: TimeInterval = 300
    private let iso = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private static let tokenKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let codexMarkers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\"", "\"token_usage_record\"", "\"thread_settings_applied\"", "\"function_call_output\"", "\"user_message\"", "\"task_complete\"", "\"turn_complete\"", "\"turn_id\""].map { Data($0.utf8) }

    /// `opencodeDB` / `catalog` 只在自测里注入：真实路径按 XDG 规则算，内置价随 bundle 分发。
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, cachePath: String? = nil, opencodeDB: String? = nil,
                catalog: PricingCatalog.Catalog? = nil) {
        self.home = home
        self.cachePath = cachePath ?? "\(home)/.config/vibedeck/usage-daily.json"
        self.opencodeDB = opencodeDB ?? OpenCodeUsage.databasePath(home: home)
        self.catalogOverride = catalog
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: Self.scanEvery)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 锁只保护快照交换，不参与读盘、解码、归并或落盘。
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 立即重扫一次（价格表更新后刷新成本时用）。
    public func refreshNow() { worker.sync { scan() } }

    /// 后台排队重扫（面板上的「刷新」按钮，不阻塞主线程）。
    public func refreshSoon() { worker.async { [weak self] in
        guard let self else { return }
        self.fileSummaries.removeAll()
        self.scan(forceRemote: true)
    } }

    func scanNowForTesting() { refreshNow() }

    static func performanceSelfTest() {
        let collector = UsageHistory(home: "/nonexistent-vibedeck-test")
        let start = Date().timeIntervalSince1970 - 60
        func line(_ object: [String: Any], _ offset: UInt64, _ state: inout FileState) {
            collector.consume(try! JSONSerialization.data(withJSONObject: object), offset: offset, state: &state)
        }
        var claude = FileState(source: "Claude")
        line(["type": "user", "uuid": "u", "timestamp": start, "parentUuid": NSNull()], 0, &claude)
        func assistant(_ uuid: String, _ parent: String, _ at: Double, _ out: Int) -> [String: Any] {
            ["type": "assistant", "uuid": uuid, "parentUuid": parent, "requestId": "req", "timestamp": at,
             "message": ["model": "fixture", "usage": ["input_tokens": 100, "output_tokens": out]]]
        }
        line(assistant("a", "u", start + 2, 100), 1, &claude)
        line(assistant("b", "a", start + 4, 200), 2, &claude)
        line(assistant("c", "b", start + 5, 0), 3, &claude)
        precondition(claude.records.count == 1 && claude.records["req"]?.usage.out == 200)
        precondition(claude.records["req"]?.timing?.speed(output: 200, proxy: false) == 40, "Claude uses final timestamp and maximum output")
        line(assistant("copy", "absent", start + 5, 200), 3, &claude)
        precondition(claude.records["req"]?.timing?.seconds == 5, "same-timestamp replay without parent preserves timing")
        line(["type": "user", "uuid": "tool", "parentUuid": "c", "timestamp": start + 10], 4, &claude)
        var second = assistant("d", "tool", start + 12, 100); second["requestId"] = "req2"
        line(second, 5, &claude)
        precondition(claude.records["req2"]?.timing?.seconds == 2, "tool_result resets nearest user ancestor")
        var missing = assistant("e", "missing", start + 15, 100); missing["requestId"] = "missing"
        line(missing, 6, &claude)
        precondition(claude.records["missing"]?.timing == nil)
        let fields: [String: Any] = ["input_tokens": 1000, "output_tokens": 200]
        var codex = FileState(source: "Codex")
        line(["type": "event_msg", "timestamp": start, "payload": ["type": "user_message"]], 0, &codex)
        line(["type": "event_msg", "timestamp": start + 4, "payload": ["type": "token_count", "info": ["last_token_usage": fields, "total_token_usage": fields]]], 1, &codex)
        precondition(codex.records["1"]?.timing?.speed(output: 200, proxy: false) == 50)
        line(["type": "response_item", "timestamp": start + 5, "payload": ["type": "function_call_output"]], 2, &codex)
        line(["type": "token_usage_record", "timestamp": start + 9, "payload": ["response_id": "resp-1", "usage": fields]], 3, &codex)
        var total = fields; total["input_tokens"] = 2000; total["output_tokens"] = 400
        line(["type": "event_msg", "timestamp": start + 9, "payload": ["type": "token_count", "info": ["last_token_usage": fields, "total_token_usage": total]]], 4, &codex)
        precondition(codex.records.count == 1 && codex.records["resp-1"]?.timing?.seconds == 4, "new Codex accounting keeps token_count timing without duplicate usage")
        line(["type": "token_usage_record", "timestamp": start + 9, "payload": ["response_id": "resp-1", "usage": fields]], 5, &codex)
        line(["type": "event_msg", "timestamp": start + 9, "payload": ["type": "token_count", "info": ["last_token_usage": fields, "total_token_usage": total]]], 6, &codex)
        precondition(codex.records.count == 1 && codex.records["resp-1"]?.timing?.seconds == 4, "identical exact usage replay preserves timing")
        precondition(PerformanceTiming.estimated(output: 49, seconds: 2) == nil)
        precondition(PerformanceTiming.estimated(output: 50, seconds: 0.99) == nil)
        precondition(PerformanceTiming.estimated(output: 50, seconds: 601) == nil)
        precondition(PerformanceTiming.proxy(ms: 2500, ttft: 500, status: 200).speed(output: 100, proxy: true) == 50)
        precondition(PerformanceTiming.proxy(ms: 900, ttft: 500, status: 200).speed(output: 100, proxy: true) == nil)
        precondition(PerformanceTiming.proxy(ms: 2500, ttft: nil, status: 200).speed(output: 100, proxy: true) == nil)
        precondition(PerformanceStats.percentile([10, 20, 30], 0.5) == 20)
        precondition(PerformanceStats.percentile([], 0.95) == nil)
        let encoded = try! PropertyListEncoder().encode(claude)
        let decoded = try! PropertyListDecoder().decode(FileState.self, from: encoded)
        precondition(decoded.records == claude.records && decoded.ancestors == claude.ancestors, "packed cache preserves optional timings and parent state")
        var legacy = FileState(source: "Claude", records: ["old": Record(id: "old", source: "Claude", timestamp: start, model: "fixture", usage: ModelTotals(out: 100))])
        legacy.ancestors = nil
        let oldDecoded = try! PropertyListDecoder().decode(FileState.self, from: PropertyListEncoder().encode(legacy))
        precondition(oldDecoded.records["old"]?.timing == nil && oldDecoded.records.count == 1 && oldDecoded.timingFetched == nil)
        legacy.timingFetched = true
        let backfilled = try! PropertyListDecoder().decode(FileState.self, from: PropertyListEncoder().encode(legacy))
        precondition(backfilled.timingFetched == true, "one-time remote timing backfill survives cache round-trip")
        var many = FileState(source: "Claude")
        for i in 0..<501 {
            let id = "sample-\(i)"
            many.records[id] = Record(id: id, source: "Claude", timestamp: start + Double(i) / 1000, model: "fixture",
                                      usage: ModelTotals(ctx: 100, out: 100), timing: PerformanceTiming(seconds: 2))
        }
        collector.updateFile("fixture", many)
        collector.trimTimings(now: start + 1)
        precondition(collector.cache.files["fixture"]!.records.count == 501)
        precondition(collector.cache.files["fixture"]!.records.values.filter { $0.timing?.seconds != nil }.count == 500)
        precondition(collector.cache.files["fixture"]!.records["sample-0"]?.timing == nil)
        let recent = collector.summarize().recentBySource["Claude"]!
        precondition(recent.requestsLastHour == 501 && recent.contextLastHour == 50_100, "context fallback uses uncapped records")
        collector.trimTimings(now: start + 86402)
        precondition(collector.cache.files["fixture"]!.records.values.allSatisfy { $0.timing == nil })
    }

    /// Small fixtures exercise the same migration / replay helpers used by the real collectors.
    static func historyCacheSelfTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibedeck-frozen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let config = root.appendingPathComponent(".config/vibedeck")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let path = config.appendingPathComponent("usage-daily.json")
            let catalog = PricingCatalog.parse(["_asof": "fixture", "fixture": ["in": 1, "out": 4, "cr": 0.1, "cw": 1.25, "cw1h": 2,
                                                   "lc": ["threshold": 100, "in": 2, "out": 6, "cr": 0.2, "cw": 2.5],
                                                   "pri": ["in": 2, "out": 8, "cr": 0.2]]])
            let now = Date().timeIntervalSince1970
            let boundary = now - Self.rawWindow
            let source = "Codex · fixture"
            func record(_ id: String, _ at: TimeInterval, _ ctx: Int64, tier: String? = nil) -> Record {
                Record(id: id, source: source, timestamp: at, model: "fixture",
                       usage: ModelTotals(ctx: ctx, cacheRead: 10, cacheWrite: 5, out: 7, think: 3),
                       cumulative: true, session: "s1", cw1h: 3, tier: tier)
            }
            let old = record("old", boundary - 0.001, 150, tier: "priority")
            let edge = record("edge", boundary, 90)
            let recent = record("recent", boundary + 0.001, 80)
            let ancient = record("ancient", now - 50 * 86400 + 123, 40)
            let initial = [old, edge, recent, ancient]
            var v3 = DiskCache()
            v3.version = 3; v3.parser = Self.parserVersion
            v3.files["remote-cli://fixture"] = FileState(source: "Remote · fixture", records: Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) }))
            let legacyEncoder = JSONEncoder()
            legacyEncoder.userInfo[Self.legacyCacheEncoding] = true
            let bytes = try legacyEncoder.encode(v3)
            try bytes.write(to: path)
            let collector = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("none.db").path, catalog: catalog)
            collector.loadCache()
            precondition(collector.cache.version == 4 && collector.migrationPending, "v3 必须迁移，不能丢掉旧字段")
            let before = collector.summarize()
            collector.freezeOldRecords(now: now)
            var state = collector.cache.files["remote-cli://fixture"]!
            precondition(state.records[old.id] == nil && state.records[ancient.id] == nil)
            precondition(state.records[edge.id] != nil && state.records[recent.id] != nil, "正好七天仍保留原始记录")
            let after = collector.summarize()
            precondition(before.days == after.days && before.totals == after.totals && before.aggregate == after.aggregate)
            precondition(abs(before.costByCurrency["USD"]! - after.costByCurrency["USD"]!) < 1e-10, "长上下文和 priority 不能对合计 token 再分档")
            // A full remote refresh clears the live window, then sends all records again.
            state.records = [:]
            for r in initial { collector.store(r, in: &state) }
            collector.updateFile("remote-cli://fixture", state)
            let replay = collector.summarize()
            precondition(replay.days == after.days && replay.totals == after.totals, "冻结后全量重拉不能重复计数")
            precondition(replay.cumulativeTurns == after.cumulativeTurns)
            let prices = config.appendingPathComponent("prices.json")
            func writePrice(_ multiplier: Double) throws {
                let json: [String: Any] = ["_currency": "TEST", "fixture": ["in": multiplier, "out": 4 * multiplier, "cache_read": 0.1 * multiplier,
                                                                           "cache_write": 1.25 * multiplier, "fast_multiplier": 2]]
                try JSONSerialization.data(withJSONObject: json).write(to: prices, options: .atomic)
            }
            try writePrice(1)
            let priced = collector.summarize()
            let raw = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("none.db").path, catalog: catalog)
            raw.cache = v3
            precondition(abs(priced.costByCurrency["TEST"]! - raw.summarize().costByCurrency["TEST"]!) < 1e-10)
            try writePrice(2)
            let repriced = collector.summarize()
            precondition(repriced.totals == priced.totals && abs(repriced.costByCurrency["TEST"]! - 2 * priced.costByCurrency["TEST"]!) < 1e-10,
                         "价格变更必须让所有文件的汇总失效一次")
            precondition(collector.saveCache())
            let v4 = try Data(contentsOf: path)
            precondition(v4.starts(with: Data("bplist".utf8)))
            let backup = config.appendingPathComponent("usage-daily.v3.bak.json")
            let backupBytes = try Data(contentsOf: backup)
            precondition(backupBytes == bytes, "迁移备份必须保留原始 v3 字节")
            let restarted = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("none.db").path, catalog: catalog)
            restarted.loadCache()
            precondition(restarted.cache.version == 4 && !restarted.migrationPending && restarted.summarize().totals == repriced.totals)
            let backupAfterRestart = try Data(contentsOf: backup)
            precondition(backupAfterRestart == bytes, "v4 重启不能重复备份")
            // Two short requests sharing a bucket must not become a long-context request when added.
            let a = record("a", now - 50 * 86400, 80)
            let b = record("b", a.timestamp, 80)
            let short = UsageHistory(home: root.appendingPathComponent("short").path, catalog: catalog)
            short.cache.files["remote-cli://short"] = FileState(source: "Remote", records: [a.id: a, b.id: b])
            let shortBefore = short.summarize()
            short.freezeOldRecords(now: now)
            precondition(abs(short.summarize().costByCurrency["USD"]! - shortBefore.costByCurrency["USD"]!) < 1e-10)
            // A duplicate can straddle the freeze boundary in either preference direction.
            for olderWins in [true, false] {
                let duplicate = UsageHistory(home: root.appendingPathComponent(UUID().uuidString).path, catalog: catalog)
                var oldRequest = record("same-request", boundary - 1, olderWins ? 90 : 40)
                oldRequest.source = "Claude"
                var newRequest = record("same-request", boundary + 1, olderWins ? 40 : 90)
                newRequest.source = "Claude"
                duplicate.cache.files["a"] = FileState(source: "Claude", records: [oldRequest.id: oldRequest])
                duplicate.cache.files["b"] = FileState(source: "Claude", records: [newRequest.id: newRequest])
                let expected = duplicate.summarize()
                duplicate.freezeOldRecords(now: now)
                precondition(duplicate.summarize().days == expected.days, "跨七天边界的 Claude 重复记录只能算优选的一条")
            }
        } catch { preconditionFailure("历史缓存 v4 自测失败：\(error)") }
    }

    static func accountingSelfTest() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibedeck-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let now = Date().timeIntervalSince1970
            let a = AccountIdentity(provider: "openai", accountID: "fixture-a")!
            let b = AccountIdentity(provider: "openai", accountID: "fixture-b")!
            let catalog = PricingCatalog.parse(["fixture": ["in": 1, "out": 4]])
            let history = UsageHistory(home: root.path, catalog: catalog)
            var r = Record(id: "resp_a", source: "Codex", timestamp: now - 8 * 86400, model: "fixture",
                           usage: ModelTotals(ctx: 100, out: 20), account: a)
            var other = r; other.id = "resp_b"; other.account = b
            let file = FileState(source: "Codex", records: [r.id: r, other.id: other])
            // Optional account sidecars leave packed row widths and legacy token decoding unchanged.
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let data = try encoder.encode(file)
            let decoded = try PropertyListDecoder().decode(FileState.self, from: data)
            precondition(decoded.records == file.records)
            precondition(PackedRows.records(file.records).rows.count == 2 * 13 * 8)
            let raw = try PackedRows.records(file.records).records()
            precondition(raw[r.id]?.usage == r.usage && raw[r.id]?.account == nil)
            let legacy = JSONEncoder(); legacy.userInfo[Self.legacyCacheEncoding] = true
            var unknown = file; unknown.records[r.id]?.account = nil; unknown.records[other.id]?.account = nil
            let legacyRoundtrip = try JSONDecoder().decode(FileState.self, from: legacy.encode(unknown))
            precondition(legacyRoundtrip.records[r.id]?.account == nil && legacyRoundtrip.records.count == 2)
            history.cache.files["fixture"] = file
            let before = history.summarize()
            history.freezeOldRecords(now: now)
            let frozen = history.cache.files["fixture"]!
            precondition(frozen.frozen?.count == 2 && Set(frozen.frozen!.compactMap { $0.account?.key }).count == 2)
            let roundtrip = try PropertyListDecoder().decode(FileState.self, from: encoder.encode(frozen))
            precondition(roundtrip == frozen && roundtrip.frozen!.allSatisfy { $0.exactRequestID != nil })
            precondition(PackedRows.frozen(frozen.frozen!).rows.count == 2 * 17 * 8)
            let after = history.summarize()
            precondition(before.totals == after.totals && before.accountUsage.groups == after.accountUsage.groups)
            // Cross-device exact request dedup remains available after both copies have frozen.
            var copied = r; copied.source = "Codex · fixture"; copied.id = "codex:resp_a"
            history.cache.files["remote-cli://fixture"] = FileState(source: "Remote · fixture", records: [copied.id: copied])
            history.freezeOldRecords(now: now)
            let combined = history.summarize().accountUsage
            precondition(combined.groups.first { $0.account == a }?.totals.requests == 1)
            // Timing backfill reads only metadata/events; token counts, parser state and offsets are untouched.
            let path = root.appendingPathComponent("rollout.jsonl")
            let objects: [[String: Any]] = [
                ["type": "session_meta", "payload": ["creator_account_id": "fixture-a", "model_provider": "openai"]],
                ["timestamp": now - 10, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-a", "root_turn_id": "root", "time_to_first_token_ms": 12, "error": NSNull()]],
                ["timestamp": now - 9, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "turn-child", "root_turn_id": "root", "time_to_first_token_ms": 20, "error": "failed"]]
            ]
            var bytes = Data()
            for object in objects { bytes.append(try JSONSerialization.data(withJSONObject: object)); bytes.append(0x0A) }
            try bytes.write(to: path)
            var oldState = FileState(source: "Codex", records: unknown.records)
            oldState.offset = UInt64(bytes.count); oldState.size = oldState.offset
            oldState.previousTotal = ["input_tokens": 120]
            let fh = try FileHandle(forReadingFrom: path); defer { try? fh.close() }
            try history.backfillCodexMetadata(fh, size: UInt64(bytes.count), mtime: now, state: &oldState)
            precondition(oldState.offset == UInt64(bytes.count) && oldState.previousTotal == ["input_tokens": 120])
            precondition(oldState.records.count == 2 && oldState.records[r.id]?.usage == r.usage)
            precondition(oldState.records.values.allSatisfy { $0.account == a })
            precondition(oldState.turnLatencies?.count == 2 && PerformanceStats.turnTTFT(oldState.turnLatencies!, since: now - 100, until: now) == 12)
            history.consume(Data(try JSONSerialization.data(withJSONObject: objects[1])), offset: 999, state: &oldState)
            precondition(oldState.records.count == 2 && oldState.turnLatencies?.count == 2)
            // Subscription cost stays included; API-equivalent pricing is independent and unknown stays nil.
            let engine = CostEngine(catalog: catalog)
            precondition(engine.cost(model: "chatgpt-web/fixture", ctx: 100, cacheRead: 0, cacheWrite: 0, out: 20)?.value == 0)
            precondition(engine.equivalentCost(model: "chatgpt-web/fixture", ctx: 100, cacheRead: 0, cacheWrite: 0, out: 20)!.value > 0)
            precondition(engine.equivalentCost(model: "chatgpt-web/gpt-6-pro", ctx: 100, cacheRead: 0, cacheWrite: 0, out: 20) == nil)
            r.timestamp = now
        } catch { preconditionFailure("Account history self-test: \(error)") }
    }

    // MARK: - 设备

    /// 挂载目录：`defaults write io.github.xixilys.vibedeck mountRoots "wsl=/Volumes/wsl/home/me; lab=/Volumes/lab/home/me"`。
    /// 每一项是另一台机器的家目录（里面有 .claude / .codex），标签就是面板里的设备名。
    public static func mountRoots(defaults: UserDefaults = .standard) -> [(label: String, path: String)] {
        guard let raw = defaults.string(forKey: "mountRoots") else { return [] }
        return parseMountRoots(raw)
    }

    public static func parseMountRoots(_ raw: String) -> [(label: String, path: String)] {
        var out: [(label: String, path: String)] = []
        var seen = Set<String>()
        for item in raw.split(whereSeparator: { ";\n,".contains($0) }) {
            let text = item.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var label: String, path: String
            if let eq = text.firstIndex(of: "=") {
                label = String(text[..<eq]).trimmingCharacters(in: .whitespaces)
                path = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else {
                path = text
                label = URL(fileURLWithPath: text).lastPathComponent
            }
            path = (path as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil,
                  seen.insert(label).inserted else { continue }
            out.append((label: label, path: path))
        }
        return out
    }

    // MARK: - 扫描

    private func scan(forceRemote: Bool = false) {
        errors = []
        if let migrationError { errors.insert(migrationError) }
        publishProgress(0, total: 0)
        loadCache()
        let paths = discoverFiles()
        let hosts = RemoteCollector.hosts()
        let now = Date().timeIntervalSince1970
        performanceCutoff = now - 86400
        let refreshHosts = CommandLine.arguments.contains("--selftest") ? [] : hosts.filter {
            forceRemote || now - (remotePulledAt[$0] ?? 0) >= Self.remoteEvery
        }
        let units = paths.count + 1 + hosts.count
        publishProgress(0, total: units)
        for (index, item) in paths.enumerated() {
            autoreleasepool { process(item.path, source: item.source) }
            publishProgress(index + 1, total: units)
        }
        // Baseline means collection has actually started, not the timestamp of an arbitrary old record.
        // Each known device/tool gets its own baseline; adding another device advances complete-account coverage.
        if errors.isEmpty {
            let activeSources = Set(paths.map { $0.source })
            for state in cache.files.values where activeSources.contains(state.source) {
                if let account = state.account {
                    recordAccountCoverage(account: account, source: state.source, pool: "codex", now: now)
                }
            }
        }
        ingestOpenCode()
        ingestDSH()
        ingestGrok()
        publishProgress(paths.count + 1, total: units)
        trimTimings(now: now)
        // SSH 冷扫描可能很慢；先让本机的新数据可见，远端仍保留上次记录。
        // 两次汇总都在同一个 worker 上，快照交换以外不持锁。
        if !refreshHosts.isEmpty {
            publish(makeSnapshot(paths: paths, hosts: hosts, processed: paths.count + 1, total: units,
                                 refreshingHosts: Set(refreshHosts), isScanning: true))
            ingestRemote(hosts: refreshHosts)
            trimTimings(now: Date().timeIntervalSince1970)
        }
        freezeOldRecords(now: now)
        var result = makeSnapshot(paths: paths, hosts: hosts, processed: units, total: units)
        cache.days = result.days
        cache.updatedAt = result.capturedAt
        if dirty, cache.updatedAt - savedAt >= Self.saveEvery {
            if saveCache() {
                dirty = false
                savedAt = cache.updatedAt
                migrationPending = false
            } else if migrationPending {
                // The atomic replacement failed: retain the original v3 file and its accounting.
                freezingEnabled = false
                migrationPending = false
                migrationError = "历史缓存迁移失败，继续使用 v3 缓存"
                errors.insert(migrationError!)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
                   let original = try? JSONDecoder().decode(DiskCache.self, from: data) {
                    cache = original
                    fileSummaries.removeAll()
                    result = makeSnapshot(paths: paths, hosts: hosts, processed: units, total: units)
                }
            }
        }
        result.error = errors.sorted().joined(separator: "；")
        publish(result)
        log.notice("历史汇总完成：\(paths.count) 文件，\(result.days.count) 天，跳过 \(result.skippedRecords) 条不完整记录")
    }

    private func makeSnapshot(paths: [(path: String, source: String)], hosts: [String], processed: Int, total: Int,
                              refreshingHosts: Set<String> = [], isScanning: Bool = false) -> Snapshot {
        var result = summarize()
        result.isScanning = isScanning
        result.processedFiles = processed
        result.totalFiles = total
        for source in ["Claude", "Codex"] where !paths.contains(where: { $0.source == source }) {
            result.sourceNotes[source] = result.totals[source] == nil ? "未检测到本机会话日志" : "日志已移除，显示已缓存历史"
        }
        if result.totals["OpenCode"] == nil {
            result.sourceNotes["OpenCode"] = FileManager.default.fileExists(atPath: opencodeDB) ? "未检测到 opencode 用量记录" : "未检测到 opencode 数据库"
        }
        for host in hosts {
            for cli in ["OpenCode", "Codex", "Claude"] {
                let source = "\(cli) · \(host)"
                let reason = cli == "OpenCode" ? (remoteStatus[host] == false ? remoteError[host] : nil) : remoteCLIStatus[host]
                result.sourceNotes[source] = Self.remoteSourceNote(cli: cli, hasHistory: result.totals[source] != nil,
                                                                   isRefreshing: refreshingHosts.contains(host), failure: reason)
            }
        }
        for root in Self.mountRoots() where !FileManager.default.fileExists(atPath: root.path) {
            result.sourceNotes["Claude · \(root.label)"] = "挂载目录不在：\(root.path)"
            result.sourceNotes["Codex · \(root.label)"] = "挂载目录不在：\(root.path)"
        }
        result.capturedAt = Date().timeIntervalSince1970
        result.error = errors.sorted().joined(separator: "；")
        return result
    }

    /// 拉取失败时，已有记录也必须说明是保留的历史，不能被本机刷新时间掩盖。
    static func remoteSourceNote(cli: String, hasHistory: Bool, isRefreshing: Bool, failure: String?) -> String? {
        if isRefreshing {
            return hasHistory ? L("正在刷新远端日志，显示已缓存历史", "Refreshing remote logs; showing retained history")
                              : L("正在读取远端日志", "Reading remote logs")
        }
        if let failure, failure.contains("opencode") && !hasHistory { return failure }
        if let failure {
            return hasHistory ? L("远端日志刷新失败（\(failure)），显示已缓存历史", "Remote refresh failed (\(failure)); showing retained history")
                              : L("未连上（\(failure)）", "Unavailable (\(failure))")
        }
        return hasHistory ? nil : L("远端无 \(cli) 记录", "No remote \(cli) records")
    }

    private func publish(_ result: Snapshot) {
        lock.lock()
        let old = cached
        cached = result
        lock.unlock()
        withExtendedLifetime(old) {}
    }

    private func discoverFiles() -> [(path: String, source: String)] {
        let fm = FileManager.default
        var result: [(path: String, source: String)] = []
        var roots: [(suffix: String, home: String)] = [("", home)]
        // 自测的临时 home 不读真实挂载目录
        if home == FileManager.default.homeDirectoryForCurrentUser.path {
            roots += Self.mountRoots().map { (suffix: " · \($0.label)", home: $0.path) }
        }
        for root in roots {
            let dirs: [(String, String)] = [(".claude/projects", "Claude"), (".config/claude/projects", "Claude"),
                                            (".codex/sessions", "Codex"), (".codex/archived_sessions", "Codex")]
            for (suffix, cli) in dirs {
                let base = URL(fileURLWithPath: "\(root.home)/\(suffix)")
                guard fm.fileExists(atPath: base.path) else { continue }
                guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in
                    self.errors.insert("部分日志目录无法读取，汇总可能不完整")
                    return true
                }) else { errors.insert("日志目录无法读取"); continue }
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    result.append((url.path, cli + root.suffix))
                }
            }
        }
        let api = "\(home)/.config/vibedeck/api-calls.jsonl"
        if fm.fileExists(atPath: api) { result.append((api, "API")) }
        return result.sorted { $0.path < $1.path }
    }

    /// 本机 opencode：一次 SQL 整表重读后替换这份伪文件的全部记录；读失败保留上次，绝不拿空数据覆盖。
    private func ingestOpenCode() {
        guard FileManager.default.fileExists(atPath: opencodeDB) else { return }   // 库不在 → 保留已缓存历史
        guard let records = OpenCodeUsage.read(dbPath: opencodeDB) else {
            errors.insert("opencode 用量库暂时读不到，保留上次汇总")
            return
        }
        if records.isEmpty, let cached = cache.files[opencodeDB], !cached.records.isEmpty {
            errors.insert("opencode 用量库读回 0 条，保留上次汇总")
            return
        }
        var state = cache.files[opencodeDB] ?? FileState(source: "OpenCode")
        var recent = records.filter { $0.value.timestamp >= (state.frozenBefore ?? 0) }
        // Bound before comparison: a full SQL reread must not restore stripped timings
        // and dirty an unchanged database on every scan.
        var counts: [String: Int] = [:]
        for var record in recent.values.filter({ $0.timing != nil }).sorted(by: {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
        }) {
            counts[record.model, default: 0] += 1
            if record.timestamp < performanceCutoff || counts[record.model]! > 500 {
                record.timing = nil
                recent[record.id] = record
            }
        }
        state.records = recent
        let latencies = OpenCodeUsage.latencies(dbPath: opencodeDB, since: Date().timeIntervalSince1970 - 86_400)
        if !latencies.isEmpty || state.turnLatencies != nil {
            state.turnLatencies = Self.mergedTurnLatencies((state.turnLatencies ?? []) + latencies, now: Date().timeIntervalSince1970)
        }
        updateFile(opencodeDB, state)
    }

    /// DSH daily ledger. Days that opencode already recorded with a DeepSeek model are skipped, because
    /// early DSH builds shared opencode's database and would otherwise be counted twice.
    private func ingestDSH() {
        let path = DSHUsage.ledgerPath(home: home)
        guard let result = DSHUsage.read(path: path) else {
            errors.insert("DSH 用量账本暂时读不到，保留上次汇总")
            return
        }
        Self.setDSHBalance(result.balance)
        guard !result.records.isEmpty else { return }
        let openCodeDays = Set((cache.files[opencodeDB]?.records ?? [:]).values
            .filter { $0.model.lowercased().hasPrefix("deepseek") }
            .map { Self.dayKey(timestamp: $0.timestamp) })
        var state = cache.files[path] ?? FileState(source: "DSH")
        state.source = "DSH"
        state.records = result.records.filter {
            !openCodeDays.contains(Self.dayKey(timestamp: $0.value.timestamp)) && $0.value.timestamp >= (state.frozenBefore ?? 0)
        }
        updateFile(path, state)
    }

    /// Grok CLI per-turn usage (`usage.json` per session). Unchanged files are not reread.
    private func ingestGrok() {
        for path in GrokUsage.files(home: home) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            var state = cache.files[path] ?? FileState(source: "Grok")
            if state.mtime == modified && state.size == size { continue }
            state.source = "Grok"
            state.mtime = modified; state.size = size
            state.records = GrokUsage.records(path: path).filter { $0.value.timestamp >= (state.frozenBefore ?? 0) }
            updateFile(path, state)
        }
    }

    private static let dshLock = NSLock()
    private static var dshBalanceValue: DSHUsage.Balance?
    /// Last DeepSeek balance DSH's cost meter saw; read by the panel's API quota list.
    static var dshBalance: DSHUsage.Balance? { dshLock.lock(); defer { dshLock.unlock() }; return dshBalanceValue }
    private static func setDSHBalance(_ value: DSHUsage.Balance?) { dshLock.lock(); dshBalanceValue = value; dshLock.unlock() }

    /// 远程主机：ssh 拉 opencode 增量 + Claude/Codex 逐条记录（按文件 mtime 游标增量）。
    /// 失败只更新状态、保留该主机上次的记录 —— 和日志被删后仍保留历史是同一个口径。
    private func ingestRemote(hosts: [String]) {
        for host in hosts {
            let now = Date().timeIntervalSince1970
            remotePulledAt[host] = now
            let key = "remote://\(host)"
            var state = cache.files[key] ?? FileState(source: "OpenCode · \(host)")
            let full = state.timingFetched != true || state.fullAt == nil || now - (state.fullAt ?? 0) >= 86400
            switch RemoteCollector.pullUsage(host: host, since: full ? 0 : (state.cursor ?? 0)) {
            case .failure(let error):
                remoteStatus[host] = false
                remoteError[host] = error.message
                if full { state.fullAt = now; updateFile(key, state) }
            case .success(let pull):
                remoteStatus[host] = true
                remoteError[host] = nil
                state.source = "OpenCode · \(host)"
                state.timingFetched = true
                if full { state.records = [:] }
                for record in pull.records { store(record, in: &state) }
                if pull.maxUpdated > 0 { state.cursor = max(state.cursor ?? 0, pull.maxUpdated) }
                if full { state.fullAt = now }
                updateFile(key, state)
            }
            // Claude / Codex 逐条：只拉 mtime 比游标新的文件（留 10 分钟余量），记录按 id 覆盖。
            let cliKey = "remote-cli://\(host)"
            var cli = cache.files[cliKey] ?? FileState(source: "Remote · \(host)")
            let incrementalSince = max(0, (cli.cursor ?? 0) - 600_000)
            let metadataBackfill = cli.metadataVersion != 1
            let since = !metadataBackfill && cli.timingFetched == true ? incrementalSince : min(incrementalSince, Int64((now - 86400) * 1000))
            // DSH / Grok records arrived after the Claude/Codex cursor; pull their history once, then follow the cursor.
            switch RemoteCollector.pullCLIRecords(host: host, since: since, includeIdentityBackfill: metadataBackfill,
                                                  toolsSince: cli.toolsVersion == 1 ? nil : 0) {
            case .failure(let error):
                remoteCLIStatus[host] = error.message
                log.notice("remote cli \(host, privacy: .public) 未连上：\(error.message, privacy: .public)")
            case .success(let pull):
                remoteCLIStatus[host] = nil
                cli.timingFetched = true
                cli.metadataVersion = 1
                cli.toolsVersion = 1
                if !pull.turnLatencies.isEmpty { cli.turnLatencies = Self.mergedTurnLatencies((cli.turnLatencies ?? []) + pull.turnLatencies, now: now) }
                if !pull.sessionAccounts.isEmpty {
                    for id in cli.records.keys {
                        guard cli.records[id]?.account == nil, let session = cli.records[id]?.session,
                              let identity = pull.sessionAccounts[(session as NSString).lastPathComponent] else { continue }
                        cli.records[id]?.account = identity
                    }
                }
                for record in pull.records {
                    if let old = cli.records[record.id], Self.kind(of: record.source) == .claude, !Self.prefer(record, over: old) { continue }
                    store(record, in: &cli)
                }
                for record in cli.records.values {
                    if let account = record.account {
                        recordAccountCoverage(account: account, source: record.source,
                            pool: AccountUsage.pool(model: record.model, source: record.source), now: now)
                    }
                }
                if pull.maxMtime > 0 { cli.cursor = max(cli.cursor ?? 0, pull.maxMtime) }
                updateFile(cliKey, cli)
                log.notice("remote cli \(host, privacy: .public) 收到 \(pull.records.count) 条")
            }
        }
    }

    private func recordAccountCoverage(account: AccountIdentity, source: String, pool: String, now: TimeInterval) {
        let key = [account.key, source, pool].joined(separator: "\u{1d}")
        var marker = cache.accountCoverage?[key] ?? AccountCoverage(accountKey: account.key, source: source, pool: pool,
                                                                   startedAt: now, lastSuccess: now)
        marker.lastSuccess = now
        if cache.accountCoverage == nil { cache.accountCoverage = [:] }
        cache.accountCoverage?[key] = marker
        dirty = true
    }

    private func process(_ path: String, source: String) {
        do {
            guard let probe = vgFileStat(path) else { throw CocoaError(.fileReadUnknown) }
            let size = probe.size
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let head = try fh.read(upToCount: 256) ?? Data()
            var state = cache.files[path] ?? FileState(source: source)
            let oldHead = Self.fingerprint(Data(head.prefix(Int(min(256, state.size)))))
            let sameSource = state.source == source
            let rewritten = state.offset > size || size < state.size || (!state.head.isEmpty && oldHead != state.head)
                || (size == state.size && probe.mtime != state.mtime)
            if state.source != source || rewritten {
                var replacement = FileState(source: source)
                // Rewrites replace the live window; frozen history has the same retention as removed logs.
                replacement.frozen = state.frozen
                replacement.frozenBefore = state.frozenBefore
                replacement.frozenSessions = state.frozenSessions
                replacement.frozenRecordCount = state.frozenRecordCount
                replacement.frozenClaudeIDs = state.frozenClaudeIDs
                replacement.frozenPeakDefinition = state.frozenPeakDefinition
                state = replacement
            }
            if Self.kind(of: source) == .codex, state.metadataVersion != 1 {
                try backfillCodexMetadata(fh, size: size, mtime: probe.mtime, attributeFrozen: sameSource && !rewritten, state: &state)
                updateFile(path, state)
            }
            if state.size == size, state.mtime == probe.mtime, state.head == Self.fingerprint(head) { return }
            try fh.seek(toOffset: state.offset)
            try readNewLines(fh, state: &state, size: size)
            state.head = Self.fingerprint(head)
            state.size = size; state.mtime = probe.mtime
            updateFile(path, state)
        } catch { errors.insert("部分日志无法读取，保留上次汇总并等待重试") }
    }

    private func readNewLines(_ fh: FileHandle, state: inout FileState, size: UInt64) throws {
        var remaining = size - state.offset
        var pending = Data()
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let end = pending.index(after: lastNL)
            let complete = pending[pending.startIndex..<end]
            var offset = state.offset
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                autoreleasepool { consume(Data(line), offset: offset, state: &state) }
                offset += UInt64(line.count + 1)
            }
            state.offset = offset
            pending = Data(pending[end...])
        }
    }

    private func consume(_ data: Data, offset: UInt64, state: inout FileState) {
        let kind = Self.kind(of: state.source)
        // 大多数行是工具结果和正文，先筛字段名，避免把数 GB 无关 JSON 全部解码。
        if kind == .claude, data.range(of: Self.usageMarker) == nil, data.range(of: Data("\"parentUuid\"".utf8)) == nil { return }
        if kind == .codex, !Self.codexMarkers.contains(where: { data.range(of: $0) != nil }) { return }
        guard !data.isEmpty else { return }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { state.skipped += 1; return }
        switch kind {
        case .claude: consumeClaude(j, state: &state)
        case .codex: consumeCodex(j, offset: offset, state: &state)
        default: consumeAPI(j, offset: offset, state: &state)
        }
    }

    static func mergedTurnLatencies(_ samples: [TurnLatencySample], now: TimeInterval) -> [TurnLatencySample] {
        var byID: [String: TurnLatencySample] = [:]
        for sample in samples where sample.timestamp >= now - 86400 && sample.timestamp <= now &&
            sample.timestamp.isFinite && sample.milliseconds.isFinite && sample.milliseconds >= 0 && !sample.turnID.isEmpty {
            if let old = byID[sample.id], old.timestamp > sample.timestamp { continue }
            byID[sample.id] = sample
        }
        var counts: [String: Int] = [:]
        return byID.values.sorted { $0.timestamp > $1.timestamp }.filter {
            counts[$0.source, default: 0] += 1
            return counts[$0.source]! <= 5000
        }
    }

    private func turnLatency(_ object: [String: Any], state: FileState) -> TurnLatencySample? {
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
              ["task_complete", "turn_complete"].contains(payload["type"] as? String ?? ""),
              let turn = payload["turn_id"] as? String, !turn.isEmpty,
              let value = payload["time_to_first_token_ms"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              case let ms = value.doubleValue, ms.isFinite, ms >= 0,
              let at = timestamp(object["timestamp"]), at >= performanceCutoff else { return nil }
        let error = payload["error"]
        return TurnLatencySample(turnID: turn, source: state.source, timestamp: at, milliseconds: ms,
            startedAt: timestamp(payload["started_at"]).flatMap { $0 <= at ? $0 : nil }, model: state.turnModels?[turn],
            account: state.account, failed: (error != nil && !(error is NSNull) && (error as? Bool != false)) ||
                state.failedTurns?.contains(turn) == true || ["failed", "error", "cancelled", "interrupted"].contains(payload["status"] as? String ?? ""))
    }

    private func observeTurnMetadata(_ object: [String: Any], state: inout FileState) {
        guard let payload = object["payload"] as? [String: Any], let turn = payload["turn_id"] as? String, !turn.isEmpty else { return }
        if object["type"] as? String == "turn_context", let model = payload["model"] as? String, !model.isEmpty {
            if state.turnModels == nil { state.turnModels = [:] }
            if state.turnModels?[turn] == nil { state.turnModels?[turn] = model }
            if (state.turnModels?.count ?? 0) > 512 { state.turnModels = [turn: model] }
        }
        if (payload["error"] != nil && !(payload["error"] is NSNull) && payload["error"] as? Bool != false) ||
            ["error", "turn_aborted"].contains(payload["type"] as? String ?? "") {
            if state.failedTurns == nil { state.failedTurns = [] }
            state.failedTurns?.insert(turn)
            if (state.failedTurns?.count ?? 0) > 512 { state.failedTurns = [turn] }
        }
    }

    /// Read immutable session identity plus a bounded recent timing tail without moving token cursors.
    /// Timing coverage: files modified in 24h, at most the final 32 MiB/file, 5000 samples/source.
    private func backfillCodexMetadata(_ fh: FileHandle, size: UInt64, mtime: TimeInterval, attributeFrozen: Bool = true, state: inout FileState) throws {
        try fh.seek(toOffset: 0)
        let header = try fh.read(upToCount: 65536) ?? Data()
        if let first = header.split(separator: 0x0A).first,
           let object = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
           object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
           let id = payload["creator_account_id"] as? String,
           let identity = AccountIdentity(provider: payload["model_provider"] as? String ?? "openai", accountID: id) {
            state.account = identity
            for key in state.records.keys where state.records[key]?.account == nil { state.records[key]?.account = identity }
            // A local rollout file has one immutable session creator. Remote mixed frozen buckets cannot use this path.
            if attributeFrozen {
                for i in (state.frozen ?? []).indices where state.frozen?[i].account == nil { state.frozen?[i].account = identity }
            }
        }
        if mtime >= performanceCutoff {
            let start = size > 32 * 1024 * 1024 ? size - 32 * 1024 * 1024 : 0
            try fh.seek(toOffset: start)
            let tail = try fh.read(upToCount: Int(min(size, 32 * 1024 * 1024))) ?? Data()
            var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: false)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            var samples = state.turnLatencies ?? []
            for line in lines where line.range(of: Data("turn_id".utf8)) != nil {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    observeTurnMetadata(object, state: &state)
                    if let sample = turnLatency(object, state: state) { samples.append(sample) }
                }
            }
            state.turnLatencies = Self.mergedTurnLatencies(samples, now: Date().timeIntervalSince1970)
        }
        state.metadataVersion = 1
    }

    private func consumeClaude(_ line: [String: Any], state: inout FileState) {
        // 子代理进度行把一条完整的 assistant 记录包在 data.message 里
        var entry = line
        if entry["message"] == nil || (entry["type"] as? String) != "assistant",
           let inner = (line["data"] as? [String: Any])?["message"] as? [String: Any], inner["message"] is [String: Any] {
            entry = inner
            if entry["type"] == nil { entry["type"] = "assistant" }
        }
        // 只留下父链最近 user/tool_result 的时刻，不缓存正文。
        let parentStart = (entry["parentUuid"] as? String).flatMap { state.ancestors?[$0] }
        let entryAt = timestamp(entry["timestamp"])
        let recentEntry = entryAt.map { $0 >= performanceCutoff - 600 } ?? false
        let start = recentEntry ? (entry["type"] as? String == "user" ? entryAt : parentStart) : nil
        if let uuid = entry["uuid"] as? String, let start {
            if state.ancestors == nil { state.ancestors = [:] }
            state.ancestors![uuid] = start
            if state.ancestors!.count > 512 {
                let keep = state.ancestors!.sorted { $0.value > $1.value }.prefix(256)
                state.ancestors = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                state.ancestors![uuid] = start
            }
        }
        guard entry["type"] as? String == "assistant", let msg = entry["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return }
        if entry["isApiErrorMessage"] as? Bool == true { return }
        let model = msg["model"] as? String ?? "?"
        guard !model.contains("synthetic") else { return }
        guard let ts = timestamp(entry["timestamp"]),
              let id = (entry["requestId"] as? String) ?? (msg["id"] as? String) ?? (entry["uuid"] as? String), !id.isEmpty,
              let input = number(usage["input_tokens"]), let output = number(usage["output_tokens"]) else { state.skipped += 1; return }
        let read = number(usage["cache_read_input_tokens"]) ?? 0
        let write = number(usage["cache_creation_input_tokens"]) ?? 0
        let w1h = min(write, number((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0)
        let think = number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0
        let tier = (usage["speed"] as? String)?.lowercased() == "fast" ? "fast" : nil
        var record = Record(id: id, source: state.source, timestamp: ts, model: model.isEmpty ? "?" : model,
                            usage: ModelTotals(ctx: input + read + write, cacheRead: read, cacheWrite: write, out: output, think: think),
                            cw1h: w1h > 0 ? w1h : nil, tier: tier)
        if recentEntry, let start = parentStart, ts - start >= 1, ts - start <= 600 {
            record.timing = PerformanceTiming(seconds: ts - start)
        }
        if let old = state.records[id] {
            // 用量仍取最大块，T1 则取同一 requestId 最后一行。
            if old.timestamp > record.timestamp {
                if !Self.prefer(record, over: old) { return }
                if let seconds = old.timing?.seconds { record.timing = PerformanceTiming(seconds: seconds) }
                record.timestamp = old.timestamp
            } else {
                if old.timestamp == record.timestamp, record.timing == nil { record.timing = old.timing }
                if old.usage.tokenTotal > record.usage.tokenTotal {
                    record.usage = old.usage; record.cw1h = old.cw1h; record.tier = old.tier
                }
            }
        }
        store(record, in: &state)
    }

    private func consumeCodex(_ j: [String: Any], offset: UInt64, state: inout FileState) {
        guard let payload = j["payload"] as? [String: Any] else { return }
        observeTurnMetadata(j, state: &state)
        let type = j["type"] as? String ?? ""
        let eventType = payload["type"] as? String ?? ""
        let eventAt = timestamp(j["timestamp"])
        let previousEventAt = state.previousEventAt
        if ["function_call_output", "user_message", "token_count"].contains(eventType), let eventAt {
            state.previousEventAt = eventAt
        }
        switch type {
        case "session_meta":
            if let id = payload["creator_account_id"] as? String {
                state.account = AccountIdentity(provider: payload["model_provider"] as? String ?? "openai", accountID: id)
            }
            if let fork = payload["forked_from_id"] as? String, !fork.isEmpty { state.forked = true }
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
        case "token_usage_record":
            guard let fields = Self.tokenFields(payload["usage"]), let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            if state.hasUsageRecords != true {
                // 这个文件有逐请求记录：此前从 token_count 推出来的记录作废，避免两套口径叠加
                state.hasUsageRecords = true
                state.records = state.records.filter { $0.key.hasPrefix("resp") }
            }
            let usage = Self.codexLastTokenUsage(fields)
            guard usage.tokenTotal > 0 else { return }
            let id = (payload["response_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "resp-off-\(offset)"
            state.latestResponseID = id
            var record = Record(id: id, source: state.source, timestamp: ts, model: state.model, usage: usage,
                                session: nil, tier: state.tier)
            if let old = state.records[id], old.timestamp == ts, old.usage == usage,
               old.model == record.model, old.tier == record.tier { record.timing = old.timing }
            store(record, in: &state)
        case "event_msg":
            let ptype = payload["type"] as? String ?? ""
            if ["task_complete", "turn_complete"].contains(ptype) {
                if let sample = turnLatency(j, state: state) {
                    state.turnLatencies = Self.mergedTurnLatencies((state.turnLatencies ?? []) + [sample], now: Date().timeIntervalSince1970)
                }
                return
            }
            if ptype == "thread_settings_applied" {
                if let tier = (payload["thread_settings"] as? [String: Any])?["service_tier"] as? String { state.tier = tier.lowercased() }
                return
            }
            guard ptype == "token_count", let info = payload["info"] as? [String: Any] else { return }
            guard let parsed = Self.codexUsage(info: info, previous: &state.previousTotal) else { return }
            guard let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            if state.hasUsageRecords == true {
                // 新版先记精确用量，再写 token_count；把本轮计时附回同一请求，避免双计。
                defer { state.latestResponseID = nil }
                if ts >= performanceCutoff, let start = previousEventAt, let fields = Self.tokenFields(info["last_token_usage"]),
                   PerformanceTiming.estimated(output: fields["output_tokens"] ?? 0, seconds: ts - start) != nil,
                   let responseID = state.latestResponseID, let record = state.records[responseID],
                   record.timestamp <= ts, record.usage.out == fields["output_tokens"], record.usage.ctx == fields["input_tokens"] {
                    state.records[record.id]?.timing = PerformanceTiming(seconds: ts - start)
                }
                return
            }
            let id = String(offset)
            // 旧版 fork 会把父会话的用量按同一秒重放一遍：开头连续 1 秒内的一串只当基线
            if state.forked == true, state.burstDone != true {
                if let last = state.burstLast {
                    if ts - last <= 1.0 {
                        if let first = state.burstFirstId { state.records[first] = nil; state.burstFirstId = nil; state.replayed = (state.replayed ?? 0) + 1 }
                        state.burstLast = ts
                        state.replayed = (state.replayed ?? 0) + 1
                        return
                    }
                    state.burstDone = true
                } else {
                    state.burstLast = ts
                    state.burstFirstId = id
                }
            }
            let model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.model
            store(Record(id: id, source: state.source, timestamp: ts, model: model, usage: parsed.usage,
                         cumulative: parsed.cumulative, tier: state.tier,
                         timing: previousEventAt.flatMap { start in
                             let seconds = ts - start
                             guard let last = Self.tokenFields(info["last_token_usage"]),
                                   PerformanceTiming.estimated(output: last["output_tokens"] ?? 0, seconds: seconds) != nil else { return nil }
                             return PerformanceTiming(seconds: seconds)
                         }), in: &state)
        default:
            return
        }
    }

    private func consumeAPI(_ j: [String: Any], offset: UInt64, state: inout FileState) {
        guard let ts = timestamp(j["epoch"]) ?? timestamp(j["ts"]), let host = j["host"] as? String,
              let ctx = number(j["ctx"]), let out = number(j["out"]) else { state.skipped += 1; return }
        let provider = (j["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        let model = (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let id = String(offset)
        store(Record(id: id, source: "API · " + provider, timestamp: ts, model: model,
                     usage: ModelTotals(ctx: ctx, cacheRead: number(j["cache_read"]) ?? 0,
                                        cacheWrite: number(j["cache_write"]) ?? 0, out: out, think: number(j["think"]) ?? 0),
                     timing: PerformanceTiming.proxy(ms: (j["ms"] as? NSNumber)?.doubleValue,
                                                     ttft: (j["ttft_ms"] as? NSNumber)?.doubleValue,
                                                     status: (j["status"] as? NSNumber)?.intValue)), in: &state)
    }

    static func tokenFields(_ raw: Any?) -> [String: Int64]? {
        guard let fields = raw as? [String: Any], fields["input_tokens"] is NSNumber, fields["output_tokens"] is NSNumber else { return nil }
        var result: [String: Int64] = [:]
        for key in tokenKeys {
            let n = (fields[key] as? NSNumber)?.int64Value ?? 0
            guard n >= 0 else { return nil }
            result[key] = n
        }
        // 缓存读不会超过输入、缓存写不会超过剩下的新鲜输入（ccusage 同样夹紧）
        let input = result["input_tokens"] ?? 0
        result["cached_input_tokens"] = min(result["cached_input_tokens"] ?? 0, input)
        result["cache_write_input_tokens"] = min(result["cache_write_input_tokens"] ?? 0, input - (result["cached_input_tokens"] ?? 0))
        return result
    }
    private func number(_ raw: Any?) -> Int64? {
        guard let n = raw as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.int64Value
    }
    private func timestamp(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue > 0 && n.doubleValue.isFinite ? n.doubleValue : nil }
        guard var text = raw as? String else { return nil }
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: text[range].prefix(4)) }
        return (iso.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970
    }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: cachePath) else { cache.parser = Self.parserVersion; return }
        do {
            let url = URL(fileURLWithPath: cachePath)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoded: DiskCache
            if data.starts(with: Data("bplist".utf8)) {
                if let packed = try? PropertyListDecoder().decode(CompressedCache.self, from: data) {
                    guard packed.version == 4, packed.compression == "lzfse" else { throw CocoaError(.fileReadCorruptFile) }
                    let payload = try (packed.archive as NSData).decompressed(using: .lzfse) as Data
                    decoded = try PropertyListDecoder().decode(DiskCache.self, from: payload)
                } else { decoded = try PropertyListDecoder().decode(DiskCache.self, from: data) }
            } else { decoded = try JSONDecoder().decode(DiskCache.self, from: data) }
            guard [3, 4].contains(decoded.version) else { errors.insert("历史缓存版本变化，已重新汇总"); return }
            cache = decoded
            if decoded.version == 3 {
                do {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("usage-daily.v3.bak.json")
                    if FileManager.default.fileExists(atPath: backup.path) {
                        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
                        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                    } else {
                        try FileManager.default.copyItem(at: url, to: backup)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    }
                    cache.version = 4
                    migrationPending = true
                    dirty = true
                } catch {
                    freezingEnabled = false
                    migrationError = "历史缓存备份失败，继续使用 v3 缓存"
                    errors.insert(migrationError!)
                }
            }
            rebuildFrozenIDs()
            for (path, state) in cache.files { indexTimings(path, state) }
            trimTimings(now: Date().timeIntervalSince1970)
        } catch { errors.insert("历史缓存无法读取，已重新汇总") }
        if (cache.parser ?? 1) < Self.parserVersion {
            // 新口径：仍在磁盘上的 Claude / Codex 日志重解析一次；已被清理的日志保留旧账
            let fm = FileManager.default
            for (path, state) in cache.files where [.claude, .codex].contains(Self.kind(of: state.source)) && fm.fileExists(atPath: path) {
                cache.files[path] = nil
            }
            cache.parser = Self.parserVersion
            dirty = true
            savedAt = 0
        }
    }
    @discardableResult private func saveCache() -> Bool {
        guard dirty else { return true }
        do {
            let url = URL(fileURLWithPath: cachePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            let data: Data
            if cache.version == 3 {
                let encoder = JSONEncoder()
                encoder.userInfo[Self.legacyCacheEncoding] = true
                data = try encoder.encode(cache)
            }
            else {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let payload = try encoder.encode(cache)
                let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
                data = try encoder.encode(CompressedCache(archive: compressed))
            }
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath)
            return true
        } catch { errors.insert("历史缓存保存失败，重启后需重新汇总"); return false }
    }
    private func readJSON(_ path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return json
        } catch { errors.insert("价目表无法读取，未计入成本"); return nil }
    }
    private func publishProgress(_ processed: Int, total: Int) {
        lock.lock()
        cached.isScanning = true; cached.processedFiles = processed; cached.totalFiles = total
        lock.unlock()
    }

    // MARK: - Frozen accounting and incremental per-file summaries

    private func store(_ value: Record, in state: inout FileState) {
        guard value.timestamp >= (state.frozenBefore ?? 0) else { return }
        var record = value
        if record.account == nil, Self.kind(of: record.source) == .codex { record.account = state.account }
        if record.timestamp < performanceCutoff { record.timing?.seconds = nil; record.timing?.ttftMS = nil }
        if record.timing?.speed(output: record.usage.out, proxy: Self.isProxySource(record.source)) == nil { record.timing?.seconds = nil }
        if record.timing?.seconds == nil && record.timing?.ttftMS == nil && record.timing?.status == nil { record.timing = nil }
        if state.records[record.id] != record { state.records[record.id] = record }
    }

    private func updateFile(_ path: String, _ state: FileState) {
        let old = cache.files[path]
        guard old != state else { return }
        if old?.records != state.records || old?.frozen != state.frozen || old?.frozenSessions != state.frozenSessions {
            summaryDirty.insert(path)
            nextFreezeAt[path] = nil
        }
        if old?.records != state.records { indexTimings(path, state) }
        // Metadata changes (offset, cursor, replay diagnostics) must also be persisted.
        // Callers only call this after a read or a collector result.
        cache.files[path] = state
        dirty = true
    }

    private func indexTimings(_ path: String, _ state: FileState) {
        timingIndex[path] = state.records.values.compactMap { record in
            guard record.timing?.seconds != nil || record.timing?.ttftMS != nil else { return nil }
            return TimingRef(id: record.id, source: record.source, model: record.model, timestamp: record.timestamp)
        }
    }

    /// 只裁剪可观测性附加字段，不碰账目、HTTP 状态码、读取游标和旧缓存版本。
    private func trimTimings(now: TimeInterval) {
        for path in cache.files.keys {
            guard var state = cache.files[path], let samples = state.turnLatencies else { continue }
            let trimmed = Self.mergedTurnLatencies(samples, now: now)
            if trimmed != samples { state.turnLatencies = trimmed; updateFile(path, state) }
        }
        var counts: [String: Int] = [:]
        var removals: [String: Set<String>] = [:]
        let refs = timingIndex.flatMap { path, refs in refs.map { (path: path, ref: $0) } }
            .sorted { $0.ref.timestamp > $1.ref.timestamp }
        for (path, ref) in refs {
            let key = ref.source + "|" + ref.model
            counts[key, default: 0] += 1
            if ref.timestamp < now - 86400 || counts[key]! > 500 { removals[path, default: []].insert(ref.id) }
        }
        for (path, ids) in removals {
            guard var state = cache.files[path] else { continue }
            for id in ids {
                state.records[id]?.timing?.seconds = nil
                state.records[id]?.timing?.ttftMS = nil
                if state.records[id]?.timing?.status == nil { state.records[id]?.timing = nil }
            }
            timingIndex[path]?.removeAll { ids.contains($0.id) }
            cache.files[path] = state
            summaryDirty.insert(path); dirty = true
        }
    }

    private func rebuildFrozenIDs() {
        frozenClaudeIDs = [:]
        for state in cache.files.values where Self.kind(of: state.source) == .claude {
            frozenClaudeIDs[state.source, default: []].formUnion(state.frozenClaudeIDs ?? [])
        }
    }

    private func pricing() -> CostEngine {
        let path = "\(home)/.config/vibedeck/prices.json"
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        let zone = TimeZone.current.identifier
        if !summaryPricesLoaded || data != priceData || zone != summaryTimeZone {
            fileSummaries.removeAll()
            pricingWarnings.removeAll()
            priceData = data
            summaryTimeZone = zone
            summaryPricesLoaded = true
        }
        let user = readJSON(path).map { ProcessScanner.PriceTable(json: $0) } ?? ProcessScanner.PriceTable()
        return CostEngine(user: user, catalog: catalogOverride ?? PricingCatalog.builtin)
    }

    private static func peakDefinition(_ user: ProcessScanner.PriceTable) -> String {
        let p = user.peak
        return p.timeZone.identifier + "|" + p.windows.map { "\($0.start)-\($0.end)" }.joined(separator: ",")
            + "|" + p.weekdays.sorted().map(String.init).joined(separator: ",") + "|" + p.excludedDates.sorted().joined(separator: ",")
    }

    private struct FrozenKey: Hashable {
        var source: String
        var model: String
        var tier: String?
        var timestamp: TimeInterval
        var peak: Bool
        var longContext: Bool
        var account: AccountIdentity?
        var exactRequestID: String?
        var billedCurrency: String? = nil
    }

    private func claudeWinners() -> [String: [String: (path: String, record: Record)]] {
        var winners: [String: [String: (path: String, record: Record)]] = [:]
        // Same order and strict preference as deduplicateClaude, including ties.
        for path in cache.files.keys.sorted() {
            guard let state = cache.files[path], Self.kind(of: state.source) == .claude else { continue }
            for record in state.records.values {
                if frozenClaudeIDs[state.source]?.contains(record.id) == true { continue }
                if let old = winners[state.source]?[record.id], !Self.prefer(record, over: old.record) { continue }
                winners[state.source, default: [:]][record.id] = (path, record)
            }
        }
        return winners
    }

    private func freezeOldRecords(now: TimeInterval) {
        guard freezingEnabled else { return }
        let boundary = now - Self.rawWindow
        let horizon = now - Self.forecastWindow
        let candidates = cache.files.keys.filter { path in
            if nextFreezeAt[path] == nil {
                let state = cache.files[path]!
                let raw = state.records.values.map { $0.timestamp + Self.rawWindow }.min() ?? .infinity
                let precise = (state.frozen ?? []).lazy.filter { $0.exactRequestID == nil && $0.timestamp != Self.hourStart($0.timestamp) }
                    .map { $0.timestamp + Self.forecastWindow }.min() ?? .infinity
                nextFreezeAt[path] = min(raw, precise)
            }
            return now > (nextFreezeAt[path] ?? .infinity)
        }
        guard !candidates.isEmpty else { return }
        let engine = pricing()
        let peakDefinition = Self.peakDefinition(engine.user)
        let winners = candidates.contains { Self.kind(of: cache.files[$0]!.source) == .claude } ? claudeWinners() : [:]
        var dayKeys = DayKeyCache()
        for path in candidates {
            var state = cache.files[path]!
            var buckets: [FrozenKey: FrozenBucket] = [:]
            func add(_ bucket: FrozenBucket) {
                var b = bucket
                if b.timestamp < horizon && b.exactRequestID == nil { b.timestamp = Self.hourStart(b.timestamp) }
                let key = FrozenKey(source: b.source, model: b.model, tier: b.tier, timestamp: b.timestamp, peak: b.peak, longContext: b.longContext, account: b.account, exactRequestID: b.exactRequestID, billedCurrency: b.billed?.currency)
                if var old = buckets[key] {
                    old.usage.add(b.usage); old.fresh += b.fresh; old.cw1h += b.cw1h
                    if let cost = b.billed { old.billed = BilledCost(value: (old.billed?.value ?? 0) + cost.value, currency: cost.currency) }
                    old.turns += b.turns; old.cumulative += b.cumulative
                    old.minContext = min(old.minContext, b.minContext); old.maxContext = max(old.maxContext, b.maxContext)
                    buckets[key] = old
                } else { buckets[key] = b }
            }
            for bucket in state.frozen ?? [] { add(bucket) }
            let localClaude = Self.kind(of: state.source) == .claude
            let oldRecords = state.records.values.filter { $0.timestamp < boundary }
            for record in oldRecords {
                let day = dayKeys.key(record.timestamp)
                if state.frozenSessions == nil { state.frozenSessions = [:] }
                state.frozenSessions![day, default: [:]][record.source, default: []].insert(record.session ?? path)
                state.frozenRecordCount = (state.frozenRecordCount ?? 0) + 1
                state.records[record.id] = nil
                if localClaude {
                    if frozenClaudeIDs[state.source]?.contains(record.id) == true || winners[state.source]?[record.id]?.path != path { continue }
                    if state.frozenClaudeIDs == nil { state.frozenClaudeIDs = [] }
                    state.frozenClaudeIDs!.insert(record.id)
                }
                let u = record.usage
                let entry = PricingCatalog.entry(for: record.model, in: engine.catalog)
                add(FrozenBucket(source: record.source, model: record.model, tier: record.tier,
                                 timestamp: record.timestamp, peak: engine.user.peak.isPeak(Date(timeIntervalSince1970: record.timestamp)),
                                 longContext: entry?.long != nil && (entry?.longThreshold ?? 0) > 0 && u.ctx > (entry?.longThreshold ?? 0),
                                 usage: u, fresh: max(0, u.ctx - u.cacheRead - u.cacheWrite),
                                 cw1h: max(0, min(record.cw1h ?? 0, u.cacheWrite)), turns: 1,
                                 cumulative: record.cumulative ? 1 : 0, minContext: u.ctx, maxContext: u.ctx, account: record.account,
                                 exactRequestID: record.account == nil ? nil : AccountUsage.exactRequestID(record.id, source: record.source),
                                 billed: record.billed))
            }
            state.frozen = Array(buckets.values)
            if !oldRecords.isEmpty { state.frozenBefore = max(state.frozenBefore ?? 0, boundary) }
            if state.frozenPeakDefinition == nil { state.frozenPeakDefinition = peakDefinition }
            updateFile(path, state)
        }
        rebuildFrozenIDs()
    }

    private static func hourStart(_ timestamp: TimeInterval) -> TimeInterval {
        Calendar.current.dateInterval(of: .hour, for: Date(timeIntervalSince1970: timestamp))?.start.timeIntervalSince1970 ?? floor(timestamp / 3600) * 3600
    }

    private func frozenCost(_ bucket: FrozenBucket, engine: CostEngine) -> (value: Double, currency: String)? {
        if let billed = bucket.billed { return (billed.value, billed.currency) }
        let u = bucket.usage
        if CostEngine.isSubscriptionIncluded(bucket.model) { return (0, "USD") }
        if var row = engine.user.row(for: bucket.model) {
            if !bucket.peak, let offpeak = row.offpeak { row.peak = offpeak }
            row.offpeak = nil
            var user = engine.user
            user.rows = [bucket.model.lowercased(): row]
            // Sum fresh input per request: clamping after summing is not equivalent for malformed old records.
            let ctx = bucket.fresh + u.cacheRead + u.cacheWrite
            return (user.cost(model: bucket.model, ctx: ctx, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite,
                              out: u.out, tier: bucket.tier) ?? 0, engine.user.currency(for: bucket.model))
        }
        guard var entry = PricingCatalog.entry(for: bucket.model, in: engine.catalog) else { return nil }
        let threshold = entry.longThreshold
        var long = bucket.longContext
        if entry.long == nil || threshold <= 0 { long = false }
        else if bucket.maxContext <= threshold { long = false }
        else if bucket.minContext > threshold { long = true }
        else { pricingWarnings.insert("冻结历史的长上下文门槛已变化，部分旧记录无法重新分档") }
        // Keep base rates for priority's ratio calculation; force the selected context band without applying the threshold to a sum.
        entry.longThreshold = long ? 1 : Int64.max
        let ctx = bucket.fresh + u.cacheRead + u.cacheWrite
        return (PricingCatalog.cost(entry, ctx: ctx, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite,
                                    cacheWrite1h: bucket.cw1h, out: u.out, tier: bucket.tier), "USD")
    }

    private func frozenEquivalentCost(_ bucket: FrozenBucket, engine: CostEngine) -> (value: Double, currency: String)? {
        // Existing frozen pricing handles request bands/peak grouping. Subscription records need a distinct API valuation.
        if bucket.billed != nil || !CostEngine.isSubscriptionIncluded(bucket.model) { return frozenCost(bucket, engine: engine) }
        var b = bucket
        b.model = String(bucket.model.dropFirst("chatgpt-web/".count))
        var equivalent = engine
        if let exact = engine.user.row(for: bucket.model) { equivalent.user.rows[b.model.lowercased()] = exact }
        return frozenCost(b, engine: equivalent)
    }

    private struct CostPoint {
        var timestamp: TimeInterval
        var source: String
        var currency: String
        var value: Double
        var tokens: Int64
    }
    private struct FileSummary {
        var days: [String: [String: Totals]] = [:]
        var totals: [String: Totals] = [:]
        var sessions: [String: Set<String>] = [:]
        var dailySessions: [String: [String: Set<String>]] = [:]
        var cumulative = 0
        var costByCurrency: [String: Double] = [:]
        var costBySource: [String: [String: Double]] = [:]
        var costByModel: [String: [String: Double]] = [:]
        var hourly: [String: [String: [String: [Double]]]] = [:] // source → currency → day → 24 hours
        var points: [String: [CostPoint]] = [:]
        var performance: [PerformanceSample] = []
        var accountPoints: [AccountUsagePoint] = []
        var models: [String: [String: [String: PerformanceTotals]]] = [:]
    }

    private func summarizeFile(_ path: String, state: FileState, engine: CostEngine,
                               claudeWinners: [String: [String: (path: String, record: Record)]], now: TimeInterval) -> FileSummary {
        var f = FileSummary()
        var dayKeys = DayKeyCache()
        f.dailySessions = state.frozenSessions ?? [:]
        for sources in f.dailySessions.values {
            for (source, keys) in sources { f.sessions[source, default: []].formUnion(keys) }
        }
        func add(source: String, model: String, at: TimeInterval, usage: ModelTotals, turns: Int, cumulative: Int,
                 cost: (value: Double, currency: String)?) {
            let day = dayKeys.key(at)
            var totals = Totals(ctx: usage.ctx, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite,
                                out: usage.out, think: usage.think, turns: turns, models: [model: usage])
            totals.sessions = 0
            f.days[day, default: [:]][source, default: Totals()].merge(totals)
            f.totals[source, default: Totals()].merge(totals)
            f.cumulative += cumulative
            guard let c = cost else { return }
            f.costByCurrency[c.currency, default: 0] += c.value
            f.costBySource[source, default: [:]][c.currency, default: 0] += c.value
            f.costByModel[model, default: [:]][c.currency, default: 0] += c.value
            guard !Self.isProxySource(source) else { return }
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: at))
            if f.hourly[source]?[c.currency]?[day] == nil {
                f.hourly[source, default: [:]][c.currency, default: [:]][day] = Array(repeating: 0, count: 24)
            }
            f.hourly[source]?[c.currency]?[day]?[hour] += c.value
            if at >= now - Self.forecastWindow {
                f.points[day, default: []].append(CostPoint(timestamp: at, source: source, currency: c.currency, value: c.value, tokens: usage.tokenTotal))
            }
        }
        if let definition = state.frozenPeakDefinition, !(state.frozen ?? []).isEmpty, definition != Self.peakDefinition(engine.user) {
            pricingWarnings.insert("峰谷时间定义已变化，冻结历史沿用冻结时的峰谷分组")
        }
        for bucket in state.frozen ?? [] {
            add(source: bucket.source, model: bucket.model, at: bucket.timestamp, usage: bucket.usage, turns: bucket.turns,
                cumulative: bucket.cumulative, cost: frozenCost(bucket, engine: engine))
            let cost = frozenEquivalentCost(bucket, engine: engine)
            f.accountPoints.append(AccountUsagePoint(timestamp: bucket.timestamp, source: bucket.source, model: bucket.model,
                account: bucket.account, pool: AccountUsage.pool(model: bucket.model, source: bucket.source), usage: bucket.usage,
                requests: bucket.turns, equivalentCostByCurrency: cost.map { [$0.currency: $0.value] } ?? [:],
                unpricedRequests: cost == nil ? bucket.turns : 0, exactRequestID: bucket.exactRequestID,
                origin: Self.isProxySource(bucket.source) ? "proxy" : "cli", timestampResolution: bucket.exactRequestID == nil && bucket.timestamp < now - Self.forecastWindow ? 3600 : 0))
        }
        for record in state.records.values {
            let day = dayKeys.key(record.timestamp)
            let session = record.session ?? path
            f.sessions[record.source, default: []].insert(session)
            f.dailySessions[day, default: [:]][record.source, default: []].insert(session)
            if Self.kind(of: state.source) == .claude, claudeWinners[state.source]?[record.id]?.path != path { continue }
            let u = record.usage
            let equivalent = record.billed.map { (value: $0.value, currency: $0.currency) }
                ?? engine.equivalentCost(model: record.model, ctx: u.ctx, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite,
                cacheWrite1h: record.cw1h ?? 0, out: u.out, tier: record.tier, at: Date(timeIntervalSince1970: record.timestamp))
            f.accountPoints.append(AccountUsagePoint(timestamp: record.timestamp, source: record.source, model: record.model,
                account: record.account, pool: AccountUsage.pool(model: record.model, source: record.source), usage: u,
                requests: 1, equivalentCostByCurrency: equivalent.map { [$0.currency: $0.value] } ?? [:],
                unpricedRequests: equivalent == nil ? 1 : 0, exactRequestID: AccountUsage.exactRequestID(record.id, source: record.source),
                origin: Self.isProxySource(record.source) ? "proxy" : "cli"))
            let modelDay = dayKeys.key(record.timestamp)
            f.models[modelDay, default: [:]][record.source, default: [:]][record.model, default: PerformanceTotals()].add(record)
            if record.timestamp >= now - 86400 {
                f.performance.append(PerformanceSample(source: record.source, model: record.model, timestamp: record.timestamp,
                                                       context: u.ctx, output: u.out, cacheRead: u.cacheRead, timing: record.timing))
            }
            add(source: record.source, model: record.model, at: record.timestamp, usage: u, turns: 1,
                cumulative: record.cumulative ? 1 : 0,
                cost: record.billed.map { (value: $0.value, currency: $0.currency) } ?? engine.cost(model: record.model, ctx: u.ctx, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite,
                                  cacheWrite1h: record.cw1h ?? 0, out: u.out, tier: record.tier, at: Date(timeIntervalSince1970: record.timestamp)))
        }
        return f
    }

    // MARK: - 汇总

    private func summarize() -> Snapshot {
        var result = Snapshot()
        let engine = pricing()
        defer { errors.formUnion(pricingWarnings) }
        let now = Date()
        var dayKeys = DayKeyCache()
        let todayKey = dayKeys.key(now.timeIntervalSince1970)
        let horizon = now.timeIntervalSince1970 - Self.forecastWindow
        let horizonDay = dayKeys.key(horizon)
        let blockDay = dayKeys.key(now.timeIntervalSince1970 - 86400)
        var buckets: [String: [String: Totals]] = [:]
        var sessions: [String: Set<String>] = [:]
        var dailySessions: [String: [String: Set<String>]] = [:]
        var hourly: [String: [String: [Double]]] = [:]
        var lastHour: [String: Double] = [:]
        var deviceHourly: [String: [String: [String: [Double]]]] = [:]
        var deviceLastHour: [String: [String: Double]] = [:]
        var claudePoints: [UsageForecast.Point] = []
        let fm = FileManager.default
        var codexWinner: [String: String] = [:]
        for (path, state) in cache.files where Self.kind(of: state.source) == .codex {
            let key = state.source + "|" + (path as NSString).lastPathComponent
            if let other = codexWinner[key], let o = cache.files[other] {
                let mine = (fm.fileExists(atPath: path) ? 1 : 0, state.records.count + (state.frozenRecordCount ?? 0))
                let theirs = (fm.fileExists(atPath: other) ? 1 : 0, o.records.count + (o.frozenRecordCount ?? 0))
                if mine > theirs { codexWinner[key] = path }
            } else { codexWinner[key] = path }
        }
        let codexKeep = Set(codexWinner.values)
        if summaryDirty.contains(where: { cache.files[$0].map { Self.kind(of: $0.source) == .claude } ?? false }) {
            for (path, state) in cache.files where Self.kind(of: state.source) == .claude { fileSummaries[path] = nil }
        }
        let needsClaude = cache.files.contains { path, state in Self.kind(of: state.source) == .claude && fileSummaries[path] == nil }
        let winners = needsClaude ? claudeWinners() : [:]
        func addHourly(_ source: String, _ currency: String, _ day: String, _ hours: [Double]) {
            if hourly[currency]?[day] == nil { hourly[currency, default: [:]][day] = Array(repeating: 0, count: 24) }
            let device = Self.device(of: source).map { "remote:\($0)" } ?? "local"
            if deviceHourly[device]?[currency]?[day] == nil {
                deviceHourly[device, default: [:]][currency, default: [:]][day] = Array(repeating: 0, count: 24)
            }
            for hour in 0..<24 {
                hourly[currency]?[day]?[hour] += hours[hour]
                deviceHourly[device]?[currency]?[day]?[hour] += hours[hour]
            }
            if day == todayKey { result.todayCostBySource[source, default: [:]][currency, default: 0] += hours.reduce(0, +) }
        }
        for (path, state) in cache.files {
            if Self.kind(of: state.source) == .codex, !codexKeep.contains(path) { continue }
            result.skippedRecords += state.skipped
            if state.hasUsageRecords != true { result.replayedTurns += state.replayed ?? 0 }
            if summaryDirty.contains(path) { fileSummaries[path] = nil }
            if fileSummaries[path] == nil { fileSummaries[path] = summarizeFile(path, state: state, engine: engine, claudeWinners: winners, now: now.timeIntervalSince1970) }
            let f = fileSummaries[path]!
            result.accountUsage.points.append(contentsOf: f.accountPoints)
            result.turnLatencies.append(contentsOf: state.turnLatencies ?? [])
            result.performance.append(contentsOf: f.performance.filter { $0.timestamp >= now.timeIntervalSince1970 - 86400 && $0.timestamp <= now.timeIntervalSince1970 })
            for sample in f.performance where sample.timestamp <= now.timeIntervalSince1970 {
                if sample.timestamp >= now.timeIntervalSince1970 - 3600 {
                    result.recentBySource[sample.source, default: RecentUsage()].tokensLastHour += sample.context + sample.output
                    result.recentBySource[sample.source, default: RecentUsage()].contextLastHour += sample.context
                    result.recentBySource[sample.source, default: RecentUsage()].requestsLastHour += 1
                }
                if sample.timestamp >= now.timeIntervalSince1970 - 900 { result.recentBySource[sample.source, default: RecentUsage()].requestsLast15m += 1 }
            }
            for (source, models) in f.models[todayKey] ?? [:] {
                for (model, totals) in models { result.todayModels[source, default: [:]][model, default: PerformanceTotals()].merge(totals) }
            }
            result.cumulativeTurns += f.cumulative
            for (day, sources) in f.days {
                for (source, totals) in sources { buckets[day, default: [:]][source, default: Totals()].merge(totals) }
            }
            for (source, totals) in f.totals { result.totals[source, default: Totals()].merge(totals) }
            for (source, keys) in f.sessions { sessions[source, default: []].formUnion(keys) }
            for (day, sources) in f.dailySessions {
                for (source, keys) in sources { dailySessions[day, default: [:]][source, default: []].formUnion(keys) }
            }
            for (currency, value) in f.costByCurrency { result.costByCurrency[currency, default: 0] += value }
            for (source, costs) in f.costBySource {
                for (currency, value) in costs { result.costBySource[source, default: [:]][currency, default: 0] += value }
            }
            for (model, costs) in f.costByModel {
                for (currency, value) in costs { result.costByModel[model, default: [:]][currency, default: 0] += value }
            }
            for (source, currencies) in f.hourly {
                for (currency, days) in currencies {
                    for (day, hours) in days where day > horizonDay { addHourly(source, currency, day, hours) }
                }
            }
            // Only the oldest partial day and the live 24-hour window need exact timestamps.
            var edge: [String: [String: [Double]]] = [:]
            for p in f.points[horizonDay] ?? [] where p.timestamp >= horizon {
                if edge[p.source]?[p.currency] == nil { edge[p.source, default: [:]][p.currency] = Array(repeating: 0, count: 24) }
                let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: p.timestamp))
                edge[p.source]?[p.currency]?[hour] += p.value
            }
            for (source, currencies) in edge { for (currency, hours) in currencies { addHourly(source, currency, horizonDay, hours) } }
            for (day, points) in f.points where day >= blockDay {
                for p in points {
                    let device = Self.device(of: p.source).map { "remote:\($0)" } ?? "local"
                    if p.timestamp >= now.timeIntervalSince1970 - 3600 {
                        lastHour[p.currency, default: 0] += p.value
                        deviceLastHour[device, default: [:]][p.currency, default: 0] += p.value
                    }
                    if p.source == "Claude", p.currency == "USD", p.timestamp >= now.timeIntervalSince1970 - 86400 {
                        claudePoints.append(.init(timestamp: p.timestamp, cost: p.value, tokens: p.tokens))
                    }
                }
            }
        }
        // 每个来源/模型只发布最近 500 个数字样本，刷新仍由原有历史扫描驱动。
        var sampleCounts: [String: Int] = [:]
        result.performance = result.performance.filter { $0.speed != nil || $0.timing?.ttftMS != nil }.sorted { $0.timestamp > $1.timestamp }.filter { sample in
            let key = sample.source + "|" + sample.model
            sampleCounts[key, default: 0] += 1
            return sampleCounts[key]! <= 500
        }
        result.accountUsage = AccountUsageSnapshot.aggregate(points: result.accountUsage.points, now: now, calendar: .current)
        for group in result.accountUsage.groups {
            guard let account = group.account else { continue }
            let markers = (cache.accountCoverage ?? [:]).values.filter { $0.accountKey == account.key }
            let requiredSources = Set(group.bySource.keys)
            let valid = markers.filter { marker in
                guard now.timeIntervalSince1970 - marker.lastSuccess <= 600 else { return false }
                if let host = Self.device(of: marker.source), remoteCLIStatus[host] != nil { return false }
                if Self.device(of: marker.source) == nil && !errors.isEmpty { return false }
                return true
            }
            guard requiredSources.isSubset(of: Set(valid.map { $0.source })), !valid.isEmpty else { continue }
            result.accountUsage.coverageStartByAccount[account.key] = valid.map { $0.startedAt }.max()
        }
        result.turnLatencies = Self.mergedTurnLatencies(result.turnLatencies, now: now.timeIntervalSince1970)
        summaryDirty.removeAll()
        for source in result.totals.keys { result.totals[source]?.sessions = sessions[source]?.count ?? 0 }
        for day in buckets.keys {
            for source in buckets[day]!.keys { buckets[day]?[source]?.sessions = dailySessions[day]?[source]?.count ?? 0 }
        }
        result.days = buckets.keys.sorted().map { Day(date: $0, sources: buckets[$0]!) }
        result.earliestDate = result.days.first?.date
        result.todayBySource = buckets[todayKey] ?? [:]
        result.dailyTokens = Dictionary(uniqueKeysWithValues: result.days.map { day in
            (day.date, day.sources.filter { !Self.isProxySource($0.key) }.values.reduce(0) { $0 + $1.tokenTotal })
        })
        result.activeDays = result.dailyTokens.values.filter { $0 > 0 }.count
        for (source, totals) in result.totals where !Self.isProxySource(source) { result.aggregate.merge(totals) }
        result.hasPriceTable = !engine.user.isEmpty
        result.priceCurrency = engine.user.currency
        result.builtinPriceAsOf = engine.catalog.isEmpty ? "" : engine.catalog.asOf
        let priced: [String: Bool] = [:]
        let cliCost = result.costBySource.filter { !Self.isProxySource($0.key) }
            .values.reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        result.primaryCurrency = cliCost.max { $0.value < $1.value }?.key ?? "USD"
        for (currency, days) in hourly {
            result.forecasts[currency] = UsageForecast.compute(hourly: days, lastHourCost: lastHour[currency] ?? 0, currency: currency, now: now)
        }
        for (device, currencies) in deviceHourly {
            for (currency, days) in currencies {
                result.dailyCostByDevice[device, default: [:]][currency] = days.mapValues { $0.reduce(0, +) }
                result.forecastsByDevice[device, default: [:]][currency] = UsageForecast.compute(
                    hourly: days, lastHourCost: deviceLastHour[device]?[currency] ?? 0, currency: currency, now: now)
            }
        }
        for (day, hours) in hourly[result.primaryCurrency] ?? [:] { result.dailyCost[day] = hours.reduce(0, +) }
        if !claudePoints.isEmpty {
            result.claudeBlock = UsageForecast.currentBlock(claudePoints.sorted { $0.timestamp < $1.timestamp }, currency: "USD",
                                                            now: now.timeIntervalSince1970)
        }
        // 未定价只按「模型」计一次，别按请求数刷屏。
        var unpricedNames = Set<String>()
        for (source, totals) in result.totals {
            for (model, _) in totals.models where !(priced[model] ?? engine.isPriced(model)) {
                result.unpricedModels += 1
                result.unpricedBySource[source, default: 0] += 1
                unpricedNames.insert(model)
                result.unpricedNamesBySource[source, default: []].append(model)
            }
        }
        result.unpricedNames = unpricedNames.sorted()
        for key in result.unpricedNamesBySource.keys { result.unpricedNamesBySource[key]?.sort() }
        return result
    }
}

public extension Fmt {
    /// 单币种金额："CNY 12.34" / "USD 5.67"；不足一分钱显示 "<0.01"；≥ 1 万用千分位。
    static func money(_ value: Double, _ currency: String) -> String {
        let symbol = currency.isEmpty ? "" : currency.uppercased() + " "
        if value < 0.01 && value > 0 { return "\(symbol)<0.01" }
        if value >= 10_000 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return symbol + (f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value))
        }
        return String(format: "%@%.2f", symbol, value)
    }

    /// 原币金额并列显示；可选参考换汇由 MoneyDisplay 处理，不改变这里的账目。
    static func money(_ byCurrency: [String: Double]) -> String {
        let parts = byCurrency.keys.sorted().compactMap { key in byCurrency[key].map { money($0, key) } }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    static func tokens(_ count: Int64) -> String {
        if count >= 100_000_000 { return String(format: "%.2f 亿", Double(count) / 100_000_000) }
        if count >= 10_000 { return String(format: "%.1f 万", Double(count) / 10_000) }
        return String(count)
    }
}
