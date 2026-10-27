import Cocoa
import Combine
import SwiftUI
import os

/// Label for an inline picker: a small glass capsule instead of the native pull-down look.
struct GlassChipLabel: View {
    var icon: String
    var text: String
    var tint: Color? = nil
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9 * VG.scale, weight: .semibold)).foregroundStyle(tint ?? .secondary)
            Text(text).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7 * VG.scale, weight: .bold)).foregroundStyle(.tertiary)
        }
        .font(VG.font(11, .medium)).foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

struct MiniProgressBar: View {
    var value: Double
    var color: Color = .green
    var width: CGFloat = 16
    var height: CGFloat = 3.5

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: width, height: height)

            let safeRatio = max(0, min(1.0, value))
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: width * CGFloat(safeRatio), height: height)
        }
    }
}

/// 承接滚动的容器。**必须放在这一层**：macOS 只把滚动事件派给光标下最深的可滚动视图，
/// SwiftUI 的 ScrollView 会吞掉它，挂在外层 NSHostingView 上收不到。
/// 横向为主 → 切 Tab 并吞事件；其余交给正常纵向滚动。
final class SwipeScrollView: NSScrollView {
    var onSwipe: ((Int) -> Void)?
    private let log = Logger(subsystem: "io.github.xixilys.vibedeck", category: "swipe")
    private var accum: CGFloat = 0
    private var lastAt: TimeInterval = 0
    private var armed = true          // 一次物理手势只允许触发一次（否则一次滑动会连跳两步）

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX      // AppKit 已按用户的「自然滚动」设置给过方向，别再取反
        let dy = e.scrollingDeltaY
        let hasPhase = e.phase != [] || e.momentumPhase != []
        if e.phase == .began { accum = 0; armed = true }

        guard abs(dx) > abs(dy) * 1.5 else {
            accum = 0
            super.scrollWheel(with: e)
            return
        }
        guard e.momentumPhase == [] else { return }          // 惯性阶段只吞掉
        if hasPhase && !armed { return }                     // 本次手势已触发过，剩下的事件全吞掉

        accum += dx
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 45 : 3
        let now = Date().timeIntervalSince1970
        if abs(accum) >= threshold, now - lastAt > 0.25 {
            let step = accum < 0 ? 1 : -1                    // 向左滑 = 下一步；向右滑 = 上一步/返回
            log.debug("swipe accum=\(self.accum) step=\(step) phase=\(e.phase.rawValue)")
            accum = 0
            lastAt = now
            if hasPhase { armed = false }
            onSwipe?(step)
        }
    }
}

private struct MeasuredScrollContent<Content: View>: View {
    let content: Content
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { reportHeight(geometry.size.height) }
                    .onChange(of: geometry.size.height) { _, height in reportHeight(height) }
            })
    }

    private func reportHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        DispatchQueue.main.async { onHeight(height) }
    }
}

private struct PanelHeightPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// The popover itself is the glass on macOS 26+; older systems get a light behind-window blur.
/// Either way the panel stays see-through rather than a flat menu fill.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        if #available(macOS 26, *) { view.isHidden = true }
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
    static let refreshVibeDeckPanel = Notification.Name("VibeDeck.refreshPanel")
    static let selectVibeDeckTab = Notification.Name("VibeDeck.selectTab")
    static let vibeDeckPanelReopened = Notification.Name("VibeDeck.panelReopened")
}

struct SwipeScroll<Content: View>: NSViewRepresentable {
    let content: Content
    let onSwipe: (Int) -> Void
    let onHeight: (CGFloat) -> Void

    final class Coordinator {
        private var pendingUpdate: (() -> Void)?
        private var updateScheduled = false
        private var generation: UInt = 0

        func schedule(_ update: @escaping () -> Void) {
            pendingUpdate = update
            guard !updateScheduled else { return }
            updateScheduled = true
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.updateScheduled = false
                let latest = self.pendingUpdate
                self.pendingUpdate = nil
                latest?()
            }
        }

        func cancel() {
            generation &+= 1
            pendingUpdate = nil
            updateScheduled = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SwipeScrollView {
        let sv = SwipeScrollView()
        sv.hasVerticalScroller = false          // 用户不要侧边滚动条；触控板照样能滚
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.onSwipe = onSwipe
        let host = NSHostingView(rootView: MeasuredScrollContent(content: content, onHeight: onHeight))
        // The document width is fixed below; only its natural height is needed.
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = host
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            host.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor)
        ])
        return sv
    }

    func updateNSView(_ sv: SwipeScrollView, context: Context) {
        sv.onSwipe = onSwipe
        if let host = sv.documentView as? NSHostingView<MeasuredScrollContent<Content>> {
            let latest = MeasuredScrollContent(content: content, onHeight: onHeight)
            // Updating another hosting tree synchronously inside a SwiftUI update can reenter layout.
            context.coordinator.schedule { [weak host] in host?.rootView = latest }
        }
    }

    static func dismantleNSView(_ nsView: SwipeScrollView, coordinator: Coordinator) {
        coordinator.cancel()
        nsView.onSwipe = nil
    }
}

/// Panel actions are injected by AppDelegate; actions that need dismissal close the popover first.
public struct PanelActions {
    /// 主线程读取常驻采集器已经生成的报告；面板不重复扫描日志和进程。
    public var latestReport: () -> ScanReport? = { nil }
    public var accountQuotas: () -> [AccountQuotaObservation] = { [] }
    public var accountLedgerError: () -> String? = { nil }
    public var isVisible: () -> Bool = { true }
    public var cleanOrphans: () -> Void = {}
    public var cleanNPX: () -> Void = {}
    public var rescan: () -> Void = {}
    public var refreshHealth: (@escaping (NerfReport) -> Void) -> Void = { completion in completion(NerfReport()) }
    public var setAutoClean: (Bool) -> Void = { _ in }
    public var setLaunchAtLogin: (Bool) -> Void = { _ in }
    public var setThresholdNotify: (Bool) -> Void = { _ in }
    public var setExitChangeNotify: (Bool) -> Void = { _ in }
    public var setFontScale: (Double) -> Void = { _ in }
    public var installProxy: () -> Void = {}
    public var uninstallProxy: () -> Void = {}
    public var copyProxyPrefix: () -> Void = {}
    public var purgeLogs: () -> Void = {}
    /// State changes request a relayout; the measured outer height is reported separately.
    public var relayout: () -> Void = {}
    public var panelHeightChanged: (CGFloat) -> Void = { _ in }
    public var syncPrices: (@escaping (String, Bool) -> Void) -> Void = { completion in completion("", false) }
    public var quit: () -> Void = {}
    public init() {}
}

public struct PanelSettings {
    public var autoClean: Bool = false
    public var launchAtLogin: Bool = false
    public var thresholdNotify: Bool = true
    public var exitChangeNotify: Bool = true
    public var fontScale: Double = 1.0
    public init(autoClean: Bool = false, launchAtLogin: Bool = false, thresholdNotify: Bool = true, exitChangeNotify: Bool = true, fontScale: Double = 1.0) {
        self.autoClean = autoClean
        self.launchAtLogin = launchAtLogin
        self.thresholdNotify = thresholdNotify
        self.exitChangeNotify = exitChangeNotify
        self.fontScale = fontScale
    }
}

/// 全局「设备」作用域：本机 / 某台远程主机 / 全部（本机 + 所有远程）。
/// 只影响展示，不动任何采集口径；持久化成 "all" / "local" / "remote:<host>"。
public enum DeviceScope: Equatable {
    case all
    case local
    case remote(String)

    /// 持久化键：写进 @AppStorage("vg.device")。
    public var key: String {
        switch self {
        case .all: return "all"
        case .local: return "local"
        case .remote(let host): return "remote:\(host)"
        }
    }

    /// 反序列化。坏值（含空主机名）一律回落到「全部」，免得锁死在空视图。
    public static func from(key: String) -> DeviceScope {
        if key == "local" { return .local }
        if key.hasPrefix("remote:") {
            let host = String(key.dropFirst("remote:".count))
            return host.isEmpty ? .all : .remote(host)
        }
        return .all
    }

    /// 配置变了（那台主机被删了）→ 回落「全部」。
    public func resolved(hosts: [String]) -> DeviceScope {
        if case .remote(let host) = self, !hosts.contains(host) { return .all }
        return self
    }

    /// 某个历史来源是否属于当前设备。
    /// 远程 / 挂载来源都带设备后缀 `Claude · <设备>`（见 UsageHistory.device）；没后缀的（含 API · X 记账）都算本机。
    public static func includes(source: String, scope: DeviceScope, hosts: [String]) -> Bool {
        switch scope {
        case .all:
            return true
        case .local:
            return UsageHistory.device(of: source) == nil
        case .remote(let host):
            return UsageHistory.device(of: source) == host
        }
    }

    /// 有历史快照后，受支持的 CLI 统一使用已去重的当日记录（包括 archived / opencode）。
    /// 本机实时行仅在首次扫描前回退使用；API 代理不重复计入。
    static func todayUsage(local: [CLIUsage], history: [String: UsageHistory.Totals], scope: DeviceScope,
                           historyReady: Bool = true) -> [CLIUsage] {
        let labels = ["Claude": "Claude Code", "Codex": "Codex", "OpenCode": "opencode", "DSH": "DSH", "Grok": "Grok", "CPA": "CPA"]
        var rows: [CLIUsage]
        if case .remote = scope { rows = [] } else { rows = local }
        guard historyReady else { return rows }
        rows = rows.map { row in
            guard labels.values.contains(row.name) else { return row }
            var empty = CLIUsage(name: row.name)
            empty.note = L("今日暂无已采集用量", "No collected usage today")
            return empty
        }
        for source in history.keys.sorted() {
            guard !UsageHistory.isProxySource(source),
                  includes(source: source, scope: scope, hosts: []),
                  let label = labels[UsageHistory.cli(of: source)], let totals = history[source] else { continue }
            guard totals.turns > 0 || totals.tokenTotal > 0 else { continue }
            let index: Int
            if let existing = rows.firstIndex(where: { $0.name == label }) { index = existing }
            else { rows.append(CLIUsage(name: label)); index = rows.count - 1 }
            rows[index].ctx += totals.ctx
            rows[index].cacheRead += totals.cacheRead
            rows[index].out += totals.out
            rows[index].think += totals.think
            rows[index].requests += totals.turns
            rows[index].turns += totals.turns
            if rows[index].hasTokens { rows[index].note = "" }
        }
        return rows
    }
}

/// 菜单里的面板：顶部 Tab 切换（订阅 / API / 统计 / 网络 / 系统），高度随当前 Tab 内容自适应（实测 macOS 14 NSMenu 会跟着
/// 自定义视图的 frame 实时重排），只有超过屏幕可用高度才在内部滚动。
public struct DashboardView: View {
    @State public var report: ScanReport
    public var actions: PanelActions

    static let panelWidth: CGFloat = 380
    /// A menu panel stays compact even on a tall display; longer pages scroll inside it.
    static var maxPanelHeight: CGFloat {
        // The native popover adds 26pt around the content. Limit the window the user actually sees.
        let outerLimit: CGFloat = VG.scale > 1.1 ? 760 : 700
        return min(outerLimit - 26, max(120, (NSScreen.main?.visibleFrame.height ?? 900) - 50))
    }

    @AppStorage("vg.tab") private var tab: Int = 0
    @AppStorage("vg.showAPITab") private var showAPITab = true
    @AppStorage("vg.device") private var deviceKey: String = "all"
    @AppStorage("vg.todayCLI") private var todayCLIKey: String = ""
    @AppStorage("vg.language") private var languageKey: String = "system"
    @AppStorage("remoteHosts") private var remoteHostsRaw: String = ""
    @State private var newHost = ""
    @State private var hostError = ""
    @AppStorage(DisplayCurrency.defaultsKey) private var currencyKey = "usd"
    @ObservedObject private var exchangeRates = ExchangeRates.shared
    @State private var accountQuotas: [AccountQuotaObservation] = []
    @State private var accountLedgerError: String?
    @State private var expandedCards: Set<String> = []
    @State private var measuredHeight: CGFloat = 400
    @State private var heightGeneration = 0
    @State private var panelChromeHeight: CGFloat = 116
    @State private var mountAvailability: [String: Bool] = [:]
    @State private var mountCheckPending = false
    @State private var detailBackStack: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drillDown: String? = nil      // 非空 = 正在看某个平台的详情页
    @State private var autoCleanOn: Bool
    @State private var launchAtLoginOn: Bool
    @State private var notifyOn: Bool
    @State private var exitNotifyOn: Bool
    @State private var fontScaleOn: Double
    @State private var refreshPending = false
    @State private var devicePickerShown = false

    @State private var liveNow: Date = Date()
    @State private var network = NetworkSnapshot()
    @State private var history = UsageHistory.Snapshot()
    @State private var health = NerfReport()

    private let liveTicker = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    public init(report: ScanReport, settings: PanelSettings, actions: PanelActions) {
        self.init(report: report, settings: settings, actions: actions, preload: true)
    }

    /// preload：截图渲染模式（ImageRenderer 不跑 onAppear），把各后台快照直接塞进初始状态。
    init(report: ScanReport, settings: PanelSettings, actions: PanelActions, preload: Bool, drill: String? = nil) {
        Self.migrateTabSelection()
        _report = State(initialValue: report)
        self.actions = actions
        if preload {
            _accountQuotas = State(initialValue: actions.accountQuotas())
            _accountLedgerError = State(initialValue: actions.accountLedgerError())
            _history = State(initialValue: UsageHistory.shared.snapshot())
            _network = State(initialValue: NetworkScanner.shared.snapshot())
            _health = State(initialValue: NerfDetector.shared.snapshot())
            _drillDown = State(initialValue: drill)
        }
        _autoCleanOn = State(initialValue: settings.autoClean)
        _launchAtLoginOn = State(initialValue: settings.launchAtLogin)
        _notifyOn = State(initialValue: settings.thresholdNotify)
        _exitNotifyOn = State(initialValue: settings.exitChangeNotify)
        _fontScaleOn = State(initialValue: settings.fontScale)
    }

    /// 旧索引 2 是系统页；只迁移一次，之后用户主动选择统计页不会被改回去。
    static func migrateTabSelection(defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: "vg.fiveTabsMigrated") {
            if defaults.integer(forKey: "vg.tab") == 2 { defaults.set(4, forKey: "vg.tab") }
            defaults.set(true, forKey: "vg.fiveTabsMigrated")
        }
        // 隐藏 API 页时，别把选择停在一个不存在的分段上。
        let showsAPI = (defaults.object(forKey: "vg.showAPITab") as? Bool) ?? true
        if !showsAPI, defaults.integer(forKey: "vg.tab") == 1 { defaults.set(0, forKey: "vg.tab") }
    }

    private var displayCurrency: DisplayCurrency { DisplayCurrency(rawValue: currencyKey) ?? .usd }
    private var availableAccountQuotas: [AccountQuotaObservation] {
        accountQuotas.isEmpty ? AccountUsage.quotaObservations(report: report) : accountQuotas
    }
    private var accountCards: [AccountPresentation] {
        AccountPresentation.currentCards(usage: history.accountUsage, quotas: availableAccountQuotas,
                                         presence: report.accountPresence, now: nowTS)
    }
    private var historicalAccountCards: [AccountPresentation] {
        AccountPresentation.cards(usage: history.accountUsage, quotas: availableAccountQuotas, now: nowTS)
    }
    private var allAccountCards: [AccountPresentation] {
        let currentIDs = Set(accountCards.map(\.id))
        return accountCards + historicalAccountCards.filter { !currentIDs.contains($0.id) }
    }
    private var unconfirmedLogins: [AccountPresence] {
        AccountPresentation.latestPresence(report.accountPresence).filter {
            if !AccountPresentation.isCurrent($0, now: nowTS) { return true }
            if $0.state == .unknown { return true }
            return $0.state == .loggedIn && !$0.isIdentifiedLogin && $0.method != "apiKey" && $0.method != "external"
        }
    }
    private func moneyText(_ values: [String: Double]) -> String {
        MoneyDisplay.format(values, mode: displayCurrency, quote: exchangeRates.quote).text
    }
    private var nowTS: TimeInterval { liveNow.timeIntervalSince1970 }
    private var currentTokens: TokenStats { report.tokens }
    private var currentLLMs: [DetectedLLMRuntime] { report.detectedLLMs }
    private var currentAPI: ProxyStatus { report.api }
    private var currentCLI: [CLIUsage] { report.cliUsage }
    private var currentInteractions: [InteractionRecord] { Array(currentTokens.recentInteractions.prefix(3)) }

    /// 当前设备作用域（存储值 + 已配置主机名做一次回落，主机被删也不锁死在空视图）。
    private var deviceScope: DeviceScope { DeviceScope.from(key: deviceKey).resolved(hosts: report.remoteHosts) }
    private var isRemoteScope: Bool { if case .remote = deviceScope { return true }; return false }
    private var scopedForecasts: [String: CostForecast] {
        deviceScope == .all ? history.forecasts : history.forecastsByDevice[deviceScope.key] ?? [:]
    }
    private var scopedUnpricedCount: Int {
        Set(history.unpricedNamesBySource.filter {
            !UsageHistory.isProxySource($0.key) && DeviceScope.includes(source: $0.key, scope: deviceScope, hosts: report.remoteHosts)
        }.values.flatMap { $0 }).count
    }

    private func includesHistorySource(_ source: String) -> Bool {
        !UsageHistory.isProxySource(source) && DeviceScope.includes(source: source, scope: deviceScope, hosts: report.remoteHosts)
    }

    private var scopedHistoryTotals: UsageHistory.Totals {
        guard deviceScope != .all else { return history.aggregate }
        return history.totals.filter { includesHistorySource($0.key) }
            .values.reduce(into: UsageHistory.Totals()) { $0.merge($1) }
    }

    private var scopedHistoryCost: [String: Double] {
        history.costBySource.filter { includesHistorySource($0.key) }
            .values.reduce(into: [String: Double]()) { result, currencies in
                for (currency, value) in currencies { result[currency, default: 0] += value }
            }
    }

    private var retainedHistoryNote: String? {
        let cachedSources = history.sourceNotes.keys.filter {
            UsageHistory.device(of: $0) != nil && history.totals[$0] != nil &&
                DeviceScope.includes(source: $0, scope: deviceScope, hosts: report.remoteHosts)
        }
        return cachedSources.isEmpty ? nil : L("含远端缓存；刷新状态见统计页", "Includes retained remote history; see Statistics for refresh status")
    }

    /// 与费用采用同一份当日记录，包含归档会话及远程设备。
    private var todayCLICandidates: [CLIUsage] {
        DeviceScope.todayUsage(local: currentCLI, history: history.currentDaySources(), scope: deviceScope,
                               historyReady: history.capturedAt > 0)
    }

    /// 今日 token（ctx+out）最多的 CLI；都为空就退回第一个。
    private var busiestTodayCLI: CLIUsage? {
        let list = todayCLICandidates
        return list.filter { $0.hasTokens }.max { ($0.ctx + $0.out) < ($1.ctx + $1.out) } ?? list.first
    }

    /// 手动选中的 CLI；选了但不在候选里（换设备/换主机）→ 自动跟随最忙的那个。
    private var selectedTodayCLI: CLIUsage? {
        if !todayCLIKey.isEmpty, let picked = todayCLICandidates.first(where: { $0.name == todayCLIKey }) { return picked }
        return busiestTodayCLI
    }

    /// Claude Code 专属的「按项目 / 最近交互」只在本地且选中 Claude Code 时出现。
    private var showClaudeExtras: Bool { deviceScope == .local && selectedTodayCLI?.name == "Claude Code" }

    /// API 上游 → 复用平台卡片：档位 = 套餐名或 "API Key"，额度条 / 余额 / 今日 token 叠加
    private var apiCards: [DetectedLLMRuntime] {
        currentAPI.providers.map { p in
            var tokens = ""
            if p.calls > 0 {
                let models = p.models.prefix(2).joined(separator: " / ") + (p.models.count > 2 ? " …" : "")
                tokens = L("\(models) · 上下文 \(formatTokens(p.ctx)) · 输出 \(formatTokens(p.out))", "\(models) · input \(formatTokens(p.ctx)) · output \(formatTokens(p.out))") + (p.ctx > 0 ? String(format: L(" · 命中 %.0f%%", " · cache %.0f%%"), p.cacheHitRate) : "")
            }
            // 上游在真实调用里给了限流头 → 拿来当余量显示（被动，不额外发请求）
            var headerLine = ""
            if let hw = p.headerWindow {
                let pct = hw.effectivePct(now: nowTS)
                headerLine = L("限流 \(p.headerLabel) 已用 \(pct)%", "Rate limit \(p.headerLabel) · \(pct)% used")
                if let c = UIFormat.countdown(to: hw.resetsAt, now: nowTS) { headerLine += L(" · 重置 \(c)", " · resets in \(c)") }
            }
            let sub: String
            if !headerLine.isEmpty, p.balanceText.isEmpty, p.fiveHour == nil { sub = headerLine }
            else if !p.balanceText.isEmpty { sub = p.balanceText }
            else if !p.quotaError.isEmpty { sub = L("额度: ", "Quota: ") + String(p.quotaError.prefix(24)) }   // 如"当前用户不存在coding plan"
            else { sub = p.calls > 0 ? L("无额度接口 · 只记调用", "No quota API · requests only") : L("今日无调用", "No requests today") }

            // 第四行：延迟 + 错误 + 花费，都从记账文件里已有的字段算，没有就不写
            var obs: [String] = []
            if p.p95ms > 0 { obs.append("p50 \(Fmt.ms(p.p50ms)) · p95 \(Fmt.ms(p.p95ms))") }
            if p.errors > 0 { obs.append(String(format: L("%d 错(%.0f%%)", "%d errors (%.0f%%)"), p.errors, p.errorRate) + (p.count429 > 0 ? L(" 含 \(p.count429) 限流", " including \(p.count429) rate limits") : "")) }
            if !p.cost.isEmpty { obs.append(Fmt.money(p.cost)) }
            return DetectedLLMRuntime(
                name: p.provider, isRunning: nowTS - p.lastTS < 120, tier: p.plan.isEmpty ? "API Key" : p.plan, detail: L("\(p.calls) 次", "\(p.calls) requests"),
                fiveHour: p.fiveHour, sevenDay: p.sevenDay, quotaSubtitle: sub,
                extraLine: tokens, extraLine2: obs.joined(separator: " · "),
                quotaNote: p.quotaIsEstimate ? L("估算 · ", "Estimate · ") + p.estimateNote : "",
                platformDetail: apiDetail(p)
            )
        }
    }

    /// API 上游的详情页：把记账文件能证明的都列出来（延迟分位 / 错误 / 按 key 分账 / 模型）
    private func apiDetail(_ p: APIProviderStatus) -> PlatformDetail {
        var d = PlatformDetail()
        d.rows.append((L("上游主机", "Upstream host"), p.host))
        if !p.plan.isEmpty { d.rows.append((L("套餐", "Plan"), p.plan)) }
        d.rows.append((L("今日调用", "Requests today"), L("\(p.calls) 次", "\(p.calls) requests")))
        if p.p95ms > 0 {
            d.rows.append((L("延迟 p50 / p95", "Latency p50 / p95"), "\(Fmt.ms(p.p50ms)) / \(Fmt.ms(p.p95ms))"))
            d.rows.append((L("最慢一次", "Slowest request"), Fmt.ms(p.maxms)))
        }
        d.rows.append((L("错误率", "Error rate"), p.calls > 0 ? String(format: L("%.1f%%（%d / %d）", "%.1f%% (%d / %d)"), p.errorRate, p.errors, p.calls) : "—"))
        if p.count429 > 0 { d.rows.append((L("429 限流", "429 rate limits"), L("\(p.count429) 次", "\(p.count429) times"))) }
        if p.ctx > 0 {
            d.rows.append((L("输入 / 输出", "Input / output"), "\(formatTokens(p.ctx)) / \(formatTokens(p.out))"))
            d.rows.append((L("缓存命中", "Cache hits"), String(format: L("%.0f%%（读 %@）", "%.0f%% (%@ read)"), p.cacheHitRate, formatTokens(p.cacheRead))))
        }
        if p.quotaIsEstimate {
            d.rows.append((L("额度口径", "Quota basis"), L("估算：本机记账请求数 ÷ 套餐上限", "Estimate: recorded requests ÷ plan limit")))
            d.rows.append((L("套餐上限", "Plan limit"), p.planLimitText))
            d.rows.append((L("估算底数", "Estimate basis"), p.estimateNote))
            d.rows.append((L("注意", "Note"), L("走代理之外的调用算不进来，会偏低", "Requests outside the proxy are excluded; this may undercount")))
        }
        if let m = p.monthly {
            d.rows.append((L("月窗口", "Monthly window"), "\(m.effectivePct(now: nowTS))%" + (UIFormat.countdown(to: m.resetsAt, now: nowTS).map { L(" · 重置 \($0)", " · resets in \($0)") } ?? "")))
        }
        if !p.cost.isEmpty {
            d.rows.append((L("今日花费（估）", "Cost today (estimate)"), Fmt.money(p.cost) + (currentAPI.priceAsOf.isEmpty ? "" : L(" · 价目表 \(currentAPI.priceAsOf)", " · rates as of \(currentAPI.priceAsOf)"))))
        } else if p.calls > 0 {
            d.rows.append((L("今日花费", "Cost today"), currentAPI.hasPriceTable ? L("该模型不在价目表里", "Model not in price table") : L("未配置价目表", "No price table configured")))
        }
        if let hw = p.headerWindow {
            var v = L("已用 \(hw.effectivePct(now: nowTS))%（按 \(p.headerLabel)）", "\(hw.effectivePct(now: nowTS))% used (\(p.headerLabel))")
            if let c = UIFormat.countdown(to: hw.resetsAt, now: nowTS) { v += L(" · 重置 \(c)", " · resets in \(c)") }
            if let age = hw.ageSeconds(now: nowTS) { v += L(" · 取自 \(UIFormat.agoShort(age))的调用", " · sampled \(UIFormat.agoShort(age))") }
            d.rows.append((L("限流余量（响应头）", "Rate limit (response headers)"), v))
        }
        if !p.models.isEmpty { d.rows.append((L("模型", "Models"), p.models.joined(separator: ", "))) }
        if !p.balanceText.isEmpty { d.rows.append((L("余额", "Balance"), p.balanceText)) }
        if !p.quotaError.isEmpty { d.rows.append((L("额度接口", "Quota API"), p.quotaError)) }
        for k in p.keys {
            var v = L("\(k.calls) 次", "\(k.calls) requests")
            if k.errors > 0 { v += L(" · \(k.errors) 错", " · \(k.errors) errors") }
            if k.ctx > 0 { v += " · \(formatTokens(k.ctx))→\(formatTokens(k.out))" }
            if !k.cost.isEmpty { v += " · " + Fmt.money(k.cost) }
            d.rows.append(("key \(k.fingerprint)", v))
        }
        d.sourceFiles = ["~/.config/vibedeck/api-calls.jsonl", "~/.config/vibedeck/api-quota.json"]
        if currentAPI.hasPriceTable { d.sourceFiles.append("~/.config/vibedeck/prices.json") }
        if p.quotaIsEstimate { d.sourceFiles.append("~/.config/vibedeck/plans.json") }
        return d
    }

    private func secondsAgo(_ timestamp: TimeInterval) -> Int {
        max(0, Int(nowTS - timestamp))
    }

    private func isRecentInteraction(timestamp: TimeInterval) -> Bool {
        secondsAgo(timestamp) < 120
    }

    private func tierColor(_ tier: String) -> Color { .secondary }

    private var thermalStateLabel: String {
        switch report.thermalStateString {
        case "正常": return L("正常", "Normal")
        case "微热": return L("微热", "Warm")
        case "较高 (可能降频)": return L("较高 (可能降频)", "High (may throttle)")
        case "严重过热": return L("严重过热", "Critical")
        default: return report.thermalStateString
        }
    }

    /// 0% 绿 → 100% 红 连续渐变。平方让曲线后段变色更快：
    /// 50% 已是黄绿、70% 黄、85% 橙、95%+ 红 —— 旧版"除了 100% 全是绿"没有识别度。
    /// 饱和度/亮度固定，深浅色模式下都能看清。
    private func quotaColor(_ pct: Int) -> Color { VG.heat(pct) }

    private struct ModelDisplayGroup: Identifiable {
        let id: String
        let isFullWidth: Bool
        let models: [DetectedLLMRuntime]
    }

    private var modelDisplayGroups: [ModelDisplayGroup] {
        var groups: [ModelDisplayGroup] = []
        var currentRegular: [DetectedLLMRuntime] = []

        for llm in currentLLMs {
            if llm.isFullWidth {
                if !currentRegular.isEmpty {
                    groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
                    currentRegular = []
                }
                groups.append(ModelDisplayGroup(id: "full-\(llm.id)", isFullWidth: true, models: [llm]))
            } else {
                currentRegular.append(llm)
            }
        }
        if !currentRegular.isEmpty {
            groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
        }
        return groups
    }

    private func formatTokensInt(_ count: Int) -> String {
        formatTokens(Int64(count))
    }

    private func refreshLive() {
        guard actions.isVisible() else { return }
        if tab == 4 { refreshMountAvailability() }
        // 只读缓存，避免与常驻 8 秒采集重复执行文件遍历、ps 和 API 汇总。
        accountLedgerError = actions.accountLedgerError()
        let latestQuotas = actions.accountQuotas()
        if latestQuotas != accountQuotas { accountQuotas = latestQuotas }
        let latestNetwork = NetworkScanner.shared.snapshot()
        if network != latestNetwork { network = latestNetwork }
        let latestHistory = UsageHistory.shared.snapshot()
        if history.capturedAt != latestHistory.capturedAt || history.isScanning != latestHistory.isScanning ||
           history.processedFiles != latestHistory.processedFiles || history.totalFiles != latestHistory.totalFiles { history = latestHistory }
        let latestHealth = NerfDetector.shared.snapshot()
        if health.capturedAt != latestHealth.capturedAt { health = latestHealth }
        if let latest = actions.latestReport(), latest.capturedAt != report.capturedAt {
            report = latest
        }
    }

    /// A disconnected mount can stall stat(); the view only reads the last result.
    private func refreshMountAvailability() {
        guard actions.isVisible(), !mountCheckPending else { return }
        let mounts = UsageHistory.mountRoots()
        guard !mounts.isEmpty else { return }
        mountCheckPending = true
        DispatchQueue.global(qos: .utility).async {
            var available: [String: Bool] = [:]
            for mount in mounts { available[mount.path] = FileManager.default.fileExists(atPath: mount.path) }
            DispatchQueue.main.async {
                guard actions.isVisible() else { return }
                mountAvailability = available
                mountCheckPending = false
            }
        }
    }

    /// A freshly swapped page first measures short (charts and grids have not laid out yet), then reports its
    /// real height. Applying both made the popover drop and spring back. Only apply a height that has held
    /// for a moment; growth to a larger settled value is applied the same way.
    private func settleHeight(_ height: CGFloat) {
        guard abs(height - measuredHeight) > 1 else { heightGeneration &+= 1; return }
        heightGeneration &+= 1
        let generation = heightGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard generation == heightGeneration, abs(height - measuredHeight) > 1 else { return }
            measuredHeight = height
        }
    }

    private var contentHeightLimit: CGFloat {
        max(120, Self.maxPanelHeight - panelChromeHeight)
    }

    /// Keep the footer as quiet native menu commands; sizing lives in Settings.
    private var footerBar: some View {
        HStack(spacing: 8) {
            if refreshPending {
                Text(L("正在刷新…", "Refreshing…")).foregroundStyle(.secondary)
            } else if health.status >= .watch {
                Button(action: openHealth) {
                    Label(L("模型检查有提醒", "Model checks need attention"), systemImage: "exclamationmark.triangle")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            } else {
                Text(history.capturedAt > 0 ? (nowTS - history.capturedAt < 5 ? L("刚刚更新", "Updated just now") : L("更新于", "Updated ") + UIFormat.agoShort(max(0, Int(nowTS - history.capturedAt)))) : L("正在采集…", "Collecting…"))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Menu {
                Button(L("模型检查…", "Model checks…"), action: openHealth)
                Button(L("模型价格…", "Model prices…"), action: openPrices)
                Button(L("Codex 进程…", "Codex processes…")) { openDetail(Self.processesPage) }
                Divider()
                Button(L("退出 VibeDeck", "Quit VibeDeck"), action: actions.quit).keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 16)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("更多操作", "More actions")).accessibilityLabel(L("更多操作", "More actions"))
            .accessibilityIdentifier("panel.more")
        }.font(VG.caption)
    }

    private let gridCols = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    // MARK: - 外壳

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar

            // 设备切换放在统计页内容里：顶栏高度在各 Tab 间保持不变，切 Tab 时面板只改一次高度，不会先掉再弹。

            SwipeScroll(
                content: tabContent.frame(width: Self.panelWidth - 24, alignment: .leading),
                onSwipe: { step in
                    guard drillDown == nil else { return }   // 详情页里不响应滑动，只用「返回」按钮
                    let visible = showAPITab ? [0, 1, 2, 3, 4] : [0, 2, 3, 4]
                    guard let current = visible.firstIndex(of: tab) else { tab = 0; return }
                    let next = max(0, min(visible.count - 1, current + step))
                    if visible[next] != tab { tab = visible[next] }
                },
                onHeight: { h in settleHeight(h) }
            )
            // A new page gets a fresh clip view. Otherwise NSScrollView carries the previous page's
            // scroll origin into Back/Tab navigation and hides the new page's first controls.
            .id("\(tab):\(drillDown ?? "overview")")
            .frame(width: Self.panelWidth - 24, height: min(max(measuredHeight, 120), contentHeightLimit))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightPreference.self, value: ["viewport": geometry.size.height])
            })

            footerBar
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, AppLanguage.current.locale)
        .id("\(languageKey)-\(fontScaleOn)")
        .background(ambient)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { MenuMaterial() }
        }
        .animation(nil, value: drillDown)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightPreference.self, value: ["panel": geometry.size.height])
        })
        .onPreferenceChange(PanelHeightPreference.self) { sizes in
            guard let height = sizes["panel"], let viewport = sizes["viewport"],
                  height.isFinite, viewport.isFinite, height > 0, viewport > 0 else { return }
            let chrome = max(0, height - viewport)
            DispatchQueue.main.async {
                if abs(chrome - panelChromeHeight) > 1 { panelChromeHeight = chrome }
                actions.panelHeightChanged(height)
            }
        }
        .onChange(of: tab) { _, _ in actions.relayout() }
        .onChange(of: showAPITab) { _, shown in
            if !shown, tab == 1 { tab = 0 }
            actions.relayout()
        }
        .onChange(of: measuredHeight) { _, _ in actions.relayout() }
        .onChange(of: languageKey) { _, _ in actions.relayout() }
        .onChange(of: drillDown) { _, page in
            if page == nil { detailBackStack.removeAll() }
            actions.relayout()
        }
        .onReceive(liveTicker) { date in
            guard actions.isVisible() else { return }
            // Countdowns show minutes; re-rendering the whole panel every 5 s is what made it feel heavy.
            if Int(date.timeIntervalSince1970 / 30) != Int(liveNow.timeIntervalSince1970 / 30) { liveNow = date }
            refreshLive()
        }
        .onAppear {
            if !showAPITab, tab == 1 { tab = 0 }
            refreshLive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshVibeDeckPanel)) { _ in rescanAll() }
        .onReceive(NotificationCenter.default.publisher(for: .vibeDeckPanelReopened)) { _ in
            // A kept panel reopens on its top page with fresh snapshots, like a newly built one. Only real changes
            // are assigned, so an unchanged panel isn't re-rendered while it appears.
            if drillDown != nil { drillDown = nil }
            let now = Date()
            if Int(now.timeIntervalSince1970 / 30) != Int(liveNow.timeIntervalSince1970 / 30) { liveNow = now }
            refreshLive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectVibeDeckTab)) { note in
            guard let selected = note.object as? Int, (0..<5).contains(selected) else { return }
            drillDown = nil
            if !showAPITab, selected == 1 { tab = 0 } else { tab = selected }
        }
    }

    /// 顶栏：应用标识 + 当前页摘要 + 模型健康胶囊 + 刷新；下面一条整宽分段控件。详情页换成「返回」。
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let name = drillDown {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left").font(VG.body).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("返回", "Back")).accessibilityLabel(L("返回", "Back"))
                    .accessibilityIdentifier("navigation.back")
                    .keyboardShortcut("[", modifiers: .command)
                    Text(detailTitle(name)).font(VG.headline).lineLimit(1).truncationMode(.middle)
                } else {
                    // The same pup as the menu bar, in the brand gradient.
                    Image(nsImage: MenuBarPet.cachedImage(pose: .sit, alert: false, label: nil)).renderingMode(.template)
                        .resizable().interpolation(.high).frame(width: 26 * VG.scale, height: 22 * VG.scale)
                        .foregroundStyle(LinearGradient(colors: [Glass.money, Glass.moneyEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("VibeDeck").font(.system(size: 14 * VG.scale, weight: .bold, design: .rounded))
                    if [1, 3, 4].contains(tab) { Text(L("本机", "Local")).font(VG.caption).foregroundStyle(.tertiary) }
                }
                Spacer(minLength: 4)
                Button(action: rescanAll) {
                    if refreshPending { ProgressView().controlSize(.mini).frame(width: 16, height: 16) }
                    else { Image(systemName: "arrow.clockwise").font(VG.body).frame(width: 16, height: 20) }
                }
                .buttonStyle(.plain).disabled(refreshPending).foregroundStyle(.secondary)
                .help(L("刷新（⌘R）", "Refresh (⌘R)"))
                .accessibilityLabel(L("刷新", "Refresh")).accessibilityIdentifier("panel.refresh")
                settingsMenu
            }
            if drillDown == nil {
                GlassTabBar(items: tabItems, selection: $tab)
                    .help(L("⌘1–5 或左右滑动切换", "Switch with ⌘1–5 or swipe horizontally"))
            }
        }
    }
    private func detailTitle(_ name: String) -> String {
        if name == Self.healthPage { return L("模型检查", "Model checks") }
        if name == Self.devicesPage { return L("设备", "Devices") }
        if name == Self.pricesPage { return L("模型价格", "Model prices") }
        if name == Self.settingsPage { return L("设置", "Settings") }
        if name == Self.accountsPage { return L("当前登录账号", "Signed-in accounts") }
        if name == Self.accountHistoryPage { return L("历史账号记录", "Account history") }
        if name == Self.livePage { return L("实时与设备", "Live & devices") }
        if name == Self.apiPage { return L("API 与套餐", "API & plans") }
        if name == Self.processesPage { return L("Codex 进程", "Codex processes") }
        // Only account pages need the (expensive) card list; platform pages are titled by their name.
        guard name.hasPrefix("account:") else { return name }
        return allAccountCards.first { "account:" + $0.id == name }?.title ?? name
    }
    private var tabItems: [GlassTabBar.Item] {
        var items = [GlassTabBar.Item(id: 0, title: L("概览", "Overview"), symbol: "square.grid.2x2")]
        if showAPITab { items.append(.init(id: 1, title: "API", symbol: "key.horizontal")) }
        items += [.init(id: 2, title: L("统计", "Stats"), symbol: "chart.bar.xaxis"),
                  .init(id: 3, title: L("网络", "Network"), symbol: "globe"),
                  .init(id: 4, title: L("系统", "System"), symbol: "cpu")]
        return items
    }

    /// Each page tints the glass behind it with its own pair of hues.
    private var ambient: some View {
        let pair: (Color, Color) = {
            if drillDown != nil { return (Glass.money, Glass.moneyEnd) }
            switch tab {
            case 2: return (Glass.moneyEnd, Glass.disk)
            case 3: return (Glass.download, Glass.upload)
            case 4: return (Glass.cpu, Glass.memory)
            default: return (Glass.money, Glass.moneyEnd)
            }
        }()
        return AmbientBackdrop(primary: pair.0, secondary: pair.1)
            .opacity(reduceTransparency ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: tab)
    }

    private func tabButton(_ index: Int, _ title: String) -> some View {
        Button { tab = index } label: {
            Text(title).font(VG.caption.weight(tab == index ? .semibold : .regular))
                .foregroundStyle(tab == index ? Color.primary : .secondary)
                .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(tab == index ? Color(nsColor: .controlBackgroundColor) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("tab.\(index)")
        .accessibilityAddTraits(tab == index ? .isSelected : [])
    }

    /// Settings get their own page rather than stretching the current panel.
    private var settingsMenu: some View {
        Button {
            if drillDown == Self.settingsPage { goBack() } else { openDetail(Self.settingsPage) }
            actions.relayout()
        } label: {
            Image(systemName: drillDown == Self.settingsPage ? "gearshape.fill" : "gearshape").font(VG.body)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(drillDown == Self.settingsPage ? Color.accentColor : .secondary)
        .help(L("设置", "Settings"))
        .accessibilityLabel(L("设置", "Settings"))
        .accessibilityIdentifier("settings.open")
    }

    private var settingsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("字号", "Text Size")).font(VG.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(UITheme.presets, id: \.value) { preset in
                    Button {
                        fontScaleOn = preset.value
                        actions.setFontScale(preset.value)
                        actions.relayout()
                    } label: {
                        Text(preset.value == 1.3 ? L("特大", "XL") : preset.title)
                            .font(VG.caption).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(fontScaleOn == preset.value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityValue(fontScaleOn == preset.value ? L("已选", "Selected") : "")
                    .accessibilityIdentifier("settings.font.\(preset.value)")
                }
            }
            HStack(spacing: 6) {
                Text(L("语言", "Language")).font(VG.caption).foregroundStyle(.secondary)
                ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                    Button {
                        languageKey = language.rawValue
                    } label: {
                        Text(language.displayName).font(VG.caption).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(languageKey == language.rawValue ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(languageKey == language.rawValue ? L("已选", "Selected") : "")
                    .accessibilityIdentifier("settings.language.\(language.rawValue)")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .vgFill(0.04, radius: 7)
    }

    /// 截图用：顶栏 + 当前页内容，不含 NSScrollView（ImageRenderer 画不了 AppKit 视图）。
    var renderBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            tabContent.frame(width: Self.panelWidth - 24, alignment: .leading)
            footerBar
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .background(ambient)
    }

    static let healthPage = "__health"
    /// Screenshot-only page: the device switcher popover drawn inline (popovers don't render offscreen).
    static let devicesPage = "__devices"
    static let pricesPage = "__prices"
    static let settingsPage = "__settings"
    static let livePage = "__live"
    static let apiPage = "__api"
    static let processesPage = "__codex_processes"

    private func openDetail(_ page: String) {
        guard page != drillDown else { return }
        if let current = drillDown { detailBackStack.append(current) }
        drillDown = page
    }

    private func goBack() {
        drillDown = detailBackStack.popLast()
    }

    private func openHealth() {
        openDetail(Self.healthPage)
    }

    private func openPrices() {
        openDetail(Self.pricesPage)
    }

    private func rescanAll() {
        guard !refreshPending else { return }
        refreshPending = true
        actions.rescan()
        // Remote history can be slow; it must not disable local status/quota refreshes.
        if !UsageHistory.shared.snapshot().isScanning { UsageHistory.shared.refreshSoon() }
        actions.refreshHealth { report in
            self.health = report
            self.refreshPending = false
        }
    }

    /// 当前页内容（不含滚动容器）：面板里包在 SwipeScroll 里，渲染截图时直接用。
    @ViewBuilder
    var tabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected = drillDown, selected.hasPrefix("account:"),
               let card = allAccountCards.first(where: { "account:" + $0.id == selected }) {
                AccountDetailView(card: card, points: history.accountUsage.points,
                                  coverageStart: card.account.flatMap { history.accountUsage.coverageStartByAccount[$0.key] },
                                  capturedAt: history.capturedAt, now: nowTS,
                                  mode: displayCurrency, quote: exchangeRates.quote)
            } else if drillDown == Self.accountsPage {
                accountUsageList()
            } else if drillDown == Self.devicesPage {
                DevicePickerPanel(choices: deviceChoiceRows, selected: deviceScope.key) { deviceKey = $0 }
            } else if drillDown == Self.accountHistoryPage {
                accountUsageList(historyMode: true)
            } else if drillDown == Self.livePage {
                deviceSelectorRow
                OverviewStrip(snapshot: history, scope: deviceScope, hosts: report.remoteHosts, now: nowTS,
                              forecasts: scopedForecasts, capturedAt: history.capturedAt, unpricedCount: scopedUnpricedCount,
                              coverageNote: retainedHistoryNote, openStats: { drillDown = nil; tab = 2 }, openPrices: openPrices)
                todayContextBlock
                historySummaryRow
                if case .remote(let host) = deviceScope { remoteDeviceSection(host: host); todayUsageDetails }
                else { localAISection }
            } else if drillDown == Self.processesPage {
                CodexProcessDetailView(processes: report.codexProcesses, now: nowTS,
                                       observedDevices: report.codexProcessDevices, errors: report.codexProcessErrors)
            } else if drillDown == Self.apiPage {
                apiSection
            } else if drillDown == Self.healthPage {
                HealthDetailView(report: health, rescan: rescanAll)
            } else if drillDown == Self.pricesPage {
                PricingDetailView(history: history, syncPrices: actions.syncPrices)
            } else if drillDown == Self.settingsPage {
                settingsStrip
                devicesSettings
                settingsSection
            } else if let name = drillDown, let llm = (currentLLMs + apiCards).first(where: { $0.name == name }) {
                detailPage(for: llm)
            } else {
                switch tab {
                case 1:
                    apiSection
                case 2:
                    if !report.remoteHosts.isEmpty { deviceSelectorRow }
                    StatsTabView(snapshot: history, scope: deviceScope, hosts: report.remoteHosts)
                case 3:
                    NetworkTrafficTile(interface: network.local.interfaceName)
                    NetworkTabView(snapshot: network, onRetest: { NetworkScanner.shared.forceRefresh() }, width: Self.panelWidth - 24)
                case 4:
                    SystemVitalsView(report: report)
                    FanControlCard()
                    hardwareSection
                    diskSection
                    devicesSection
                default: aiSection
                }
            }
        }
    }

    // MARK: - 设备切换器

    private var deviceChoices: [(String, String)] {
        [(DeviceScope.all.key, L("全部设备", "All devices")), (DeviceScope.local.key, L("本机", "Local"))]
            + report.remoteHosts.map { (DeviceScope.remote($0).key, RemoteCollector.displayName(for: $0)) }
    }
    private var deviceScopeLabel: String { deviceChoices.first { $0.0 == deviceScope.key }?.1 ?? L("全部设备", "All devices") }
    /// Today's activity per device for the switcher: cost, tokens, hourly shape and reachability.
    private var deviceChoiceRows: [DeviceChoice] {
        let usage = history.accountUsage
        let cnyPerUSD = exchangeRates.quote?.cnyPerUSD ?? 7.2
        var remoteIndex = 0
        return deviceChoices.map { key, title in
            let scope = DeviceScope.from(key: key)
            var costs: [String: Double] = [:], tokens: Int64 = 0, hourly = Array(repeating: 0.0, count: 24)
            for (source, totals) in usage.todayBySource where includesSource(source, scope: scope) {
                tokens += totals.usage.tokenTotal
                for (currency, value) in totals.equivalentCostByCurrency { costs[currency, default: 0] += value }
                for (currency, hours) in usage.todayHourlyBySource[source] ?? [:] {
                    let scale = currency == "CNY" ? 1 / cnyPerUSD : 1
                    for (hour, value) in hours.enumerated() where hour < 24 && value.isFinite { hourly[hour] += value * scale }
                }
            }
            let tokenText = tokens > 0 ? L(Fmt.tokens(tokens) + " token", String(format: "%.1fM tokens", Double(tokens) / 1e6)) : ""
            let kind: DeviceChoice.Kind, online: Bool?, status: String
            switch scope {
            case .all:
                kind = .all; online = nil; status = ""
            case .local:
                kind = .local; online = true; status = L("本机 · 在线", "This Mac · online")
            case .remote(let host):
                kind = .remote
                if let device = report.remoteDeviceStatus[host] {
                    if !device.error.isEmpty { online = false; status = L("连不上", "Unreachable") }
                    else if let success = device.lastSuccess {
                        online = true
                        status = L("在线 · ", "Online · ") + UIFormat.agoShort(max(0, Int(nowTS - success)))
                    } else { online = nil; status = L("等待首次同步", "Waiting for first sync") }
                } else { online = nil; status = L("挂载目录", "Mounted folder") }
            }
            let color = DeviceChoice.color(kind: kind, index: remoteIndex)
            if kind == .remote { remoteIndex += 1 }
            // One amount per row: mixed currencies fold through the reference rate (original amounts stay in Statistics).
            let mode: DisplayCurrency = displayCurrency == .original ? .usd : displayCurrency
            var cost = costs.isEmpty ? "—" : MoneyDisplay.format(costs, mode: mode, quote: exchangeRates.quote).text
            if costs.count > 1, exchangeRates.quote?.isUsable() != true {
                // No current rate: fold with the default one, marked approximate, so the row still reads as one number.
                let usd = costs.reduce(0.0) { $0 + ($1.key == "CNY" ? $1.value / cnyPerUSD : $1.value) }
                cost = "≈" + (mode == .cny ? MoneyDisplay.amount(usd * cnyPerUSD, currency: "CNY") : MoneyDisplay.amount(usd, currency: "USD"))
            }
            return DeviceChoice(id: key, title: title, kind: kind, online: online, status: status,
                                cost: cost, tokens: tokens, tokenText: tokenText, hourly: hourly, color: color)
        }
    }

    private func includesSource(_ source: String, scope: DeviceScope) -> Bool {
        !UsageHistory.isProxySource(source) && DeviceScope.includes(source: source, scope: scope, hosts: report.remoteHosts)
    }

    private var deviceScopeMenu: some View {
        let rows = deviceChoiceRows
        let current = rows.first { $0.id == deviceScope.key }
        return Button { devicePickerShown.toggle() } label: {
            GlassChipLabel(icon: current?.symbol ?? "square.stack.3d.up", text: deviceScopeLabel, tint: current?.color)
        }
        .buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
        .popover(isPresented: $devicePickerShown, arrowEdge: .bottom) {
            DevicePickerPanel(choices: rows, selected: deviceScope.key) { key in
                deviceKey = key
                devicePickerShown = false
            }
        }
        .help(L("选择用量设备；账号额度保持合并", "Choose usage devices; account quotas stay merged"))
        .accessibilityIdentifier("usage.device")
        .onChange(of: deviceKey) { _, _ in actions.relayout() }
    }
    private var deviceSelectorRow: some View {
        HStack { Text(L("设备用量", "Device usage")).font(VG.caption).foregroundStyle(.secondary); Spacer(minLength: 8); deviceScopeMenu }
    }

    // MARK: - Tab 系统：物理硬件 + MCP/NPX

    private var hardwareSection: some View {
        DisclosureGroup {
            VStack(spacing: 7) {
                VGKeyValue(key: L("可用内存", "Memory available"), value: report.totalMemoryGB > 0 ? "\(report.freePercentage)%" : "—")
                VGKeyValue(key: L("压缩内存", "Compressed"), value: String(format: "%.2f GB", report.compressorGB))
                VGKeyValue(key: "Swap", value: String(format: "%.2f GB", report.swapUsedGB))
                VGKeyValue(key: L("负载 1m / 5m", "Load 1m / 5m"), value: String(format: "%.2f / %.2f", report.loadAvg1m, report.loadAvg5m))
                VGKeyValue(key: L("热状态", "Thermal state"), value: thermalStateLabel,
                           valueColor: report.thermalStateString == "正常" ? .primary : .orange)
                VGKeyValue(key: L("磁盘容量", "Disk capacity"), value: report.diskTotalGB > 0 ? String(format: "%.1f GB", report.diskTotalGB) : "—")
                VGKeyValue(key: L("活跃 MCP", "Active MCP"), value: L("\(report.activeMCPProcessCount) 进程 · \(Int(report.activeMCPTotalMemMB)) MB", "\(report.activeMCPProcessCount) processes · \(Int(report.activeMCPTotalMemMB)) MB"))
                VGKeyValue(key: L("NPX 缓存", "NPX cache"), value: report.npxCacheKnown ? sizeText(report.npxCacheMB) : report.npxCachePending ? L("计算中…", "Calculating…") : "—")
                ForEach(report.orphanedGroups) { group in
                    VGKeyValue(key: group.serviceName, value: L("\(group.processCount) 个孤儿 · \(Int(group.totalMemMB)) MB", "\(group.processCount) orphaned · \(Int(group.totalMemMB)) MB"), valueColor: .orange)
                }
            }.padding(.top, 6)
        } label: {
            HStack {
                Text(L("进程与缓存", "Processes & caches")).font(VG.body)
                Spacer(minLength: 4)
                if report.totalOrphanCount > 0 {
                    Text(L("\(report.totalOrphanCount) 个断链进程", "\(report.totalOrphanCount) orphaned")).font(VG.caption).foregroundStyle(.orange)
                } else {
                    Text(L("MCP \(report.activeMCPProcessCount)", "MCP \(report.activeMCPProcessCount)")).font(VG.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.secondary)
    }

    // MARK: - Tab 订阅：平台矩阵 + 今日 Token + 最近交互

    /// Daily activity comes first; account quotas stay global while usage follows the device menu.
    private var aiSection: some View {
        let order = ["Claude", "Codex"]
        // Built once per render: each access of accountCards merges and sorts every quota and usage group again.
        let accountCards = self.accountCards
        let readable = accountCards.enumerated().sorted { a, b in
            let ta = a.element.title.components(separatedBy: " · ").first ?? "", tb = b.element.title.components(separatedBy: " · ").first ?? ""
            let ia = order.firstIndex(of: ta) ?? order.count, ib = order.firstIndex(of: tb) ?? order.count
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        let count = VG.scale > 1.1 ? 4 : 6
        // Identified accounts that reported a quota in the last 6 hours but whose sign-in is not confirmed right now
        // (device offline, or the scan is still catching up) are appended dimmed and marked unconfirmed. They are
        // never counted as confirmed sign-ins; confirmed accounts always come first.
        let confirmedIDs = Set(accountCards.map(\.id))
        let pending = historicalAccountCards.filter { card in
            !confirmedIDs.contains(card.id) && card.account != nil &&
                card.currentQuotas(at: nowTS).contains { nowTS - $0.capturedAt <= 6 * 3600 }
        }
        // Subscription plans without a sign-in identity (Grok / GLM / Gemini) join the same ring grid.
        let plans = PlanQuota.collect(local: currentLLMs, remote: report.remoteLLMs, now: nowTS)
        let planCards = plans.map(\.card)
        let visible = Array((readable + pending).prefix(count)) + planCards
        let pendingIDs = Set(pending.map(\.id))
        let fullValue = fullValueTexts(visible)
        return VStack(alignment: .leading, spacing: 6) {
            TodayHeroTile(snapshot: history, scope: deviceScope, hosts: report.remoteHosts, now: nowTS,
                          mode: displayCurrency, quote: exchangeRates.quote,
                          openStats: { tab = 2 }, openLive: { openDetail(Self.livePage) }) {
                HStack(spacing: 8) { deviceScopeMenu; currencyPicker }
            }
            FirstTokenStrip(snapshot: history, hosts: report.remoteHosts, now: nowTS, open: { openDetail(Self.livePage) })
            HStack(spacing: 6) {
                Text(L("订阅", "Subscriptions")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                VGInfoButton(title: L("订阅额度", "Subscription quotas"),
                             text: L("Grok / GLM / Gemini 订阅取各设备里最近一次读到的额度（GLM 按 key 指纹合并）；Gemini 没有可读的额度接口时显示「暂不可读」。「满额」学 sub2api 的算法：取这个额度窗口最近几小时的采样，用这段时间的请求按 API 价折算的花费 ÷ 额度涨了几个百分点，至少涨 3 个点才算，是估算。账号数只统计设备当前确认登录的订阅账号，同一账号跨设备合并。历史账号不计入；设备暂时联系不上时，最近 6 小时有额度的账号以淡色加 ? 显示，不计入账号数。外环为周额度，内环为 5 小时额度，均表示已用。", "Grok / GLM / Gemini use the most recent quota read on any device (GLM merged by key fingerprint); Gemini shows “not readable” without a quota source. “Full” follows sub2api: API-priced spend since the window’s oldest recent sample ÷ the points used, once it has moved at least 3 points; an estimate. Only currently confirmed subscription logins are counted, deduplicated across devices. Historical accounts are excluded; while a device is unreachable, accounts with quota in the last 6 h are shown dimmed with ? and not counted. Outer ring: weekly quota used. Inner ring: 5-hour quota used."))
                if let error = accountLedgerError {
                    Image(systemName: "exclamationmark.triangle").font(VG.caption).foregroundStyle(.orange)
                        .help(L("周期记录读写失败：", "Cycle history unavailable: ") + error)
                }
                Spacer()
                Button { openDetail(Self.accountsPage) } label: {
                    HStack(spacing: 3) {
                        Text(L("\(accountCards.count) 个账号", "\(accountCards.count) accounts"))
                        if !unconfirmedLogins.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(L("\(unconfirmedLogins.count) 待确认", "\(unconfirmedLogins.count) unconfirmed"))
                        }
                        Image(systemName: "chevron.right")
                    }.font(VG.caption).foregroundStyle(.secondary).monospacedDigit().contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("accounts.all")
                    .help(L("当前登录账号与设备确认状态", "Current logins and device confirmation status"))
            }
            .padding(.horizontal, 2)
            AccountQuotaGrid(cards: visible, now: nowTS, unconfirmedIDs: pendingIDs, fullValue: fullValue, open: { id in
                if id.hasPrefix("plan:"), let plan = plans.first(where: { "plan:" + $0.id == id }) {
                    if currentLLMs.contains(where: { $0.name == plan.runtimeName }) { openDetail(plan.runtimeName) }
                } else { openDetail("account:" + id) }
            })
            APIQuotaSection(providers: currentAPI.providers, dshBalance: UsageHistory.dshBalance,
                            plans: plans, now: nowTS,
                            openAPI: { if showAPITab { tab = 1 } else { openDetail(Self.apiPage) } })
            // Machine-state rows share one quiet style at the bottom: processes, then vitals.
            VStack(spacing: 5) {
                CodexProcessSummary(processes: report.codexProcesses, now: nowTS, open: { openDetail(Self.processesPage) })
                VitalsStrip(openSystem: { tab = 4 }, openNetwork: { tab = 3 })
            }
            .padding(.top, 2)
        }
    }

    /// sub2api-style "whole quota is worth" per tile, from the window that moved the most since its baseline.
    private func fullValueTexts(_ cards: [AccountPresentation]) -> [String: String] {
        var out: [String: String] = [:]
        // Baselines are at most 6 h old, so only recent points matter; deduplicate those once for every tile.
        let cutoff = nowTS - 7 * 3600
        let recent = AccountUsage.deduplicated(history.accountUsage.points.filter { $0.timestamp >= cutoff })
        for card in cards {
            let candidates = card.currentQuotas(at: nowTS).compactMap { q -> (AccountQuotaObservation, [String: Double])? in
                AccountUsage.recentCapacity(q, points: recent).map { (q, $0) }
            }
            guard let (q, value) = candidates.max(by: { ($0.0.usedPercent - ($0.0.baselinePercent ?? 0)) < ($1.0.usedPercent - ($1.0.baselinePercent ?? 0)) })
            else { continue }
            out[card.id] = "≈" + moneyText(value) + " / " + (q.window == "week" ? L("周", "wk") : q.window)
        }
        return out
    }

    private static let accountsPage = "__accounts__"
    private static let accountHistoryPage = "__account_history__"
    private var currencyPicker: some View {
        Menu {
            ForEach(DisplayCurrency.allCases, id: \.rawValue) { currency in
                Button { currencyKey = currency.rawValue } label: {
                    if currency.rawValue == currencyKey { Label(currency.label, systemImage: "checkmark") }
                    else { Text(currency.label) }
                }
            }
        } label: {
            GlassChipLabel(icon: "dollarsign.arrow.circlepath", text: displayCurrency.label)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("usage.currency")
        .help(exchangeRates.quote?.isUsable() == true ? L("参考汇率只改变显示，不改变原始费用", "Reference conversion changes display only") : L("没有可用参考汇率，保留原币金额", "No current reference rate; showing original currencies"))
    }
    private func accountUsageList(historyMode: Bool = false) -> some View {
        let cards = historyMode ? historicalAccountCards : accountCards
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(L("API 等价用量", "API-equivalent usage")).font(VG.caption).foregroundStyle(.secondary); Spacer(); currencyPicker }
            ForEach(cards) { card in
                Button { openDetail("account:" + card.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(card.title).font(VG.headline).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(card.usage.map { moneyText($0.totals.equivalentCostByCurrency) } ?? "—").font(VG.body).monospacedDigit()
                            Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.secondary)
                        }
                        Text(card.account == nil ? L("未归属 · 保留原始记录", "Unassigned · original records retained") : card.sources.map { AccountPresentation.sourceLabel($0) }.joined(separator: " / "))
                            .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            if cards.isEmpty {
                Text(historyMode ? L("暂无历史账号记录", "No account history") : L("暂无已确认登录的账号", "No confirmed signed-in accounts"))
                    .font(VG.body).foregroundStyle(.secondary)
            }
            if !historyMode {
                if !unconfirmedLogins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("登录待确认", "Sign-ins to confirm")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(unconfirmedLogins) { login in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(login.tool + " · " + (login.deviceID == "local" ? L("本机", "Local") : RemoteCollector.displayName(for: login.deviceID)))
                                        .font(VG.body)
                                    Text(AccountPresentation.isCurrent(login, now: nowTS) ? login.basis.label : L("登录状态已过期，等待设备更新", "Login status is old; waiting for the device"))
                                        .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Text(AccountPresentation.isCurrent(login, now: nowTS) && login.state == .loggedIn ? L("已登录 · 标识未知", "Signed in · ID unknown") : L("待确认", "Unconfirmed"))
                                    .font(VG.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }.padding(.vertical, 6)
                }
                Button { openDetail(Self.accountHistoryPage) } label: {
                    HStack {
                        Label(L("历史账号与未归属记录", "Historical & unassigned records"), systemImage: "clock")
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                    }.font(VG.body).foregroundStyle(.secondary).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("accounts.history")
            }
        }
    }

    private var historySummaryRow: some View {
        let tokens = history.capturedAt > 0 ? formatTokens(scopedHistoryTotals.tokenTotal) : "—"
        let cost = scopedHistoryCost
        let costText = cost.isEmpty ? L("未定价", "Unpriced") : moneyText(cost)
        return HStack(spacing: 6) {
            Button { tab = 2 } label: {
                HStack(spacing: 6) {
                    Text(L("历史累计", "History")).foregroundStyle(.secondary)
                    Text(L("\(tokens) token", "\(tokens) tokens")).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                    Text(history.capturedAt > 0 ? costText : "—").monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.tertiary)
                }
                .font(VG.body).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("已采集历史 \(tokens) token · API 等价成本 \(costText)", "Collected history: \(tokens) tokens · API-equivalent cost \(costText)"))
            VGInfoButton(title: L("历史统计范围", "Historical coverage"),
                         text: usageCoverageText + "\n\n" + L("历史累计包含当前设备筛选下已采集的输入与输出；金额保留币种；换算采用带日期的参考汇率，未定价模型不计入费用。", "History includes collected input and output for the selected devices. Currency conversion uses a dated reference rate; unpriced models are excluded from costs."))
        }
    }

    private var localAISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            todayUsageDetails
            DisclosureGroup(L("本机平台详情", "Local platforms")) {
                VStack(spacing: 0) {
                    ForEach(currentLLMs) { runtime in
                        Button { openDetail(runtime.name) } label: {
                            HStack(spacing: 8) {
                                Text(runtime.name).font(VG.body)
                                Spacer(minLength: 4)
                                Text(UIFormat.tier(runtime.tier)).font(VG.caption).foregroundStyle(.secondary)
                                Circle().fill(runtime.isRunning ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 5, height: 5)
                                    .help(runtime.isRunning ? L("会话在线", "Session online") : L("空闲", "Idle"))
                                Image(systemName: "chevron.right").font(VG.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(VG.caption).foregroundStyle(.secondary)

            if showClaudeExtras && !currentInteractions.isEmpty {
                DisclosureGroup(L("最近交互", "Recent interactions")) {
                    ForEach(currentInteractions) { item in
                        interactionRow(for: item)
                    }
                }
                .font(VG.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Each collected CLI stays visible; input includes cache reads.
    private var todayContextBlock: some View {
        let rows = todayCLICandidates
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("今日用量", "Today")).font(VG.headline).foregroundStyle(.primary)
                VGInfoButton(title: L("用量覆盖", "Usage coverage"), text: usageCoverageText)
                Spacer(minLength: 0)
                Text(L("输入", "Input")).frame(width: 64 * VG.scale, alignment: .trailing)
                Text(L("输出", "Output")).frame(width: 64 * VG.scale, alignment: .trailing)
            }
            .font(VG.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(L("今日还没有可用量记录", "No collected usage today"))
                    .font(VG.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { usage in
                Button { todayCLIKey = usage.name } label: {
                    HStack(spacing: 6) {
                        Text(usage.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(usage.hasTokens ? formatTokens(usage.ctx) : "—")
                            .frame(width: 64 * VG.scale, alignment: .trailing)
                        Text(usage.hasTokens ? formatTokens(usage.out) : "—")
                            .frame(width: 64 * VG.scale, alignment: .trailing)
                    }
                    .font(VG.body).monospacedDigit().foregroundStyle(.primary)
                    .padding(.vertical, 2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(usage.note.isEmpty ? L("选择 \(usage.name) 查看详情", "Select \(usage.name) for details") : usage.note)
            }
            HStack(spacing: 4) {
                Text(deviceScope == .all ? L("已采集日志 · 全部设备", "Collected logs · all devices") : L("已采集日志 · 当前设备", "Collected logs · selected device"))
                    .font(VG.caption).foregroundStyle(.secondary).lineLimit(1).help(usageCoverageText)
                Spacer(minLength: 0)
            }
        }
    }

    private var todayUsageDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let usage = selectedTodayCLI {
                DisclosureGroup(L("\(usage.name) 用量详情", "\(usage.name) usage details")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if usage.hasTokens {
                            Text(L("新输入 \(formatTokens(max(0, usage.ctx - usage.cacheRead))) · 缓存读取 \(formatTokens(usage.cacheRead))", "Fresh \(formatTokens(max(0, usage.ctx - usage.cacheRead))) · cache reads \(formatTokens(usage.cacheRead))"))
                            Text(String(format: L("缓存命中 %.1f%% · %d 次请求", "Cache hit %.1f%% · %d requests"), usage.cacheHitRate, usage.requests))
                            Text(L("输出中含思考 \(formatTokens(usage.think))", "Output includes \(formatTokens(usage.think)) reasoning"))
                        } else if usage.turns > 0 {
                            Text(L("\(usage.turns) 轮 · token 数据不可用", "\(usage.turns) turns · token data unavailable"))
                        } else {
                            Text(L("暂无可用 token 数据", "Token data unavailable"))
                        }
                        if !usage.note.isEmpty { Text(UIFormat.metadata(usage.note)).help(usage.note) }
                        if let note = retainedHistoryNote { Text(note) }
                    }
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                .font(VG.caption).foregroundStyle(.secondary)
            }
            if showClaudeExtras && !currentTokens.todayByProject.isEmpty {
                DisclosureGroup(L("按项目查看", "Usage by project")) {
                    ForEach(Array(currentTokens.todayByProject.prefix(8))) { project in
                        HStack(spacing: 8) {
                            Text(project.name).lineLimit(1).truncationMode(.middle).help(project.path)
                            Spacer(minLength: 4)
                            Text(formatTokens(project.ctx)).monospacedDigit()
                            Text(L("\(project.turns) 轮", "\(project.turns) turns")).foregroundStyle(.secondary)
                        }
                        .font(VG.caption).padding(.vertical, 4)
                    }
                }
                .font(VG.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var usageCoverageText: String {
        var text = L("当日累计输入已包含缓存读取，不是单次请求的上下文长度。统计仅包含已采集的会话日志；未含 Codex 云端 / Dot 用量。云端任务在本机执行工具，不代表云端 token 记录也保存在本机。", "Daily input includes cache reads; it is not a single request's context length. Totals include collected session logs only. Codex Cloud / Dot usage is excluded. Running cloud tools locally does not store cloud token records locally.")
        if let note = retainedHistoryNote { text += "\n\n" + note }
        return text
    }

    // MARK: - 订阅页 · 远程设备分区

    /// 选了某台远程主机：只展示采集器能拿到的（opencode / Codex / Claude），拿不到的如实说明。
    @ViewBuilder
    private func remoteDeviceSection(host: String) -> some View {
        let today = historyTodayRows(host)
        let hostSources = history.totals.filter { UsageHistory.device(of: $0.key) == host }
        let total: UsageHistory.Totals? = hostSources.isEmpty ? nil : hostSources.values.reduce(into: UsageHistory.Totals()) { $0.merge($1) }
        let cost = history.costBySource.filter { UsageHistory.device(of: $0.key) == host }.values
            .reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        let todayCost = history.todayCostBySource.filter { UsageHistory.device(of: $0.key) == host }.values
            .reduce(into: [String: Double]()) { acc, v in for (k, x) in v { acc[k, default: 0] += x } }
        let unpriced = history.unpricedBySource.filter { UsageHistory.device(of: $0.key) == host }.values.reduce(0, +)
        let isMount = UsageHistory.mountRoots().contains { $0.label == host }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "desktopcomputer", tint: .blue)
                Text(L("设备 · \(RemoteCollector.displayName(for: host))", "Device · \(RemoteCollector.displayName(for: host))")).font(VG.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                VGPill(text: isMount ? L("挂载目录", "Mounted folder") : L("SSH 采集", "SSH collection"), tint: .blue, symbol: isMount ? "externaldrive.connected.to.line.below" : "network")
            }

            HStack(spacing: 6) {
                remoteMetric(L("历史用量", "Historical usage"), total.map { formatTokens($0.tokenTotal) + " token" } ?? L("暂无记录", "No records"),
                             total.map { L("\($0.sessions) 会话 · \($0.turns) 请求", "\($0.sessions) sessions · \($0.turns) requests") } ?? L("等待历史采集", "Waiting for history"))
                remoteMetric(L("API 等价成本", "API-equivalent cost"), total == nil ? L("暂无记录", "No records") : (cost.isEmpty ? L("未定价", "Unpriced") : Fmt.money(cost)),
                             unpriced > 0 ? L("\(unpriced) 个模型未定价 · 今天 \(Fmt.money(todayCost))", "\(unpriced) unpriced models · today \(Fmt.money(todayCost))") : L("今天 \(Fmt.money(todayCost))", "Today \(Fmt.money(todayCost))"))
            }

            if today.isEmpty {
                Text(L("该设备今日还没有采集到 CLI 用量", "No CLI usage collected from this device today"))
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                remoteCLIList(today)
            }

            let notes = Array(Set(["Claude", "Codex", "OpenCode"].compactMap { history.sourceNotes["\($0) · \(host)"] })).sorted()
            if !notes.isEmpty {
                Text(notes.joined(separator: " · "))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(isMount ? L("直接读挂载目录里的 .claude / .codex 日志，口径与本机一致。", "Reads mounted .claude / .codex logs, using the same accounting as local logs.") : L("每 5 分钟经 ssh 增量拉取 Claude / Codex / opencode 的逐条记录，按请求时间归到每一天；成本按内置官方价或你的价目表。", "Pulls Claude / Codex / opencode records over SSH every five minutes, grouped by request date; costs use built-in or custom rates."))
                .font(VG.scaled(8))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remoteMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(VG.scaled(8.5)).foregroundColor(.secondary)
            Text(value).font(VG.scaled(12, weight: .semibold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.85)
            Text(detail).font(VG.scaled(8)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// 远程设备今日各 CLI 一张紧凑卡片：输入、输出、次数和缓存命中率。
    @ViewBuilder
    private func remoteCLIList(_ rows: [CLIUsage]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("今日各 CLI", "CLI usage today"))
                .font(VG.scaled(9, weight: .bold))
                .foregroundColor(.secondary)
            ForEach(rows) { u in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(u.name)
                            .font(VG.scaled(9, weight: .semibold))
                        Spacer()
                        Text(L("\(u.requests) 次", "\(u.requests) requests"))
                            .font(VG.scaled(8.5))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(L("输入 \(formatTokens(u.ctx))", "Input \(formatTokens(u.ctx))"))
                        Text(L("输出 \(formatTokens(u.out))", "Output \(formatTokens(u.out))"))
                        Spacer(minLength: 0)
                        if u.ctx > 0 {
                            Text(String(format: L("缓存 %.0f%%", "Cache %.0f%%"), u.cacheHitRate))
                                .foregroundColor(u.cacheHitRate >= 80 ? .green : .secondary)
                        }
                    }
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .padding(.vertical, 8)
                if u.id != rows.last?.id { Divider() }
            }
        }
    }

    // MARK: - Tab API：API Key 调用（经记账代理）

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VGIcon(symbol: "key.horizontal.fill", tint: .blue)
                Text(L("API Key 调用", "API key calls")).font(VG.headline)
                Spacer(minLength: 0)
            }
            let api = currentAPI
            HStack(spacing: 4) {
                Circle()
                    .fill(api.running ? Color.green : (api.installed ? Color.orange : Color.secondary.opacity(0.4)))
                    .frame(width: 5, height: 5)
                Text(api.running ? L("代理运行中 · :\(api.port)", "Proxy running · :\(api.port)") : (api.installed ? L("代理已安装，未在跑", "Proxy installed, not running") : L("代理未安装", "Proxy not installed")))
                    .font(VG.scaled(9.5, weight: .medium))
                    .foregroundColor(api.installed && !api.running ? .orange : .secondary)
            }

            if apiCards.isEmpty {
                Text(currentAPI.installed
                     ? L("还没有调用经过代理。把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。", "No calls have passed through the proxy yet. Prefix BASE_URL in your alias with http://127.0.0.1:\(currentAPI.port)/ to track usage.")
                     : L("菜单里「安装 API 记账代理」，再把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。", "Install the API accounting proxy from the menu, then prefix BASE_URL in your alias with http://127.0.0.1:\(currentAPI.port)/ to track usage."))
                    .font(VG.scaled(8.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(apiCards) { card in
                        modelCard(for: card)
                        if card.id != apiCards.last?.id { Divider() }
                    }
                }
            }

            Divider().opacity(0.35)

            // 记账覆盖体检：有 BASE_URL 没走代理 = 面板上看不到那些调用
            let cov = currentAPI.coverage
            if !cov.entries.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: cov.directCount > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                        .font(VG.scaled(8))
                        .foregroundColor(cov.directCount > 0 ? .orange : .green)
                    Text(L("记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处", "Accounting coverage: \(cov.proxiedCount)/\(cov.entries.count) endpoints"))
                        .font(VG.scaled(9, weight: .medium))
                    if cov.directCount > 0 {
                        Text(L("· 未接：", "· Direct: ") + cov.entries.filter { !$0.proxied }.prefix(3).map { $0.host }.joined(separator: " "))
                            .font(VG.scaled(8))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .help(cov.entries.map { "\($0.proxied ? "✓" : "✗") \($0.name) → \($0.host)  (\($0.file):\($0.line))" }.joined(separator: "\n"))
            }

            // 代理控制
            VStack(alignment: .leading, spacing: 6) {
                if currentAPI.installed {
                    Text(L("代理前缀 http://127.0.0.1:\(currentAPI.port)/", "Proxy prefix http://127.0.0.1:\(currentAPI.port)/"))
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                    Button(action: actions.copyProxyPrefix) { Text(L("复制", "Copy")).font(VG.scaled(9)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                    Button(action: actions.uninstallProxy) { Text(L("停止并卸载", "Stop and uninstall")).font(VG.scaled(9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                } else {
                    Text(L("安装后登录自启，不依赖本 App。", "Starts at login, independently of this app."))
                        .font(VG.scaled(8.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: actions.installProxy) { Text(L("安装并启动", "Install and start")).font(VG.scaled(9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                }
            }
        }
    }

    // MARK: - Tab 系统：磁盘占用（会话日志治理）

    private var diskSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                actionSection
                if report.diskStatsPending {
                    Text(report.diskStatsKnown
                         ? L("正在后台更新，显示上次统计", "Updating in the background; showing the last measurement")
                         : L("正在后台统计，不影响额度刷新", "Measuring in the background; quota refresh remains available"))
                        .font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(report.disk.prefix(6)) { d in
                    HStack(spacing: 5) {
                        Image(systemName: d.purgeable ? "clock.arrow.circlepath" : "lock")
                            .font(VG.scaled(7.5))
                            .foregroundColor(d.purgeable ? .blue.opacity(0.8) : .secondary.opacity(0.6))
                        Text(UIFormat.metadata(d.label))
                            .font(VG.scaled(9.5, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if d.purgeable, d.oldMB >= 1 {
                            Text(String(format: L("旧 %.0f MB", "Old %.0f MB"), d.oldMB))
                                .font(VG.scaled(8.5, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                        Text(sizeText(d.totalMB))
                            .font(VG.scaled(9.5))
                            .foregroundColor(.secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .help(d.note)
                }

                if report.purgeableMB >= 100 {
                    Button(action: actions.purgeLogs) {
                        HStack {
                            Image(systemName: "trash").font(VG.scaled(9))
                            Text(String(format: L("清理 %d 天前的会话记录 · %@", "Clean session logs older than %d days · %@"), ProcessScanner.shared.logRetentionDays, sizeText(report.purgeableMB)))
                                .font(VG.scaled(10, weight: .semibold))
                            Spacer()
                            Text(L("移入废纸篓", "Move to Trash")).font(VG.scaled(8)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.14))
                        .foregroundColor(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Text(L("🔒 = 只统计不清理（运行库 / 插件 / 你的产物）", "🔒 = counted only, not cleaned (runtimes / plugins / your files)"))
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VGIcon(symbol: "internaldrive.fill", tint: .gray)
                Text(L("磁盘占用", "Disk usage")).font(VG.headline)
                Spacer()
                Text(report.diskStatsKnown
                     ? String(format: L("最近统计 %.1f GB", "Last measured: %.1f GB"), report.diskTotalAIGB)
                     : (report.diskStatsPending ? L("计算中…", "Calculating…") : L("暂不可用", "Unavailable")))
                    .font(VG.scaled(9.5))
                    .foregroundColor(.secondary)
            }
        }
        .tint(.secondary)
        .accessibilityIdentifier("system.diskDetails")
    }

    private func sizeText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// 远程 / 挂载设备今天各 CLI 的用量：取自历史汇总（按请求时间归日，≤5 分钟旧）。
    private func historyTodayRows(_ host: String) -> [CLIUsage] {
        DeviceScope.todayUsage(local: [], history: history.currentDaySources(), scope: .remote(host))
    }

    // MARK: - Tab 系统：设备与数据源

    private var devicesSection: some View {
        let hosts = RemoteCollector.hosts()
        let mounts = UsageHistory.mountRoots()
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                VGKeyValue(key: L("本机", "Local"), value: L("~/.claude · ~/.config/claude · ~/.codex（含 archived）· opencode", "~/.claude · ~/.config/claude · ~/.codex (including archived) · opencode"))
                ForEach(hosts, id: \.self) { host in
                    let note = history.sourceNotes["Codex · \(host)"]
                    VGKeyValue(key: RemoteCollector.displayName(for: host), value: note ?? L("SSH · Claude / Codex / opencode", "SSH · Claude / Codex / opencode"),
                               valueColor: note == nil ? .primary : .secondary)
                }
                ForEach(mounts.indices, id: \.self) { i in
                    let m = mounts[i]
                    let available = mountAvailability[m.path]
                    VGKeyValue(key: m.label,
                               value: available == nil ? L("检查挂载… · \(m.path)", "Checking mount… · \(m.path)") :
                                available == true ? L("挂载 · \(m.path)", "Mounted · \(m.path)") : L("目录不在：\(m.path)", "Directory unavailable: \(m.path)"),
                               valueColor: available == nil ? .secondary : available == true ? .primary : .orange)
                }
                Text(L("WSL / Linux 两种接法：能免密 ssh 就加到 remoteHosts；已经把那台机器的家目录挂到本机（SMB / sshfs / \\\\wsl$）就加到 mountRoots。", "Two ways to connect WSL / Linux: add passwordless SSH hosts to remoteHosts, or add mounted home directories (SMB / sshfs / \\\\wsl$) to mountRoots."))
                    .font(VG.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(#"defaults write io.github.xixilys.vibedeck remoteHosts "user@wsl-host""#, forType: .string)
                    } label: { Label(L("复制 SSH 配置命令", "Copy SSH setup command"), systemImage: "doc.on.doc").font(VG.font(11)) }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(#"defaults write io.github.xixilys.vibedeck mountRoots "wsl=/Volumes/wsl/home/you""#, forType: .string)
                    } label: { Label(L("复制挂载配置命令", "Copy mount setup command"), systemImage: "doc.on.doc").font(VG.font(11)) }
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 6)
        } label: {
            VGSectionHeader(title: L("设备与数据源", "Devices and sources"), symbol: "externaldrive.connected.to.line.below.fill", tint: .blue) {
                Text(L("\(hosts.count + mounts.count + 1) 台", "\(hosts.count + mounts.count + 1) devices")).font(VG.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .accessibilityIdentifier("system.deviceDetails")
        .onAppear { refreshMountAvailability() }
    }

    // MARK: - Tab 系统：设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow(L("显示 API 页", "Show API tab"), isOn: $showAPITab)
            Divider().opacity(0.5)
            settingRow(L("自动清理", "Automatic cleanup"), detail: L("仅清理持续断链的 AI 进程", "Only persistently orphaned AI processes"),
                       isOn: Binding(get: { autoCleanOn }, set: { autoCleanOn = $0; actions.setAutoClean($0) }))
            Divider().opacity(0.5)
            settingRow(L("登录时启动", "Launch at login"),
                       isOn: Binding(get: { launchAtLoginOn }, set: { launchAtLoginOn = $0; actions.setLaunchAtLogin($0) }))
            Divider().opacity(0.5)
            settingRow(L("阈值通知", "Threshold alerts"), info: L("额度 80/95%、内存 85/93%、磁盘 90/96% 越线时提醒一次", "Alert once when quota reaches 80/95%, memory 85/93%, or disk 90/96%"),
                       isOn: Binding(get: { notifyOn }, set: { notifyOn = $0; actions.setThresholdNotify($0) }))
            Divider().opacity(0.5)
            settingRow(L("出口变化通知", "Exit change alerts"), info: L("AI 出口 IP 或国家变化时提醒，每家 10 分钟最多一次", "Alert when an AI exit IP or country changes, at most once per provider every 10 minutes"),
                       isOn: Binding(get: { exitNotifyOn }, set: { exitNotifyOn = $0; actions.setExitChangeNotify($0) }))
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    // MARK: - 设置 · 设备

    private var manualHosts: [String] {
        remoteHostsRaw.split { ", ;\n\t".contains($0) }.map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// SSH devices are the collection targets: ~/.ssh/config aliases or user@host, plus herdr machines and mounted homes.
    private var devicesSettings: some View {
        let manual = Set(manualHosts)
        let all = RemoteCollector.hosts()
        let mounts = UsageHistory.mountRoots()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("设备", "Devices")).font(VG.caption.weight(.semibold)).foregroundStyle(.secondary)
                VGInfoButton(title: L("添加设备", "Adding devices"),
                             text: L("填 ~/.ssh/config 里的别名或 user@host，需要免密登录且远端有 python3。添加后自动采集 Claude Code / Codex / opencode 用量、额度与首字。herdr 里启用的机器会自动出现；挂载目录用 defaults 的 mountRoots 配置。",
                                     "Enter an ~/.ssh/config alias or user@host with key-based login and python3 on the remote. Claude Code / Codex / opencode usage, quotas and first-token timing are collected automatically. Enabled herdr machines appear on their own; mounted homes use the mountRoots default."))
                Spacer()
                Text(L("\(all.count + mounts.count) 台", "\(all.count + mounts.count)")).font(VG.caption).foregroundStyle(.tertiary)
            }
            ForEach(all, id: \.self) { host in
                HStack(spacing: 6) {
                    Circle().fill(report.remoteDeviceStatus[host].map { $0.error.isEmpty ? Glass.memory : Color.orange } ?? Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(RemoteCollector.displayName(for: host)).font(VG.body).lineLimit(1)
                    if RemoteCollector.displayName(for: host) != host {
                        Text(host).font(VG.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if manual.contains(host) {
                        Button {
                            remoteHostsRaw = manualHosts.filter { $0 != host }.joined(separator: " ")
                            actions.rescan()
                        } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help(L("移除", "Remove"))
                    } else {
                        Text("herdr").font(VG.caption).foregroundStyle(.tertiary)
                    }
                }
                .help(report.remoteDeviceStatus[host]?.error ?? "")
            }
            ForEach(mounts, id: \.label) { mount in
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.connected.to.line.below").font(VG.caption).foregroundStyle(.secondary)
                    Text(mount.label).font(VG.body)
                    Spacer()
                    Text(L("挂载", "Mount")).font(VG.caption).foregroundStyle(.tertiary)
                }.help(mount.path)
            }
            HStack(spacing: 6) {
                TextField(L("ssh 别名或 user@host", "ssh alias or user@host"), text: $newHost)
                    .textFieldStyle(.roundedBorder).font(VG.body)
                    .onSubmit(addHost)
                    .accessibilityIdentifier("settings.device.field")
                Button(L("添加", "Add"), action: addHost)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings.device.add")
            }
            if !hostError.isEmpty { Text(hostError).font(VG.caption).foregroundStyle(.orange) }
        }
        .padding(10)
        .vgFill(0.06, radius: 8)
    }

    private func addHost() {
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProcessScanner.isValidSSHHost(host) else {
            hostError = L("格式不对：只填 ssh 别名或 user@host", "Invalid: use an ssh alias or user@host"); return
        }
        guard !RemoteCollector.hosts().contains(host) else { hostError = L("这台设备已经在列表里", "Already added"); return }
        remoteHostsRaw = (manualHosts + [host]).joined(separator: " ")
        newHost = ""; hostError = ""
        actions.rescan()
        UsageHistory.shared.refreshSoon()
    }

    private func settingRow(_ title: String, detail: String = "", info: String = "", isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VG.body)
                if !detail.isEmpty {
                    Text(detail).font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !info.isEmpty { VGInfoButton(title: title, text: info) }
            Spacer(minLength: 6)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Tab 系统：清理动作

    @ViewBuilder
    private var actionSection: some View {
        if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
            VStack(spacing: 5) {
                if report.totalOrphanCount > 0 {
                    Button(action: actions.cleanOrphans) {
                        HStack {
                            Text(L("清理断链 AI 残留进程", "Clean orphaned AI processes"))
                                .font(VG.scaled(10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let memStr = report.totalOrphanMemMB > 1024
                                ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                                : "\(Int(report.totalOrphanMemMB)) MB"
                            Text(memStr)
                                .font(VG.scaled(9.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .vgFill(0.12, radius: 6)
                    }
                    .buttonStyle(.plain)
                }

                if report.npxCacheMB > 100 {
                    Button(action: actions.cleanNPX) {
                        HStack {
                            Text(L("清理 NPX 临时工具缓存", "Clean NPX temporary tool cache"))
                                .font(VG.scaled(10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let npxStr = report.npxCacheMB > 1024
                                ? String(format: "%.2f GB", report.npxCacheMB / 1024.0)
                                : "\(Int(report.npxCacheMB)) MB"
                            Text(npxStr)
                                .font(VG.scaled(9.5, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .vgFill(0.08, radius: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(L("AI 与系统运行环境健康，暂无残留垃圾", "AI tools and system are healthy; no leftovers found"))
                    .font(VG.scaled(9.5))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    // MARK: - 最近交互单行

    @ViewBuilder
    private func interactionRow(for item: InteractionRecord) -> some View {
        let isLive = isRecentInteraction(timestamp: item.timestamp)
        let timeAgo = UIFormat.ago(secondsAgo(item.timestamp))

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isLive ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)

                Text(Fmt.modelDisplayName(item.model))
                    .font(VG.scaled(9, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("(\(timeAgo))")
                    .font(VG.scaled(7.5))
                    .foregroundColor(isLive ? .green : .secondary)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    MiniProgressBar(
                        value: item.cacheHitRate / 100.0,
                        color: item.cacheHitRate >= 80 ? .green : (item.cacheHitRate > 50 ? .blue : .secondary),
                        width: 20,
                        height: 3
                    )
                    Text(String(format: "%.1f%%", item.cacheHitRate))
                        .font(VG.scaled(8.5, weight: .bold))
                        .foregroundColor(item.cacheHitRate >= 80 ? .green : .primary)
                        .lineLimit(1)
                        .fixedSize()
                    Text(L("命中", "hit"))
                        .font(VG.scaled(7))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            HStack(spacing: 3.5) {
                Text(L("上下文 \(formatTokensInt(item.contextTokens))", "Context \(formatTokensInt(item.contextTokens))"))
                Text("·")
                Text(L("输出 \(formatTokensInt(item.outputTokens))", "Output \(formatTokensInt(item.outputTokens))"))
                if item.thinkingTokens > 0 {
                    Text("·")
                    Text(L("思考 \(formatTokensInt(item.thinkingTokens))", "Reasoning \(formatTokensInt(item.thinkingTokens))"))
                }
            }
            .font(VG.scaled(8))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .vgFill(0.04, radius: 5)
    }

    // MARK: - 额度子组件

    /// "5H ▮▮ 12%" 一组
    @ViewBuilder
    private func quotaBar(label: String, win: QuotaWindow) -> some View {
        let pct = max(0, min(100, win.usedPct))
        let state = QuotaReadingState.evaluate(win, now: nowTS)
        let current = state == .current
        let level = VGUsageLevel.evaluate(pct, predictedDepletion: QuotaPresentation.predictedDepletion(win, now: nowTS))
        HStack(spacing: 3) {
            Text(label)
                .font(VG.scaled(7.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
            if state != .reset {
                MiniProgressBar(value: Double(pct) / 100.0, color: current ? level.tint : .secondary, width: 16, height: 3.5)
            }
            Text(state == .reset ? L("待刷新", "Awaiting update") : current ? "\(pct)%" : L("\(pct)% · 上次", "\(pct)% · last"))
                .font(VG.scaled(7.5, weight: .bold))
                .foregroundColor(current && level != .normal ? level.tint : .secondary)
                .lineLimit(1)
                .fixedSize()
            if current && level != .normal {
                Image(systemName: level.symbol).font(VG.caption).foregroundStyle(level.tint)
                    .accessibilityLabel(QuotaPresentation.usageLabel(pct, predictedDepletion: QuotaPresentation.predictedDepletion(win, now: nowTS)))
                    .help(QuotaPresentation.usageLabel(pct, predictedDepletion: QuotaPresentation.predictedDepletion(win, now: nowTS)))
            }
        }
    }

    @ViewBuilder
    private func dot() -> some View {
        Text("·")
            .font(VG.scaled(7))
            .foregroundColor(.secondary)
            .fixedSize()
    }

    /// 脚注内容：各窗口重置倒计时 + 按池分别标数据新鲜度（>5 分钟才标）
    private func footerParts(for llm: DetectedLLMRuntime) -> (resets: String, stale: String) {
        let sp = UIFormat.tier(llm.secondaryPoolName)
        let windows: [(String, QuotaWindow?)] = [
            ("5H", llm.fiveHour), ("W", llm.sevenDay), ("\(sp)5H", llm.secondaryFiveHour), ("\(sp)W", llm.secondarySevenDay)
        ]
        let resets = windows.compactMap { label, w -> String? in
            guard let w = w, let c = UIFormat.countdown(to: w.resetsAt, now: nowTS) else { return nil }
            return "\(label) \(c)"
        }
        var stale: [String] = []
        if let a = [llm.fiveHour, llm.sevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append(L("记录于 \(UIFormat.agoShort(a))", "Recorded \(UIFormat.agoShort(a))"))
        }
        if let a = [llm.secondaryFiveHour, llm.secondarySevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append(L("\(sp) 记录于 \(UIFormat.agoShort(a))", "\(sp) recorded \(UIFormat.agoShort(a))"))
        }
        return (resets.isEmpty ? "" : L("重置 ", "Resets ") + resets.joined(separator: " · "), stale.joined(separator: " · "))
    }

    /// 「按当前节奏会不会超额」——挑最吃紧的那个窗口，一直显示，不只是超额时才提示。
    /// 超额的窗口优先；都不超额就显示离满最近的那个。
    private func burnLine(for llm: DetectedLLMRuntime) -> (text: String, over: Bool)? {
        let secondaryPool = UIFormat.tier(llm.secondaryPoolName)
        let wins: [(String, QuotaWindow?)] = [("5h", llm.fiveHour), (L("周", "Week"), llm.sevenDay),
                                              ("\(secondaryPool)5h", llm.secondaryFiveHour),
                                              ("\(secondaryPool)\(L("周", "week"))", llm.secondarySevenDay)]
        var best: (label: String, burn: Burn)? = nil
        for (label, w) in wins {
            guard let w = w, QuotaReadingState.evaluate(w, now: nowTS) == .current,
                  let b = w.burn(now: nowTS), b.isRecent else { continue }
            if best == nil || b.projectedAtReset > best!.burn.projectedAtReset { best = (label, b) }
        }
        guard let (label, b) = best else { return nil }
        if let at = b.exhaustAt, let eta = UIFormat.countdown(to: at, now: nowTS) {
            return (L("\(label) 按当前节奏 \(eta) 后打满（重置时 \(b.projectedAtReset)%）", "\(label) at the current pace: full \(eta) (\(b.projectedAtReset)% at reset)"), true)
        }
        return (L("\(label) 按当前节奏，到重置 \(b.projectedAtReset)%", "\(label) at the current pace: \(b.projectedAtReset)% at reset"), false)
    }

    /// Single-line reset and forecast summaries retain their full text on hover.
    @ViewBuilder
    private func quotaFooter(for llm: DetectedLLMRuntime) -> some View {
        let parts = footerParts(for: llm)
        if let b = burnLine(for: llm) {
            Text((b.over ? "⚡ " : "→ ") + b.text)
                .font(VG.scaled(7))
                .foregroundColor(b.over ? .red : .secondary)
                .lineLimit(1).help(b.text)
        }
        if !parts.resets.isEmpty || !parts.stale.isEmpty {
            (Text(parts.resets)
                + Text(parts.resets.isEmpty || parts.stale.isEmpty ? "" : " · ")
                + Text(parts.stale).foregroundColor(.orange))
                .font(VG.scaled(7))
                .foregroundColor(.secondary)
                .lineLimit(1).help([parts.resets, parts.stale].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    /// 一个套餐多模型额度：按已用 % 降序，只显示 3 个，其余"另 N 个"展开
    @ViewBuilder
    private func subQuotaRows(for llm: DetectedLLMRuntime) -> some View {
        if !llm.subQuotas.isEmpty {
            let sorted = llm.subQuotas.sorted { $0.window.effectivePct(now: nowTS) > $1.window.effectivePct(now: nowTS) }
            let expanded = expandedCards.contains(llm.id)
            let shown = expanded ? sorted : Array(sorted.prefix(3))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { q in
                    HStack(spacing: 3) {
                        Text(q.name)
                            .font(VG.scaled(7.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        quotaBar(label: "", win: q.window)
                    }
                }
                if sorted.count > 3 {
                    Button(action: {
                        if expanded { expandedCards.remove(llm.id) } else { expandedCards.insert(llm.id) }
                    }) {
                        Text(expanded ? L("收起 ▴", "Show fewer ▴") : L("另 \(sorted.count - 3) 个 ▾", "\(sorted.count - 3) more ▾"))
                            .font(VG.scaled(7.5))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)
        }
    }

    private func cardHeader(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text(llm.name).font(VG.headline)
                    .foregroundColor(llm.isRunning ? .primary : .secondary)
                    .lineLimit(1).help(llm.name)
                Spacer(minLength: 4)
                if !llm.tier.isEmpty {
                    Text(UIFormat.tier(llm.tier)).font(VG.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(llm.tier)
                }
            }
            if !llm.detail.isEmpty {
                Text(UIFormat.metadata(llm.detail)).font(VG.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(llm.detail)
            }
        }
    }

    // 普通卡片（双列）
    @ViewBuilder
    private func modelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            cardHeader(for: llm)

            if llm.hasQuota {
                HStack(spacing: 3) {
                    if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                    if let sd = llm.sevenDay {
                        if llm.fiveHour != nil { dot() }
                        quotaBar(label: "W", win: sd)
                    }
                }
                quotaFooter(for: llm)
                if !llm.quotaNote.isEmpty {
                    Text(UIFormat.metadata(llm.quotaNote))
                        .font(VG.scaled(7.5))
                        .foregroundColor(.orange.opacity(0.85))      // 橙色 = 这数是估的，不是厂商给的
                        .lineLimit(1)
                        .help(llm.quotaNote)
                }
            } else {
                let subtitle = llm.quotaSubtitle.isEmpty ? (llm.isRunning ? L("服务就绪", "Service ready") : L("未启动", "Not running")) : llm.quotaSubtitle
                Text(UIFormat.metadata(subtitle))
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(subtitle)
            }
            if !llm.extraLine.isEmpty {
                Text(UIFormat.metadata(llm.extraLine))
                    .font(VG.scaled(7.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(llm.extraLine)
            }
            if !llm.extraLine2.isEmpty {
                Text(UIFormat.metadata(llm.extraLine2))
                    .font(VG.scaled(7.5))
                    .foregroundColor(llm.extraLine2.contains("错") ? .orange : .secondary)
                    .lineLimit(1)
                    .help(llm.extraLine2)
            }
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // 整行卡片（双池：原生池 + 三方池）
    @ViewBuilder
    private func fullWidthModelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            cardHeader(for: llm)

            VStack(alignment: .leading, spacing: 6) {
                if llm.fiveHour != nil || llm.sevenDay != nil {
                    HStack(spacing: 6) {
                        Text(L("官方", "Official")).font(VG.caption).foregroundStyle(.secondary)
                            .frame(width: 64 * VG.scale, alignment: .leading)
                        if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                        if let sd = llm.sevenDay { quotaBar(label: "W", win: sd) }
                        Spacer(minLength: 0)
                    }
                }
                if llm.secondaryFiveHour != nil || llm.secondarySevenDay != nil {
                    HStack(spacing: 6) {
                        Text(UIFormat.tier(llm.secondaryPoolName)).font(VG.caption).foregroundStyle(.secondary)
                            .lineLimit(1).frame(width: 64 * VG.scale, alignment: .leading).help(llm.secondaryPoolName)
                        if let fh = llm.secondaryFiveHour { quotaBar(label: "5H", win: fh) }
                        if let sw = llm.secondarySevenDay { quotaBar(label: "W", win: sw) }
                        Spacer(minLength: 0)
                    }
                }
            }

            quotaFooter(for: llm)
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .vgFill(llm.isRunning ? 0.08 : 0.03, radius: 6)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // MARK: - 详情页

    /// 大号额度环：外圈已用比例，中间百分比，下面窗口名 + 重置倒计时
    @ViewBuilder
    private func quotaRing(label: String, win: QuotaWindow, size: CGFloat = 78) -> some View {
        let pct = max(0, min(100, win.usedPct))
        let state = QuotaReadingState.evaluate(win, now: nowTS)
        let predicted = QuotaPresentation.predictedDepletion(win, now: nowTS)
        let level = VGUsageLevel.evaluate(pct, predictedDepletion: predicted)
        let color = state == .current ? level.tint : Color.secondary
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                if state != .reset && pct > 0 { Circle()
                    .trim(from: 0, to: Double(pct) / 100.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90)) }
                VStack(spacing: 0) {
                    Text(state == .reset ? "—" : "\(pct)")
                        .font(VG.scaled(21, weight: .bold, design: .rounded))
                        .foregroundColor(pct > 80 ? color : .primary)
                    Text(state == .reset ? L("待刷新", "Awaiting update") : state == .current ? L("% 已用", "% used") : L("% 上次记录", "% last reading"))
                        .font(VG.scaled(7))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(VG.scaled(9.5, weight: .semibold))
            if let c = UIFormat.countdown(to: win.resetsAt, now: nowTS) {
                Text(L("重置 \(c)", "Resets \(c)"))
                    .font(VG.scaled(8))
                    .foregroundColor(.secondary).lineLimit(1).help(L("重置 \(c)", "Resets \(c)"))
            }
            if state == .current && level != .normal {
                Label(QuotaPresentation.usageLabel(pct, predictedDepletion: predicted), systemImage: level.symbol)
                    .font(VG.caption).foregroundStyle(color).lineLimit(1)
            }
            if let a = win.ageSeconds(now: nowTS) {
                Text(L("记录于 \(UIFormat.agoShort(a))", "Recorded \(UIFormat.agoShort(a))"))
                    .font(VG.scaled(7.5))
                    .foregroundColor(a > 300 ? .orange : .secondary.opacity(0.75))
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(VG.scaled(9.5, weight: .bold))
            .foregroundColor(.secondary)
    }

    private func card<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .vgFill(0.06, radius: 8)
    }

    @ViewBuilder
    private func detailPage(for llm: DetectedLLMRuntime) -> some View {
        let d = llm.platformDetail

        // 1. 额度环
        if llm.hasQuota {
            card {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 2), spacing: 12) {
                    if let fh = llm.fiveHour {
                        quotaRing(label: L("5 小时窗口", "5-hour window"), win: fh).frame(maxWidth: .infinity)
                    }
                    if let sd = llm.sevenDay {
                        quotaRing(label: llm.name == "Grok" ? L("周窗口", "Weekly window") : L("7 天窗口", "7-day window"), win: sd).frame(maxWidth: .infinity)
                    }
                    if let sf = llm.secondaryFiveHour {
                        quotaRing(label: "\(UIFormat.tier(llm.secondaryPoolName)) 5H", win: sf).frame(maxWidth: .infinity)
                    }
                    if let sw = llm.secondarySevenDay {
                        quotaRing(label: L("\(UIFormat.tier(llm.secondaryPoolName))池 周", "\(UIFormat.tier(llm.secondaryPoolName)) weekly pool"), win: sw).frame(maxWidth: .infinity)
                    }
                }
            }
        }

        // 1.5 燃烧速率（窗口长度已知才算：本窗口迄今的平均速度）
        let burns: [(String, Burn)] = [(L("5 小时", "5 hours"), llm.fiveHour), (L("周", "Week"), llm.sevenDay),
                                       (L("\(UIFormat.tier(llm.secondaryPoolName)) 5 小时", "\(UIFormat.tier(llm.secondaryPoolName)) 5 hours"), llm.secondaryFiveHour),
                                       (L("\(UIFormat.tier(llm.secondaryPoolName)) 周", "\(UIFormat.tier(llm.secondaryPoolName)) week"), llm.secondarySevenDay)]
            .compactMap { label, w in w?.burn(now: nowTS).map { (label, $0) } }
        if !burns.isEmpty {
            card {
                sectionTitle(L("燃烧速率（优先按近期节奏）", "Burn rate (recent pace when available)"))
                ForEach(Array(burns.enumerated()), id: \.offset) { _, item in
                    let b = item.1
                    HStack(spacing: 4) {
                        Text(item.0).font(VG.scaled(9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: L("%.1f%%/小时", "%.1f%%/hour"), b.pctPerHour))
                            .font(VG.scaled(9, weight: .semibold))
                        Text(UIFormat.metadata(b.basis))
                            .font(VG.scaled(7.5))
                            .foregroundColor(b.isRecent ? .blue.opacity(0.85) : .secondary)
                            .help(b.basis)
                        Text(L("→ 重置时 \(b.projectedAtReset)%", "→ \(b.projectedAtReset)% at reset"))
                            .font(VG.scaled(8.5))
                            .foregroundColor(b.projectedAtReset >= 100 ? .red : .secondary)
                        if let at = b.exhaustAt, let eta = UIFormat.countdown(to: at, now: nowTS) {
                            Text(L("· \(eta) 后打满", "· full \(eta)"))
                                .font(VG.scaled(8.5, weight: .semibold))
                                .foregroundColor(.orange)
                                .fixedSize()
                        }
                    }
                }
            }
        }

        // 2. 其他额度桶（Codex 的 Spark 等）
        if !d.extraPools.isEmpty {
            card {
                sectionTitle(L("其他额度桶（主卡未显示）", "Other quota pools (not shown on the main card)"))
                ForEach(Array(d.extraPools.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Text(item.0).font(VG.scaled(9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        quotaBar(label: "", win: item.1)
                        if let c = UIFormat.countdown(to: item.1.resetsAt, now: nowTS) {
                            Text(c).font(VG.scaled(7.5)).foregroundColor(.secondary).fixedSize()
                        }
                    }
                }
            }
        }

        // 3. 订阅 / 账号信息
        if !d.rows.isEmpty {
            card {
                HStack {
                    sectionTitle(L("订阅与账号", "Subscription and account"))
                    Spacer()
                    if !llm.tier.isEmpty {
                        Text(UIFormat.tier(llm.tier))
                            .font(VG.scaled(8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tierColor(llm.tier).opacity(0.18))
                            .foregroundColor(tierColor(llm.tier))
                            .clipShape(Capsule())
                    }
                }
                ForEach(Array(d.rows.enumerated()), id: \.offset) { _, row in
                    let preserveIdentifier = ["默认模型", "CLI 版本", "模型", "上游主机", "Default model", "CLI version", "Models", "Upstream host"].contains(row.0)
                    HStack(alignment: .top, spacing: 6) {
                        Text(UIFormat.metadata(row.0))
                            .font(VG.scaled(8.5))
                            .foregroundColor(.secondary)
                            .frame(width: 96, alignment: .leading)
                            .help(row.0)
                        Text(preserveIdentifier ? row.1 : UIFormat.metadata(row.1))
                            .font(VG.scaled(8.5, design: .monospaced))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(row.1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        // 4. 活跃会话
        if !d.sessions.isEmpty {
            card {
                HStack {
                    sectionTitle(L("活跃会话", "Active sessions"))
                    Spacer()
                    Text(L("\(d.sessions.count) 个", "\(d.sessions.count) sessions")).font(VG.scaled(8)).foregroundColor(.secondary)
                }
                ForEach(d.sessions) { se in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 4, height: 4)
                            Text(shortPath(se.cwd))
                                .font(VG.scaled(8.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(UIFormat.agoShort(se.startedAgo))
                                .font(VG.scaled(8)).foregroundColor(.secondary).fixedSize()
                            Text(String(format: "%.0f MB", se.memMB))
                                .font(VG.scaled(8)).foregroundColor(.secondary).fixedSize()
                        }
                        Text("PID \(se.pid)")
                            .font(VG.scaled(7, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 1)
                }
            }
        }

        // 5. 今日用量（该平台自己的）
        if let u = currentCLI.first(where: { $0.name.hasPrefix(llm.name) || llm.name.hasPrefix($0.name.replacingOccurrences(of: " Code", with: "")) }) {
            card {
                sectionTitle(L("今日用量", "Today's usage"))
                if u.hasTokens {
                    HStack(spacing: 0) {
                        detailMetric(L("上下文", "Context"), formatTokens(u.ctx))
                        detailMetric(L("输出", "Output"), formatTokens(u.out))
                        detailMetric(L("思考", "Reasoning"), formatTokens(u.think))
                        detailMetric(L("调用", "Requests"), "\(u.requests)")
                    }
                    HStack(spacing: 4) {
                        Text(L("缓存命中", "Cache hit rate")).font(VG.scaled(8)).foregroundColor(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18)).frame(height: 5)
                                RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(max(0.01, min(1, u.cacheHitRate / 100))), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text(String(format: "%.1f%%", u.cacheHitRate))
                            .font(VG.scaled(8, weight: .bold)).fixedSize()
                    }
                } else {
                    Text(u.turns > 0 ? L("\(u.turns) 轮 · \(u.note)", "\(u.turns) turns · \(u.note)") : u.note)
                        .font(VG.scaled(8.5)).foregroundColor(.secondary)
                }
            }
        }

        // 6. 数据来源
        if !d.sourceFiles.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle(L("数据来源（只读本机文件）", "Data sources (local files, read only)"))
                ForEach(d.sourceFiles, id: \.self) { f in
                    Text(f).font(VG.scaled(7.5, design: .monospaced)).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func detailMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(VG.scaled(12, weight: .bold, design: .rounded))
            Text(label).font(VG.scaled(7.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// /Users/x/Desktop/code/foo → ~/…/code/foo
    private func shortPath(_ p: String) -> String {
        var s = p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let parts = s.split(separator: "/")
        if parts.count > 3 { s = "~/…/" + parts.suffix(2).joined(separator: "/") }
        return s
    }

    private func openDetail(_ llm: DetectedLLMRuntime) {
        // 只有真有东西可看才进详情，避免点进去一片空白
        guard llm.hasQuota || !llm.platformDetail.rows.isEmpty || !llm.platformDetail.sessions.isEmpty else { return }
        openDetail(llm.name)
    }
}


/// 面板底栏的小按钮：图标 + 文字，悬停时出现圆角底色（系统工具栏按钮的手感）。
struct FooterButton: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(VG.font(11, .medium))
                Text(title).font(VG.font(11.5, .medium))
            }
            .foregroundStyle(hover ? tint : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(hover ? VG.fillStrong : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
