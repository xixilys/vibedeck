import Foundation

/// 金额预测：只用本机已有的历史，纯函数，便于自测。
///
/// 今日：两种估计按「典型一天已经过去多少」加权 ——
///   · 比例法：今天已花 ÷ 历史同一时刻平均已完成的比例（下午以后很准，早上会放大噪声）
///   · 余量法：今天已花 + 历史同一时刻之后平均还会花多少 × 今天的活跃系数（早上更稳）
/// 本月：至少 7 个过去记录日时，已花 + 今天余量 + 剩余天数 × 近 14 天指数加权日均。
/// 历史不足时只保留已发生费用与今天的短时估计，不推算整月。区间是历史波动范围，不是置信区间。
public struct CostForecast: Equatable {
    /// 表示预测依据的历史覆盖程度，不表示经过校准的概率置信度。
    public enum Confidence: Equatable {
        case insufficient
        case limited
        case established
    }
    public var currency = "USD"
    public var todaySoFar = 0.0
    public var todayProjected = 0.0
    public var todayLow = 0.0
    public var todayHigh = 0.0
    /// 近 60 分钟花了多少（= 当前每小时速度）
    public var lastHourCost = 0.0
    public var yesterday = 0.0
    public var weekSoFar = 0.0
    public var monthSoFar = 0.0
    public var monthProjected = 0.0
    public var monthLow = 0.0
    public var monthHigh = 0.0
    /// 近 14 天（含 0 花费日）指数加权日均
    public var dailyAverage = 0.0
    public var profileDays = 0
    /// 近 14 天中有 24 小时桶的过去记录日数；缺失日不计入历史覆盖。
    public var historyDays = 0
    public var todayConfidence: Confidence = .insufficient
    /// insufficient 时 monthProjected 仅含本月已花与今天余量，并非整月预测。
    public var monthConfidence: Confidence = .insufficient
    public var basis = ""
    /// 近 14 天逐日（最早 → 今天），给柱状图
    public var recentDays: [String] = []
    public var recentCosts: [Double] = []
    public var hasData: Bool { todaySoFar > 0 || monthSoFar > 0 || recentCosts.contains { $0 > 0 } }
}

/// Claude 5 小时计费块（ccusage blocks 口径）：首条请求取整点起算，5 小时内或间隔 < 5 小时的请求归同一块。
public struct BillingBlock: Equatable {
    public var start: TimeInterval = 0
    public var end: TimeInterval = 0
    public var lastActivity: TimeInterval = 0
    public var cost = 0.0
    public var currency = "USD"
    public var tokens: Int64 = 0
    public var requests = 0
    public var perHour = 0.0
    public var projected = 0.0
    public var isActive = false
}

public enum UsageForecast {
    /// 一条带成本的明细（已按币种拆开）。
    public struct Point {
        public var timestamp: TimeInterval
        public var cost: Double
        public var tokens: Int64 = 0
        public init(timestamp: TimeInterval, cost: Double, tokens: Int64 = 0) {
            self.timestamp = timestamp; self.cost = cost; self.tokens = tokens
        }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = Double(sorted.count - 1) * p
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// hourly: 日期键 → 24 格小时花费（本地时区）。now 决定「今天」和「此刻」。
    public static func compute(hourly: [String: [Double]], lastHourCost: Double, currency: String,
                               now: Date = Date(), calendar: Calendar = .current) -> CostForecast {
        var f = CostForecast()
        f.currency = currency
        f.lastHourCost = lastHourCost
        let today = calendar.startOfDay(for: now)
        func key(_ d: Date) -> String { UsageHistory.dayKey(timestamp: d.timeIntervalSince1970, timeZone: calendar.timeZone) }
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: today)! }
        // 小时桶按当地墙钟小时生成；DST 切换日不能用距零点的秒数当小时索引。
        let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
        let h = min(23, max(0, clock.hour ?? 0))
        let frac = Double((clock.minute ?? 0) * 60 + (clock.second ?? 0)) / 3600
        func before(_ hours: [Double]) -> Double {
            guard hours.count == 24 else { return 0 }
            return hours[0..<h].reduce(0, +) + hours[h] * frac
        }
        let todayHours = hourly[key(today)] ?? Array(repeating: 0, count: 24)
        f.todaySoFar = todayHours.reduce(0, +)
        f.yesterday = (hourly[key(day(1))] ?? []).reduce(0, +)

        // 近 14 天逐日 + 历史作息曲线（近 28 天有花费的日子）
        for back in stride(from: 13, through: 0, by: -1) {
            let k = key(day(back))
            f.recentDays.append(k)
            f.recentCosts.append((hourly[k] ?? []).reduce(0, +))
        }
        var totals: [Double] = [], soFar: [Double] = [], remain: [Double] = []
        for back in 1...28 {
            guard let hours = hourly[key(day(back))] else { continue }
            let total = hours.reduce(0, +)
            guard total > 0 else { continue }
            let c = before(hours)
            totals.append(total); soFar.append(c); remain.append(max(0, total - c))
        }
        f.profileDays = totals.count
        f.historyDays = (1...14).filter { hourly[key(day($0))]?.count == 24 }.count

        if totals.count >= 3 {
            f.todayConfidence = totals.count >= 7 ? .established : .limited
            let meanTotal = totals.reduce(0, +) / Double(totals.count)
            let fractions = zip(soFar, totals).map { $0 / $1 }
            let F = fractions.reduce(0, +) / Double(fractions.count)
            let typicalSoFar = soFar.reduce(0, +) / Double(soFar.count)
            var factor = 1.0
            if typicalSoFar > meanTotal * 0.05, f.todaySoFar > 0 { factor = min(3, max(0.3, f.todaySoFar / typicalSoFar)) }
            let meanRemain = remain.reduce(0, +) / Double(remain.count)
            let additive = f.todaySoFar + meanRemain * factor
            let ratio = F > 0.05 ? f.todaySoFar / F : additive
            let w = min(1, max(0, F))
            f.todayProjected = max(f.todaySoFar, w * ratio + (1 - w) * additive)
            let sortedRemain = remain.map { $0 * factor }.sorted()
            f.todayLow = min(f.todayProjected, f.todaySoFar + percentile(sortedRemain, 0.25))
            f.todayHigh = max(f.todayProjected, f.todaySoFar + percentile(sortedRemain, 0.75))
            f.basis = "按近 \(totals.count) 个活跃日的作息曲线"
        } else {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let hoursLeft = max(0, tomorrow.timeIntervalSince(now) / 3600)
            f.todayProjected = f.todaySoFar + lastHourCost * min(1, hoursLeft)
            f.todayLow = f.todaySoFar
            f.todayHigh = f.todaySoFar + lastHourCost * min(3, hoursLeft)
            f.basis = "历史不足 3 天，按近 1 小时速度"
        }

        // 本周（周一起）与本月
        var weekStart = today
        var iso = Calendar(identifier: .iso8601); iso.timeZone = calendar.timeZone
        if let ws = iso.dateInterval(of: .weekOfYear, for: now)?.start { weekStart = ws }
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = calendar.component(.day, from: now)
        var monthBeforeToday = 0.0
        var cursor = monthStart
        while cursor < today {
            monthBeforeToday += (hourly[key(cursor)] ?? []).reduce(0, +)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        cursor = weekStart
        while cursor <= today {
            f.weekSoFar += (hourly[key(cursor)] ?? []).reduce(0, +)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        f.monthSoFar = monthBeforeToday + f.todaySoFar

        // 日均：近 14 天（不含今天），从第一天有数据开始算，指数加权（半衰期约 7 天）
        let firstActive = (1...28).reversed().first { (hourly[key(day($0))] ?? []).reduce(0, +) > 0 }
        var series: [Double] = []
        if let first = firstActive {
            for back in stride(from: min(first, 14), through: 1, by: -1) { series.append((hourly[key(day(back))] ?? []).reduce(0, +)) }
        }
        if !series.isEmpty {
            var wsum = 0.0, vsum = 0.0
            for (i, v) in series.reversed().enumerated() { let w = pow(0.9, Double(i)); wsum += w; vsum += w * v }
            f.dailyAverage = vsum / wsum
        }
        if !series.isEmpty, f.historyDays >= 7 {
            f.monthConfidence = f.historyDays >= 14 ? .established : .limited
            let mean = series.reduce(0, +) / Double(series.count)
            let sd = sqrt(series.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, series.count - 1)))
            let remainingDays = Double(max(0, daysInMonth - dayOfMonth))
            let spread = 0.674 * sd * sqrt(remainingDays)
            f.monthProjected = monthBeforeToday + f.todayProjected + remainingDays * f.dailyAverage
            f.monthLow = monthBeforeToday + f.todayLow + max(0, remainingDays * f.dailyAverage - spread)
            f.monthHigh = monthBeforeToday + f.todayHigh + remainingDays * f.dailyAverage + spread
        } else {
            f.monthProjected = f.monthSoFar + (f.todayProjected - f.todaySoFar)
            f.monthLow = f.monthSoFar
            f.monthHigh = f.monthSoFar + (f.todayHigh - f.todaySoFar)
            f.basis += " · 本月历史不足 7 个记录日，暂不推算整月"
        }
        f.monthProjected = max(f.monthSoFar, f.monthProjected)
        f.monthLow = max(f.monthSoFar, min(f.monthProjected, f.monthLow))
        f.monthHigh = max(f.monthProjected, f.monthHigh)
        return f
    }

    /// 当前（或最近一个）5 小时计费块。points 需按时间升序。
    public static func currentBlock(_ points: [Point], currency: String, now: TimeInterval = Date().timeIntervalSince1970) -> BillingBlock? {
        let window = 5.0 * 3600
        var block: BillingBlock?
        for p in points {
            if var b = block, p.timestamp - b.start < window, p.timestamp - b.lastActivity < window {
                b.cost += p.cost; b.tokens += p.tokens; b.requests += 1; b.lastActivity = p.timestamp
                block = b
            } else {
                var b = BillingBlock()
                b.start = floor(p.timestamp / 3600) * 3600
                b.end = b.start + window
                b.lastActivity = p.timestamp
                b.cost = p.cost; b.tokens = p.tokens; b.requests = 1; b.currency = currency
                block = b
            }
        }
        guard var b = block else { return nil }
        b.isActive = now < b.end && now - b.lastActivity < window
        let firstInBlock = points.first { $0.timestamp >= b.start }?.timestamp ?? b.start
        let elapsedHours = max(1.0 / 6, (min(now, b.end) - firstInBlock) / 3600)
        b.perHour = b.cost / elapsedHours
        b.projected = b.isActive ? b.cost + b.perHour * max(0, (b.end - now) / 3600) : b.cost
        return b
    }
}
