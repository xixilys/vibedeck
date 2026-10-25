import SwiftUI
import AppKit

/// Passing a cached reset time does not establish the new window's usage.
enum QuotaReadingState: Equatable {
    case current, old, reset, undated

    static func evaluate(_ window: QuotaWindow, now: TimeInterval) -> Self {
        if let reset = window.resetsAt, !reset.isFinite || reset > 253402300799 { return .undated }
        if window.isExpired(now: now) { return .reset }
        guard let captured = window.capturedAt, captured.isFinite, captured > 0 else { return .undated }
        return now - captured > 10 * 60 || captured > now + 60 ? .old : .current
    }
}

/// Presentation priority only: never combines percentages or infers account identity.
enum QuotaPresentation {
    static func windows(_ runtime: DetectedLLMRuntime) -> [QuotaWindow] {
        [runtime.fiveHour, runtime.sevenDay, runtime.secondaryFiveHour, runtime.secondarySevenDay].compactMap { $0 }
    }

    static func isRetained(_ runtime: DetectedLLMRuntime) -> Bool {
        runtime.quotaNote.contains("未取得新额度") || runtime.quotaNote.contains("Quota missing;")
    }

    static func connectionCurrent(_ status: RemoteDeviceStatus?, isRemote: Bool, now: TimeInterval) -> Bool {
        guard isRemote else { return true }
        guard let status, status.error.isEmpty, let success = status.lastSuccess else { return false }
        return now - success <= 600 && success <= now + 60
    }

    static func trusted(_ window: QuotaWindow, runtime: DetectedLLMRuntime, status: RemoteDeviceStatus?, isRemote: Bool, now: TimeInterval) -> Bool {
        QuotaReadingState.evaluate(window, now: now) == .current && !isRetained(runtime)
            && connectionCurrent(status, isRemote: isRemote, now: now)
    }

    static func displayable(_ window: QuotaWindow, now: TimeInterval) -> Bool {
        guard ringFraction(usedPct: window.usedPct) != nil else { return false }
        let state = QuotaReadingState.evaluate(window, now: now)
        return state == .current || state == .old
    }

    static func ringFraction(usedPct: Int) -> Double? {
        guard (0...100).contains(usedPct) else { return nil }
        return Double(usedPct) / 100
    }

    static func predictedDepletion(_ window: QuotaWindow, now: TimeInterval) -> Bool {
        guard QuotaReadingState.evaluate(window, now: now) == .current else { return false }
        return window.burn(now: now)?.exhaustAt != nil
    }

    /// Short units preserve both pool/window and reset time in the compact two-column row.
    static func compactReset(to reset: TimeInterval?, now: TimeInterval) -> String? {
        guard let reset, reset.isFinite, reset > 0, reset <= 253402300799, now.isFinite else { return nil }
        let remaining = reset - now
        guard remaining.isFinite else { return nil }
        if remaining <= 0 { return L("已重置", "Reset") }
        if remaining < 60 { return L("<1分", "<1m") }
        guard remaining / 60 < Double(Int.max) else { return nil }
        let minutes = Int(remaining / 60)
        if minutes >= 1440 {
            let days = minutes / 1440, hours = minutes % 1440 / 60
            return hours == 0 ? L("\(days)天", "\(days)d") : L("\(days)天\(hours)时", "\(days)d\(hours)h")
        }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("\(rest)分", "\(rest)m") }
        return rest == 0 ? L("\(hours)时", "\(hours)h") : L("\(hours)时\(rest)分", "\(hours)h\(rest)m")
    }

    static func usageLabel(_ usedPct: Int, predictedDepletion: Bool = false) -> String {
        if usedPct >= 100 { return L("已用尽", "Exhausted") }
        if predictedDepletion { return L("预计耗尽", "May run out") }
        return VGUsageLevel.evaluate(usedPct).label
    }

    /// Only trusted, current predictions replace the existing usage/age label.
    static func usageLabel(_ window: QuotaWindow, trusted: Bool, now: TimeInterval) -> String? {
        guard trusted, QuotaReadingState.evaluate(window, now: now) == .current,
              let burn = window.burn(now: now) else { return nil }
        if let exhaustAt = burn.exhaustAt {
            guard let duration = compactReset(to: exhaustAt, now: now) else { return nil }
            return L("约 \(duration) 耗尽", "Out in ~\(duration)")
        }
        return L("重置时≈\(burn.projectedAtReset)%", "~\(burn.projectedAtReset)% at reset")
    }

    static func deviceColumns(scale: CGFloat) -> Int { scale > 1.1 ? 1 : 2 }

    /// Compact window order is stable: primary 5h, primary week, secondary 5h, secondary week.
    static func primaryWindowIndex(_ runtime: DetectedLLMRuntime, status: RemoteDeviceStatus? = nil, isRemote: Bool = false, now: TimeInterval) -> Int? {
        let candidates = windows(runtime)
        var best: Int?
        for index in candidates.indices where trusted(candidates[index], runtime: runtime, status: status, isRemote: isRemote, now: now) {
            if best == nil || candidates[index].usedPct > candidates[best!].usedPct { best = index }
        }
        return best
    }

    /// Current readings outrank every old reading, including an old 100% window.
    static func priority(_ runtime: DetectedLLMRuntime, status: RemoteDeviceStatus? = nil, isRemote: Bool = false, now: TimeInterval) -> Int {
        let windows = windows(runtime)
        if let current = windows.filter({ trusted($0, runtime: runtime, status: status, isRemote: isRemote, now: now) }).map(\.usedPct).max() {
            return 1000 + current
        }
        return windows.filter {
            let state = QuotaReadingState.evaluate($0, now: now)
            return state == .current || state == .old
        }.map(\.usedPct).max() ?? -1
    }
}

/// Every device's readable windows stay visible; missing readings do not create empty rings.
struct UnifiedQuotaSection: View {
    let report: ScanReport
    let scope: DeviceScope
    let now: TimeInterval
    var openLocal: (String) -> Void
    var openDevice: (String) -> Void

    private struct RingReading: Identifiable {
        let runtime: DetectedLLMRuntime
        let slot: String
        let title: String
        let window: QuotaWindow
        var id: String { runtime.name + ":" + slot }
    }

    private struct DeviceReading: Identifiable {
        let host: String?
        let rings: [RingReading]
        var id: String { host.map { "remote:" + $0 } ?? "local" }
    }

    private func platform(_ name: String) -> String {
        name == "Gemini" || name == "Antigravity" ? "Antigravity" : name
    }

    private func rings(_ runtimes: [DetectedLLMRuntime]) -> [RingReading] {
        let order = ["Claude", "Codex", "Grok", "Antigravity"]
        return runtimes.sorted {
            let lhs = order.firstIndex(of: platform($0.name)) ?? order.count
            let rhs = order.firstIndex(of: platform($1.name)) ?? order.count
            return lhs == rhs ? $0.name < $1.name : lhs < rhs
        }.flatMap { runtime -> [RingReading] in
            let pool = runtime.secondaryPoolName == "三方" || runtime.secondaryPoolName == "3p"
                ? L("三方", "3P") : runtime.secondaryPoolName
            let secondary = pool.isEmpty ? L("副池", "Secondary") : pool
            let candidates: [(String, String, QuotaWindow?)] = [
                ("5h", L("5小时", "5h"), runtime.fiveHour),
                ("week", L("周", "Week"), runtime.sevenDay),
                ("secondary5h", secondary + L("5h", " 5h"), runtime.secondaryFiveHour),
                ("secondaryWeek", secondary + L("周", " Week"), runtime.secondarySevenDay)
            ]
            return candidates.compactMap { slot, title, window in
                guard let window, QuotaPresentation.displayable(window, now: now) else { return nil }
                return RingReading(runtime: runtime, slot: slot, title: title, window: window)
            }
        }
    }

    private var devices: [DeviceReading] {
        var result: [DeviceReading] = []
        if scope == .all || scope == .local {
            let local = rings(report.detectedLLMs)
            if !local.isEmpty { result.append(DeviceReading(host: nil, rings: local)) }
        }
        for host in report.remoteHosts where scope == .all || scope == .remote(host) {
            let remote = rings(report.remoteLLMs[host] ?? [])
            if !remote.isEmpty { result.append(DeviceReading(host: host, rings: remote)) }
        }
        return result
    }

    private var windowColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
              count: VG.scale > 1.1 ? 1 : 2)
    }

    var body: some View {
        let visibleDevices = devices
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleDevices) { device in
                VStack(alignment: .leading, spacing: 5) {
                    deviceHeader(device)
                    LazyVGrid(columns: device.rings.count == 1 ? [GridItem(.flexible(), alignment: .top)] : windowColumns,
                              alignment: .leading, spacing: 6) {
                        ForEach(device.rings) { ring in
                            ringView(ring, device: device)
                        }
                    }
                }
                .padding(.vertical, 2)
                if device.id != visibleDevices.last?.id { Divider().opacity(0.6) }
            }
            if visibleDevices.isEmpty {
                Text(L("暂无可读取的额度", "No readable quota data"))
                    .font(VG.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }

    private func status(_ device: DeviceReading) -> RemoteDeviceStatus? {
        device.host.flatMap { report.remoteDeviceStatus[$0] }
    }

    private func isTrusted(_ ring: RingReading, device: DeviceReading) -> Bool {
        QuotaPresentation.trusted(ring.window, runtime: ring.runtime, status: status(device), isRemote: device.host != nil, now: now)
    }

    private func deviceHeader(_ device: DeviceReading) -> some View {
        let name = device.host.map { RemoteCollector.displayName(for: $0) } ?? L("本机", "Local")
        let offline = !(status(device)?.error ?? "").isEmpty
        let hasCurrent = device.rings.contains { isTrusted($0, device: device) }
        return HStack(spacing: 6) {
            Image(systemName: device.host == nil ? "desktopcomputer" : "network")
                .font(VG.caption).foregroundStyle(.secondary)
            Text(name).font(VG.headline).lineLimit(1).truncationMode(.middle).help(name)
            if offline || !hasCurrent {
                Label(offline ? L("离线", "Offline") : L("旧值", "Last reading"),
                      systemImage: offline ? "wifi.slash" : "clock")
                    .font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(status(device)?.error ?? "")
            }
            Spacer(minLength: 4)
            if let host = device.host {
                Button { openDevice(host) } label: {
                    Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(L("查看设备详情", "Show device details"))
            }
        }
    }

    private func ringView(_ ring: RingReading, device: DeviceReading) -> some View {
        let trusted = isTrusted(ring, device: device)
        let pct = ring.window.usedPct
        let fraction = Double(pct) / 100
        let predicted = trusted && QuotaPresentation.predictedDepletion(ring.window, now: now)
        let forecast = QuotaPresentation.usageLabel(ring.window, trusted: trusted, now: now)
        let level = VGUsageLevel.evaluate(pct, predictedDepletion: predicted)
        let tint = trusted ? level.tint : Color.secondary
        let annotation = !trusted ? sampledAge(ring.window) : forecast ?? QuotaPresentation.usageLabel(pct, predictedDepletion: predicted)
        let annotationTint = forecast != nil ? (predicted ? Color.red : Color.secondary) : tint
        let diameter = 22 * VG.scale
        let width = 2.5 * VG.scale
        let help = readingHelp(ring, device: device, trusted: trusted) + " · " + resetText(ring.window)
        return Button {
            if let host = device.host { openDevice(host) } else { openLocal(ring.runtime.name) }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.10), lineWidth: width)
                    if fraction > 0 {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: fraction == 1 ? .butt : .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: trusted ? level.symbol : "clock")
                        .font(.system(size: 9 * VG.scale, weight: .semibold)).foregroundStyle(tint)
                }
                .frame(width: diameter, height: diameter).padding(width / 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(platform(ring.runtime.name)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text("\(pct)%").font(VG.number(14, .semibold)).fixedSize()
                    }
                    .font(VG.caption).foregroundStyle(trusted ? Color.primary : Color.secondary)
                    HStack(spacing: 3) {
                        Text(ring.title).fixedSize(horizontal: false, vertical: true).help(ring.title)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.clockwise").font(.system(size: 8 * VG.scale))
                        Text(QuotaPresentation.compactReset(to: ring.window.resetsAt, now: now) ?? L("未知", "Unknown"))
                            .monospacedDigit().fixedSize()
                    }
                    .font(VG.caption).foregroundStyle(.secondary).help(resetText(ring.window))
                    if !trusted || forecast != nil || level != .normal {
                        Text(annotation)
                            .font(VG.caption).foregroundStyle(annotationTint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(platform(ring.runtime.name) + " · " + ring.title + " · " + L("已用 \(pct)%", "\(pct)% used") + " · " + annotation + " · " + resetText(ring.window))
    }

    private func sampledAge(_ window: QuotaWindow) -> String {
        guard let captured = window.capturedAt, captured <= now else { return L("旧值 · 时钟异常", "Last · clock mismatch") }
        let age = UIFormat.agoShort(max(0, Int(now - captured)))
        return L("旧值 · \(age)", "Last · \(age)")
    }

    private func resetText(_ window: QuotaWindow) -> String {
        guard let countdown = UIFormat.countdown(to: window.resetsAt, now: now) else { return L("重置时间未知", "Reset unknown") }
        return L("\(countdown)后重置", "Resets in \(countdown)")
    }

    private func readingHelp(_ ring: RingReading, device: DeviceReading, trusted: Bool) -> String {
        var parts = [platform(ring.runtime.name), ring.title]
        if !ring.runtime.tier.isEmpty { parts.append(UIFormat.tier(ring.runtime.tier)) }
        if !ring.runtime.quotaNote.isEmpty { parts.append(UIFormat.metadata(ring.runtime.quotaNote)) }
        if trusted {
            let predicted = QuotaPresentation.predictedDepletion(ring.window, now: now)
            parts.append(QuotaPresentation.usageLabel(ring.window, trusted: trusted, now: now)
                         ?? QuotaPresentation.usageLabel(ring.window.usedPct, predictedDepletion: predicted))
            if let burn = ring.window.burn(now: now) { parts.append(UIFormat.metadata(burn.basis)) }
        }
        if !trusted {
            if let captured = ring.window.capturedAt, captured > now + 60 {
                parts.append(L("采样时间晚于本机时钟", "Sample timestamp is ahead of this device's clock"))
            } else if let captured = ring.window.capturedAt {
                let age = max(0, Int(now - captured))
                parts.append(L("\(UIFormat.agoShort(age))采样", "Sampled \(UIFormat.agoShort(age))"))
            }
            if QuotaPresentation.isRetained(ring.runtime) {
                parts.append(L("未取得新额度，保留上次读数", "Quota missing; showing last reading"))
            }
            if let error = status(device)?.error, !error.isEmpty { parts.append(error) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Shared presentation rules keep CLI request totals separate from proxy timing.
struct ModelPerformanceRow: Identifiable {
    let model: String
    let totals: PerformanceTotals
    let proxyTotals: PerformanceTotals
    let samples: [PerformanceSample]
    let hasCLIRecords: Bool
    var id: String { model }
    var speedSamples: [PerformanceSample] { PerformancePresentation.speedSamples(samples) }
    var estimated: Bool {
        let selected = speedSamples
        return selected.isEmpty ? hasCLIRecords : !selected.contains { UsageHistory.isProxySource($0.source) }
    }
}

enum PerformancePresentation {
    static func speedSamples(_ samples: [PerformanceSample]) -> [PerformanceSample] {
        let proxy = samples.filter { UsageHistory.isProxySource($0.source) && $0.speed != nil }
        return proxy.isEmpty ? samples.filter { !UsageHistory.isProxySource($0.source) && $0.speed != nil } : proxy
    }

    static func rows(snapshot: UsageHistory.Snapshot, scope: DeviceScope, hosts: [String], now: TimeInterval) -> [ModelPerformanceRow] {
        guard snapshot.capturedAt > 0,
              UsageHistory.dayKey(timestamp: snapshot.capturedAt) == UsageHistory.dayKey(timestamp: now) else { return [] }
        var cli: [String: PerformanceTotals] = [:], proxy: [String: PerformanceTotals] = [:]
        for (source, models) in snapshot.todayModels where DeviceScope.includes(source: source, scope: scope, hosts: hosts) {
            for (model, totals) in models {
                if UsageHistory.isProxySource(source) { proxy[model, default: PerformanceTotals()].merge(totals) }
                else { cli[model, default: PerformanceTotals()].merge(totals) }
            }
        }
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let samples = Dictionary(grouping: snapshot.performance.filter {
            $0.timestamp >= start && $0.timestamp <= now && DeviceScope.includes(source: $0.source, scope: scope, hosts: hosts)
        }, by: { $0.model })
        return Set(cli.keys).union(proxy.keys).map { model in
            ModelPerformanceRow(model: model, totals: cli[model] ?? proxy[model] ?? PerformanceTotals(),
                                proxyTotals: proxy[model] ?? PerformanceTotals(), samples: samples[model] ?? [],
                                hasCLIRecords: cli[model] != nil)
        }.sorted { $0.totals.requests == $1.totals.requests ? $0.model < $1.model : $0.totals.requests > $1.totals.requests }
    }

    static func speed(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    static func latency(_ value: Double?) -> String {
        value.map { $0 < 1000 ? String(format: "%.0f ms", $0) : String(format: "%.2f s", $0 / 1000) } ?? "—"
    }
    static func cache(_ totals: PerformanceTotals) -> String {
        totals.context > 0 ? String(format: "%.0f%%", Double(totals.cacheRead) / Double(totals.context) * 100) : "—"
    }
}

/// One overview strip, with recent activity above the existing cost disclosure.
struct OverviewStrip: View {
    let snapshot: UsageHistory.Snapshot
    let scope: DeviceScope
    let hosts: [String]
    let now: TimeInterval
    let forecasts: [String: CostForecast]
    let capturedAt: TimeInterval
    let unpricedCount: Int
    var coverageNote: String? = nil
    var openStats: () -> Void
    var openPrices: () -> Void
    @State private var expanded = false

    private var forecast: CostForecast? {
        let withData = forecasts.filter { $0.value.hasData }
        let candidates = withData.isEmpty ? forecasts : withData
        return candidates["USD"] ?? candidates["CNY"] ?? candidates.keys.sorted().first.flatMap { candidates[$0] }
    }
    private var updatedText: String {
        guard capturedAt > 0 else { return L("汇总中…", "Summarizing…") }
        let age = max(0, Int(now - capturedAt))
        return age < 60 ? L("刚刚更新", "Updated just now") : L("更新于\(UIFormat.agoShort(age))", "Updated \(UIFormat.agoShort(age))")
    }
    private var todayValue: String {
        guard snapshot.capturedAt > 0, Calendar.current.isDate(Date(timeIntervalSince1970: snapshot.capturedAt), inSameDayAs: Date(timeIntervalSince1970: now)) else { return "—" }
        let amounts = snapshot.accountUsage.todayBySource.filter {
            !UsageHistory.isProxySource($0.key) && DeviceScope.includes(source: $0.key, scope: scope, hosts: hosts)
        }.values.reduce(into: [String: Double]()) { result, total in
            for (currency, cost) in total.equivalentCostByCurrency { result[currency, default: 0] += cost }
        }
        return MoneyDisplay.format(amounts, mode: .original, quote: nil).text
    }
    private var hourSamples: [PerformanceSample] {
        snapshot.performance.filter { $0.timestamp >= now - 3600 && $0.timestamp <= now && DeviceScope.includes(source: $0.source, scope: scope, hosts: hosts) }
    }
    /// A model seen in both logs still gets one activity ranking, preferring CLI records.
    private func mainModel(in samples: [PerformanceSample]) -> String? {
        let grouped = Dictionary(grouping: samples.filter { $0.speed != nil }, by: { $0.model })
        var ranked: [(model: String, requests: Int)] = []
        for (model, records) in grouped {
            let cliCount = records.filter { !UsageHistory.isProxySource($0.source) }.count
            ranked.append((model: model, requests: cliCount == 0 ? records.count : cliCount))
        }
        ranked.sort { a, b in a.requests == b.requests ? a.model < b.model : a.requests > b.requests }
        return ranked.first?.model
    }
    private var recent: [String: RecentUsage] {
        snapshot.recentBySource.filter { !UsageHistory.isProxySource($0.key) && DeviceScope.includes(source: $0.key, scope: scope, hosts: hosts) }
    }
    private func speedHelp(hour: [PerformanceSample], rows: [ModelPerformanceRow]) -> String {
        let models = Set(hour.map { $0.model }).union(rows.map { $0.model }).sorted()
        var lines = [L("主模型：\(mainModel(in: hour) ?? "—")", "Main model: \(mainModel(in: hour) ?? "—")"),
                     L("速度为输出 token/s；CLI 为估算，代理为实测。", "Output tokens/s; CLI is estimated, proxy is measured.")]
        for model in models {
            let periods: [(String, [PerformanceSample])] = [
                (L("近 1h", "Last 1h"), hour.filter { $0.model == model }),
                (L("今日", "Today"), rows.first { $0.model == model }?.samples ?? [])
            ]
            for (label, samples) in periods {
                let selected = PerformancePresentation.speedSamples(samples)
                let basis = selected.contains { UsageHistory.isProxySource($0.source) } ? L("代理", "Proxy") : L("估算", "Est.")
                lines.append("\(model) · \(label) · \(basis): p50 \(PerformancePresentation.speed(PerformanceStats.speed(selected))), p90 \(PerformancePresentation.speed(PerformanceStats.speed(selected, percentile: 0.9)))")
            }
        }
        lines.append(L("分位数使用每来源、模型最近最多 500 条样本；主模型按近 1h 有效速度样本数选择。", "Percentiles use up to 500 recent samples per source/model; the main model has the most valid last-hour speed samples."))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let hour = hourSamples
        let model = mainModel(in: hour)
        let mainSamples = hour.filter { $0.model == model }
        let speeds = PerformancePresentation.speedSamples(mainSamples)
        let estimated = !speeds.contains { UsageHistory.isProxySource($0.source) }
        let rows = PerformancePresentation.rows(snapshot: snapshot, scope: scope, hosts: hosts, now: now)
        let today = rows.reduce(into: PerformanceTotals()) { $0.merge($1.totals) }
        let recent = self.recent
        let turnSamples = snapshot.turnLatencies.filter {
            DeviceScope.includes(source: $0.source, scope: scope, hosts: hosts) && $0.isSuccessfulSample &&
                $0.timestamp >= now - 3600 && $0.timestamp <= now
        }
        let nativeTTFT = PerformanceStats.turnTTFT(turnSamples, since: now - 3600, until: now)
        let proxyTTFT = PerformanceStats.ttft(hour)
        let ttft = nativeTTFT ?? proxyTTFT
        let hourRequests = recent.values.reduce(0) { $0 + $1.requestsLastHour }
        let hourContext = recent.values.reduce(Int64(0)) { $0 + $1.contextLastHour }
        let averageContext = hourRequests > 0
            ? String(format: "%.1fK", Double(hourContext) / Double(hourRequests) / 1000) : "—"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("实时 · 近 1h", "Live · last 1h")).font(VG.font(11, .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(updatedText).font(VG.caption).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 14) {
                metric(title: L("输出速度", "Output speed"),
                       value: PerformancePresentation.speed(PerformanceStats.speed(speeds)),
                       detail: model == nil ? L("暂无样本", "No samples") : (estimated ? L("CLI 估算 · tok/s", "CLI est. · tok/s") : L("代理实测 · tok/s", "Proxy · tok/s")),
                       help: speedHelp(hour: hour, rows: rows))
                metric(title: L("首字延迟", "First token"),
                       value: PerformancePresentation.latency(ttft),
                       detail: nativeTTFT != nil ? "Codex · p50" : L("首响应近似 · p50", "First response est. · p50"),
                       help: L("Codex 使用完成事件中的 time_to_first_token_ms，按设备与 turn ID 去重，排除失败轮次；只在整轮结束后出现。近 1h 无此类样本时，显示代理首响应近似，计时截至首次写出响应，可能包含元数据。两种样本不混合计算；缺失显示 —。", "Codex uses time_to_first_token_ms from completed turns, deduplicated by device and turn ID, excluding failed turns. Samples appear after the turn completes. Without a last-hour Codex sample, proxy first-response timing is shown as an approximation; it may include metadata. The two measurements are never pooled. Missing data shows —.") + (proxyTTFT.map { L("\n代理首响应 p50：", "\nProxy first-response p50: ") + PerformancePresentation.latency($0) } ?? ""))
            }
            Divider().opacity(0.6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: 2), alignment: .leading, spacing: 7) {
                compactMetric(title: L("平均上下文", "Context / req"), value: averageContext,
                              help: L("当前设备范围内近 1h 完整 CLI 记录的输入 token（含缓存）÷ 请求数，以 K 显示；不受速度采样上限影响，不重复计入代理。", "Input tokens (including cache) divided by requests from complete CLI records in the selected device scope over the last hour, shown in K; independent of the speed sample cap and excluding proxy duplicates."))
                compactMetric(title: "Token", value: recent.isEmpty ? "—" : formatTokens(recent.values.reduce(Int64(0)) { $0 + $1.tokensLastHour }),
                              help: L("最近一小时的完整 CLI 记录：输入（含缓存）+ 输出；不受速度采样上限影响，不重复计入 API 代理。", "Complete last-hour CLI records: input (including cache) plus output, independent of the speed sample cap; API proxy records are excluded to avoid duplication."))
                compactMetric(title: L("请求/分 · 15m", "Req/min · 15m"),
                              value: recent.isEmpty ? "—" : String(format: "%.1f", Double(recent.values.reduce(0) { $0 + $1.requestsLast15m }) / 15),
                              help: L("最近 15 分钟完整 CLI 请求数 ÷ 15；数据缺失显示 —。", "Complete CLI request count over the last 15 minutes divided by 15; unavailable data shows —."))
                compactMetric(title: L("参考费用/h", "Reference cost/h"), value: forecast.map { Fmt.money($0.lastHourCost, $0.currency) } ?? "—",
                              help: L("原有费用记录的近 1h 参考值；订阅内调用可能记为 0。", "Last-hour reference from the original cost records; included subscription calls can be recorded as zero.") + "\n" + forecasts.keys.sorted().compactMap { currency in forecasts[currency].map { "\(Fmt.money($0.lastHourCost, currency))/h" } }.joined(separator: "\n"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: openStats) {
                    HStack(spacing: 4) {
                        Text(L("缓存命中", "Cache hit")).foregroundStyle(.secondary)
                        Text(PerformancePresentation.cache(today)).monospacedDigit().foregroundStyle(.primary)
                        Text(L("今日", "today")).foregroundStyle(.tertiary)
                    }
                    .font(VG.caption).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("今日缓存读取 token ÷ 输入 token；同模型有 CLI 记录时优先 CLI，避免重复统计代理。", "Today’s cache-read tokens divided by input tokens; CLI totals take priority for models also recorded by the proxy."))
                Spacer(minLength: 0)
                Label(L("未含云端 / Dot", "Cloud / Dot excluded"), systemImage: "cloud")
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VGInfoButton(title: L("估算与覆盖范围", "Estimate and coverage"),
                             text: L("按参考 API 单价折算，不是订阅账单。指标来自已采集日志；远程缺失计时不使用本机数据代替。未含 Codex 云端 / Dot 用量。", "Reference API estimates are not subscription bills. Metrics use collected logs; missing remote timing is never replaced by local data. Codex Cloud / Dot usage is excluded."))
            }
            DisclosureGroup(isExpanded: $expanded) {
                details.padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text(L("今日 API 等价估算", "Today’s API estimate")).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(todayValue).font(VG.number(13)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    Spacer(minLength: 0)
                }
            }
            .tint(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                cell(title: L("今日累计", "Today so far"), value: todayValue)
                Rectangle().fill(VG.stroke).frame(width: 0.5)
                cell(title: L("本月 · 原记录", "Month · original records"), value: forecast.map { Fmt.money($0.monthSoFar, $0.currency) } ?? "—")
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(forecasts.keys.sorted().filter { $0 != forecast?.currency }, id: \.self) { currency in
                if let other = forecasts[currency], other.hasData {
                    Text(L("\(currency) · 今日 \(Fmt.money(other.todaySoFar, currency)) · 本月已计 \(Fmt.money(other.monthSoFar, currency))",
                           "\(currency) · today \(Fmt.money(other.todaySoFar, currency)) · month to date \(Fmt.money(other.monthSoFar, currency))"))
                        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 4) {
                Text(coverageNote ?? updatedText).font(VG.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button(L("价格明细", "Rates"), action: openPrices).font(VG.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if unpricedCount > 0 {
                Button(L("\(unpricedCount) 个模型未定价", "\(unpricedCount) unpriced models"), action: openPrices)
                    .font(VG.caption).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        }
    }

    private func metric(title: String, value: String, detail: String, help: String) -> some View {
        Button(action: openStats) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(VG.caption).foregroundStyle(.secondary)
                Text(value).font(VG.number(18, .semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(VG.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func compactMetric(title: String, value: String, help: String) -> some View {
        Button(action: openStats) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(VG.caption).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                    Text(value).font(VG.number(13, .medium)).foregroundStyle(.primary).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(value).font(VG.number(13, .medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
    private func cell(title: String, value: String) -> some View {
        Button(action: openStats) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(VG.caption).foregroundStyle(.secondary)
                Text(value).font(VG.number(13, .semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 模型健康详情页（降智检测）。
struct HealthDetailView: View {
    let report: NerfReport
    var rescan: () -> Void

    private var grouped: [(NerfFinding.Severity, [NerfFinding])] {
        [NerfFinding.Severity.hard, .soft, .good, .info].compactMap { sev in
            let items = report.findings.filter { $0.severity == sev }
            return items.isEmpty ? nil : (sev, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            if !report.currentModels.isEmpty { modelsCard }
            findingsCard
            if !report.probes.isEmpty {
                probeCard
            } else {
                DisclosureGroup {
                    probeCard.padding(.top, 6)
                } label: {
                    HStack {
                        Text(L("指纹检测", "Fingerprint check"))
                        Spacer(minLength: 4)
                        Text(report.probeInstalled ? L("已安装", "Installed") : L("未安装", "Not installed"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(VG.caption).foregroundStyle(.secondary).tint(.secondary)
            }
            DisclosureGroup(L("检测方法", "How checks work")) {
                methodCard.padding(.top, 6)
            }
            .font(VG.caption).foregroundStyle(.secondary).tint(.secondary)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: report.status.symbol)
                .font(.system(size: 20 * VG.scale, weight: .semibold))
                .foregroundStyle(report.status.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.status.label).font(VG.title)
                Text(healthText(report.headline)).font(VG.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(report.headline)
                Text(L("近 48 小时 · \(report.sessionsScanned) 个会话 · \(report.turnsScanned) 轮", "Last 48 hours · \(report.sessionsScanned) sessions · \(report.turnsScanned) turns")).font(VG.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button(action: rescan) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L("立刻重新检查", "Check again now"))
        }
        .vgCard()
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            VGSectionHeader(L("正在用的模型", "Current models"), symbol: "cpu.fill", tint: .blue)
            ForEach(report.currentModels.keys.sorted(), id: \.self) { key in
                VGKeyValue(key: key, value: report.currentModels[key] ?? "")
            }
        }
        .vgCard()
    }

    private var findingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: L("证据", "Evidence"), symbol: "list.bullet.rectangle.fill", tint: .orange) {
                Text(L("\(report.findings.count) 条", "\(report.findings.count) findings")).font(VG.caption).foregroundStyle(.secondary)
            }
            if report.findings.isEmpty {
                Label(L("没发现模型被换、推理级别被降或上下文被缩的记录", "No recorded model replacement, reduced reasoning or smaller context window"), systemImage: "checkmark.circle")
                    .font(VG.subheadline).foregroundStyle(.secondary)
            }
            ForEach(grouped.indices, id: \.self) { gi in
                let sev = grouped[gi].0
                let items = grouped[gi].1
                VStack(alignment: .leading, spacing: 5) {
                    Text(sev.label).font(VG.font(10, .semibold)).foregroundStyle(sev.tint)
                    ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, finding in
                        if index > 0 { Divider() }
                        findingRow(finding)
                    }
                    if items.count > 8 { Text(L("另 \(items.count - 8) 条", "\(items.count - 8) more findings")).font(VG.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .vgCard()
    }

    private func findingRow(_ f: NerfFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: f.severity.symbol).font(VG.font(12, .semibold)).foregroundStyle(f.severity.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(healthText(f.title)).font(VG.font(12, .medium)).lineLimit(2).help(f.title)
                    Spacer(minLength: 4)
                    Text(UIFormat.agoShort(max(0, Int(Date().timeIntervalSince1970 - f.timestamp)))).font(VG.caption).foregroundStyle(.tertiary).fixedSize()
                }
                Text(healthText(f.detail)).font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).help(f.detail)
                HStack(spacing: 4) {
                    VGPill(text: healthText(f.source), tint: .secondary)
                    if !f.session.isEmpty { VGPill(text: f.session, tint: .blue, symbol: "folder") }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VGSectionHeader(title: L("指纹检测（is-gpt-nerfed）", "Fingerprint check (is-gpt-nerfed)"), symbol: "waveform.path.ecg", tint: .pink) {
                VGPill(text: report.probeInstalled ? L("已安装", "Installed") : L("未安装", "Not installed"), tint: report.probeInstalled ? .green : .secondary)
            }
            if report.probeInstalled {
                if report.probes.isEmpty {
                    Text(L("近 7 天还没有检测记录。在 Codex 里输入 $is-gpt-nerfed 可立即检测。", "No checks in the last 7 days. Enter $is-gpt-nerfed in Codex to run one.")).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(report.probes.prefix(5)) { p in
                    HStack(spacing: 6) {
                        Text(healthText(NerfDetector.verdictTitle(p)).replacingOccurrences(of: L("指纹：", "Fingerprint: "), with: ""))
                            .font(VG.font(11, .semibold))
                            .foregroundStyle(p.verdict == "MATCH" ? Color.green : (p.verdict == "SUSPICIOUS" ? .orange : (p.verdict.hasPrefix("INVALID") ? .secondary : .red)))
                        Text("\(p.expected) → \(p.prediction)").font(VG.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(p.probability.map { String(format: "%.0f%%", $0 * 100) } ?? "").font(VG.number(10, .medium)).foregroundStyle(.secondary)
                        Text(UIFormat.agoShort(max(0, Int(Date().timeIntervalSince1970 - p.finished)))).font(VG.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text(L("被动检测只能看到 Codex 自己记下的模型名。想确认「名字没变、权重被换」，可以装 is-gpt-nerfed：它用 ModelTrace 随机数指纹比对（每次约 3 条短回答的 token），结论会自动出现在这里。", "Passive checks read the model name recorded by Codex. is-gpt-nerfed can also check model weights using ModelTrace fingerprints, costing roughly three short replies per check. Its results appear here."))
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "https://github.com/kiyoakii/is-gpt-nerfed/blob/main/README.zh-CN.md") { NSWorkspace.shared.open(url) }
                } label: {
                    Label(L("查看安装方法", "Installation guide"), systemImage: "arrow.up.right.square").font(VG.font(11, .medium))
                }
                .buttonStyle(.link)
            }
        }
        .vgCard()
    }

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("怎么判断的", "How checks work")).font(VG.font(10, .semibold)).foregroundStyle(.secondary)
            Text(L("· Codex：没改设置（无 thread_settings_applied）却换了更弱的模型、调低了推理级别、跑了隐藏的内部模型、上下文窗口变小 → 硬证据；改了设置的变化标「是你改的吗？」。", "· Codex: a weaker model, lower reasoning, hidden model or smaller context without a recorded settings change is marked as hard evidence. Recorded settings changes are identified separately."))
            Text(L("· Claude Code：主对话里没用 /model 却换成了更小的档位（如 Opus → Sonnet）→ 硬证据；来回切换（opusplan 这类）只提示。", "· Claude Code: a smaller model tier in the main conversation without /model is marked as hard evidence. Repeated switches, such as opusplan routing, are informational."))
            Text(L("· 行为统计：今天每次请求的平均输出、思考占比明显低于近两周中位数 → 可疑，仅供参考。", "· Behavior: average output or reasoning share well below the 14-day median is a suspicious signal for reference only."))
            Text(L("· 全部只读本机日志，0 token；指纹检测由 is-gpt-nerfed 自己调度。", "· Passive checks only read local logs and use no tokens. Fingerprint checks are scheduled by is-gpt-nerfed."))
        }
        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .vgCard()
    }
}

/// The detector preserves its original evidence strings. Translate their presentation here.
private func healthText(_ value: String) -> String {
    var english = value
    let titles: [(String, String)] = [
        ("没发现模型被换、推理被降或上下文被缩", "No model replacement, lower reasoning or smaller context detected"),
        ("还没有可检查的会话", "No sessions available to check"),
        ("发现降级证据", "Degradation evidence found"),
        ("有可疑迹象", "Suspicious signs found"),
        ("模型来回切换（像 opusplan 自动路由）", "Models alternate, possibly through opusplan routing"),
        ("内部隐藏模型回答了本轮", "A hidden internal model answered this turn"),
        ("设置里换成了更弱的模型（是你改的吗？）", "Settings selected a weaker model — did you change it?"),
        ("设置里换了模型", "Model changed in settings"),
        ("没改设置，模型被换成更弱的", "Weaker model without a settings change"),
        ("没改设置，模型升级了", "Model upgraded without a settings change"),
        ("没改设置，模型变了", "Model changed without a settings change"),
        ("设置里调低了推理级别", "Reasoning reduced in settings"),
        ("设置里调整了推理级别", "Reasoning changed in settings"),
        ("没改设置，推理级别被调低", "Reasoning reduced without a settings change"),
        ("没改设置，推理级别变了", "Reasoning changed without a settings change"),
        ("服务档位变化（只影响速度）", "Service tier changed (speed only)"),
        ("上下文窗口被缩小", "Context window became smaller"),
        ("上下文窗口变大", "Context window became larger"),
        ("你用 /model 换了模型", "Model changed with /model"),
        ("没用 /model，模型被换成更弱的", "Weaker model without /model"),
        ("没用 /model，模型变了", "Model changed without /model"),
        ("API 错误 / 过载偏多", "Frequent API errors or overloads"),
        ("Codex 思考占比下降", "Codex reasoning share decreased"),
        ("行为统计", "Behavior"),
        ("指纹：", "Fingerprint: "),
        ("已降配", "Downgraded"), ("被降配", "Downgraded"), ("被升配", "Upgraded"),
        ("模型被换", "Model changed"), ("未收录的模型", "Unlisted model"),
        ("本次无结果", "No result"), ("可疑", "Suspicious")
    ]
    for (source, replacement) in titles { english = english.replacingOccurrences(of: source, with: replacement) }
    let patterns: [(String, String)] = [
        (#"(Codex|Claude) 回答明显变短"#, "$1 replies became shorter"),
        (#"今天每次请求平均输出 (\d+) token，近两周中位数 (\d+)（仅供参考）"#, "Average output today: $1 tokens; 14-day median: $2 (reference only)"),
        (#"今天思考占输出 ([\d.]+)%，近两周中位数 ([\d.]+)%（仅供参考）"#, "Reasoning share today: $1%; 14-day median: $2% (reference only)"),
        (#"近 24 小时 (\d+) 次错误，占 (\d+)%"#, "$1 errors in the last 24 hours ($2%)"),
        (#"选的是 (.+)，指纹更像 (.+)（(.+)）"#, "Selected $1; fingerprint resembles $2 ($3)"),
        (#"Codex 模型目录把 (.+) 列为 (.+) 的后继"#, "Codex's catalog lists $1 as the successor to $2"),
        (#"(.+) 是 Codex 不公开列出的内部模型"#, "$1 is an internal model absent from Codex's public catalog"),
        (#"从内部模型 (.+) 换回来了"#, "Switched back from internal model $1"),
        (#"更新的一代（(.+)）"#, "Newer generation ($1)"),
        (#"更旧的一代（(.+)）"#, "Older generation ($1)"),
        (#"Codex 目录排序 (.+) 在 (.+) 之前"#, "Codex's catalog ranks $1 before $2"),
        (#"Codex 目录排序 (.+) 在 (.+) 之后"#, "Codex's catalog ranks $1 after $2")
    ]
    for (pattern, replacement) in patterns {
        english = english.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    let details: [(String, String)] = [
        ("不是你能选的公开模型", "is not a public model you can select"),
        ("同一个模型", "Same model"), ("换到更大的档位", "Switched to a larger model tier"),
        ("换到更小的档位", "Switched to a smaller model tier"),
        ("更大的档位", "Larger model tier"), ("更小的档位", "Smaller model tier"),
        ("，档位也不同", ", with a different model tier"),
        ("支持的最高推理级别更高", "Higher maximum reasoning level"),
        ("支持的最高推理级别更低", "Lower maximum reasoning level"),
        ("上下文窗口更大", "Larger context window"), ("上下文窗口更小", "Smaller context window"),
        ("同代同档，目录里没有先后", "Same generation and tier; no catalog ordering"),
        ("：", ": ")
    ]
    for (source, replacement) in details { english = english.replacingOccurrences(of: source, with: replacement) }
    if english.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
        english = "Recorded diagnostic — original text in help"
    }
    return L(value, english)
}

/// Small first-screen summary. Detailed performance remains in the Live page.
struct DailyUsageSummary: View {
    let snapshot: UsageHistory.Snapshot
    let scope: DeviceScope
    let hosts: [String]
    let now: TimeInterval
    let mode: DisplayCurrency
    let quote: ExchangeQuote?
    var openStats: () -> Void
    var openLive: () -> Void

    private var today: AccountUsageTotals {
        snapshot.accountUsage.todayBySource.filter {
            !UsageHistory.isProxySource($0.key) && DeviceScope.includes(source: $0.key, scope: scope, hosts: hosts)
        }.values.reduce(into: AccountUsageTotals()) { total, value in
            total.usage.add(value.usage); total.requests += value.requests; total.unpricedRequests += value.unpricedRequests
            for (currency, cost) in value.equivalentCostByCurrency { total.equivalentCostByCurrency[currency, default: 0] += cost }
        }
    }
    private var currentDay: Bool {
        snapshot.capturedAt > 0 && Calendar.current.isDate(Date(timeIntervalSince1970: snapshot.capturedAt), inSameDayAs: Date(timeIntervalSince1970: now))
    }
    private var firstToken: (Double?, Bool) {
        let samples = snapshot.turnLatencies.filter { DeviceScope.includes(source: $0.source, scope: scope, hosts: hosts) }
        if let native = PerformanceStats.turnTTFT(samples, since: now - 3600, until: now) { return (native, true) }
        let proxy = snapshot.performance.filter {
            $0.timestamp >= now - 3600 && $0.timestamp <= now && DeviceScope.includes(source: $0.source, scope: scope, hosts: hosts)
        }
        return (PerformanceStats.ttft(proxy), false)
    }
    var body: some View {
        let totals = today
        let cost = MoneyDisplay.format(totals.equivalentCostByCurrency, mode: mode, quote: quote)
        let latency = firstToken
        let originalAmounts = totals.equivalentCostByCurrency.keys.sorted().map {
            MoneyDisplay.amount(totals.equivalentCostByCurrency[$0]!, currency: $0)
        }
        let amounts = currentDay && (mode == .original || cost.conversionUnavailable) && !originalAmounts.isEmpty
            ? originalAmounts : [currentDay ? cost.text : "—"]
        return HStack(alignment: .top, spacing: 16) {
            Button(action: openStats) {
                VStack(alignment: .leading, spacing: 3) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(amounts.indices, id: \.self) { index in
                            Text(amounts[index]).font(VG.number(amounts.count > 1 ? 14 : 20)).foregroundStyle(.primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    Text(currentDay ? formatTokens(totals.usage.tokenTotal) + " token" : "— token")
                        .font(VG.caption).foregroundStyle(.secondary)
                    if currentDay && totals.unpricedRequests > 0 {
                        Text(L("部分请求未定价", "Some requests unpriced")).font(VG.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("summary.today")
                .help(L("今日 API 等价用量，不是订阅实付账单。点击查看统计。", "Today’s API-equivalent usage, not subscription charges. Open statistics.") + (cost.detail.isEmpty ? "" : "\n" + cost.detail))
            Button(action: openLive) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("首字 · 近 1h", "First token · 1h")).font(VG.caption).foregroundStyle(.secondary)
                    Text(PerformancePresentation.latency(latency.0)).font(VG.number(20)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(latency.0 == nil ? L("暂无计时", "No timing yet") : latency.1 ? "Codex · p50" : L("首响应近似 · p50", "First response est. · p50"))
                        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("summary.ttft")
                .help(L("Codex 完成事件记录的首 token 时间，按设备与 turn 去重，排除失败。没有 Codex 样本时使用代理首响应近似，两者不混合。点击查看全部实时指标和设备明细。", "Completed Codex turns’ own first-token timing, deduplicated by device and turn, excluding failures. Without Codex samples, shows proxy first-response timing as a separate approximation. Open all Live metrics and device details."))
        }
    }
}
