import Foundation

/// 纯数字的响应计时；可选字段让已有历史缓存继续可读。
public struct PerformanceTiming: Codable, Equatable {
    public var seconds: Double? = nil
    public var ttftMS: Double? = nil
    public var status: Int? = nil
    static func estimated(output: Int64, seconds: Double) -> Double? {
        guard output >= 50, seconds.isFinite, seconds >= 1, seconds <= 600 else { return nil }
        return Double(output) / seconds
    }
    static func proxy(ms: Double?, ttft: Double?, status: Int?) -> PerformanceTiming {
        let valid = ttft.flatMap { value -> Double? in
            guard value.isFinite, value >= 0, let ms, ms.isFinite, value <= ms else { return nil }
            return value
        }
        return PerformanceTiming(seconds: valid.flatMap { first in ms.map { ($0 - first) / 1000 } }, ttftMS: valid, status: status)
    }
    func speed(output: Int64, proxy: Bool) -> Double? {
        guard let seconds else { return nil }
        if !proxy { return Self.estimated(output: output, seconds: seconds) }
        guard output >= 20, seconds.isFinite, seconds >= 0.5, (status ?? 200) < 400 else { return nil }
        return Double(output) / seconds
    }
}

public struct PerformanceSample: Equatable {
    public var source: String
    public var model: String
    public var timestamp: TimeInterval
    public var context: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var timing: PerformanceTiming?
    public var speed: Double? { timing?.speed(output: output, proxy: UsageHistory.isProxySource(source)) }
}

public struct PerformanceTotals: Equatable {
    public var requests = 0
    public var context: Int64 = 0
    public var cacheRead: Int64 = 0
    public var proxyRequests = 0
    public var errors = 0
    public var rateLimits = 0
    mutating func add(_ record: UsageHistory.Record) {
        requests += 1; context += record.usage.ctx; cacheRead += record.usage.cacheRead
        if let status = record.timing?.status {
            proxyRequests += 1
            if status >= 400 { errors += 1 }
            if status == 429 { rateLimits += 1 }
        }
    }
    mutating func merge(_ other: PerformanceTotals) {
        requests += other.requests; context += other.context; cacheRead += other.cacheRead
        proxyRequests += other.proxyRequests; errors += other.errors; rateLimits += other.rateLimits
    }
}

public enum PerformanceStats {
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return UsageForecast.percentile(sorted, p)
    }
    public static func speed(_ samples: [PerformanceSample], percentile p: Double = 0.5) -> Double? {
        percentile(samples.compactMap { $0.speed }, p)
    }
    public static func ttft(_ samples: [PerformanceSample], percentile p: Double = 0.5) -> Double? {
        percentile(samples.filter {
            UsageHistory.isProxySource($0.source) && ($0.timing?.status ?? 200) < 400
        }.compactMap { $0.timing?.ttftMS }, p)
    }
}

public struct RecentUsage: Equatable {
    public var contextLastHour: Int64 = 0
    public var requestsLastHour = 0
    public var tokensLastHour: Int64 = 0
    public var requestsLast15m = 0
}

public extension PerformanceStats {
    /// Codex turn-first-token timing; never combines proxy first-byte samples with this basis.
    /// Native first-token metric only. Claude first-response and opencode stream-start samples are
    /// approximations of a different thing and are pooled only when a caller asks for them explicitly.
    static func turnTTFT(_ samples: [TurnLatencySample], since: TimeInterval,
                         until: TimeInterval = Date().timeIntervalSince1970, percentile p: Double = 0.5,
                         includeApproximate: Bool = false) -> Double? {
        var unique: [String: TurnLatencySample] = [:]
        for sample in samples where sample.isSuccessfulSample && sample.timestamp >= since && sample.timestamp <= until
            && (includeApproximate || sample.isNativeFirstToken) {
            if let old = unique[sample.id], old.timestamp >= sample.timestamp { continue }
            unique[sample.id] = sample
        }
        return percentile(unique.values.map { $0.milliseconds }, p)
    }
}
