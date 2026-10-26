import Cocoa
import Combine
import SwiftUI
import ServiceManagement
import UserNotifications
import os

/// Hosts the interactive panel without entering NSMenu's keyboard-tracking loop.
final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    weak var delegateRef: AppDelegate?
    private let vlog = Logger(subsystem: "io.github.xixilys.vibedeck", category: "menu")

    override func scrollWheel(with event: NSEvent) {
        vlog.debug("view scroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY)")
        if delegateRef?.handleScroll(event) == true { return }
        super.scrollWheel(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let panelPopover = NSPopover()
    private var previousPanelApplication: NSRunningApplication?
    private var restorePanelFocusOnClose = false
    private var timer: Timer?
    private var autoCleanTimer: Timer?
    private var terminationPending = false

    private var currentReport = ScanReport()
    private var isPanelOpen = false
    private var isRelayoutScheduled = false
    private var panelGeneration: UInt = 0
    /// The SwiftUI tree is kept for a while after the panel closes: rebuilding it on every click was the open lag.
    private var cachedPanelKey: String?
    private var panelClosedAt: TimeInterval = 0
    private static let panelCacheSeconds: TimeInterval = 30 * 60
    private var pendingPanelHeight: CGFloat?
    private var pet: MenuBarPetAnimator?
    private var petSample: AnyCancellable?
    private var petAlert = false
    private var petLabel: String?
    private weak var hostingView: SwipeHostingView<DashboardView>?
    private let log = Logger(subsystem: "io.github.xixilys.vibedeck", category: "menu")

    // UserDefaults Keys
    private let autoCleanKey = "autoCleanEnabled"

    var isAutoCleanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCleanKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCleanKey)
            setupAutoCleanTimer()
        }
    }

    /// A new build changes the app's code hash, which the fan service trusts. Ask for the one administrator
    /// approval right at launch instead of when the fan card is opened. A cancelled prompt is not repeated for
    /// this build; the fan card's button remains available.
    private func authorizeFanServiceAtLaunch() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard (FanSMC.fanCount() ?? 0) > 0, FanService.installation() != .installed else { return }
            let executable = Bundle.main.executablePath ?? ""
            let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
            let build = "\((attributes?[.size] as? NSNumber)?.intValue ?? 0):\(Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
            let key = "vg.fan.launchPromptBuild"
            guard UserDefaults.standard.string(forKey: key) != build else { return }
            UserDefaults.standard.set(build, forKey: key)
            DispatchQueue.main.async {
                NSApp.activate()
                FanService.enable { result in
                    if case .failure(let error) = result {
                        self.log.notice("fan service launch authorization: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        let thermostat = FanThermostat.shared
        guard thermostat.requiresHandback else { return .terminateNow }
        terminationPending = true
        thermostat.prepareForQuit { [weak self] result in
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            self.terminationPending = false
            switch result {
            case .success:
                sender.reply(toApplicationShouldTerminate: true)
            case .failure(let error):
                sender.reply(toApplicationShouldTerminate: false)
                thermostat.cancelQuit()
                self.sendNotification(title: L("VibeDeck 仍在运行", "VibeDeck is still running"),
                                      body: L("尚未确认风扇已恢复系统自动，已取消退出。", "Fan Auto was not confirmed, so quitting was cancelled. ") + error.localizedDescription)
                self.log.error("Quit cancelled: fan Auto was not confirmed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        setupStatusItem()

        loadNotifyState()
        DashboardView.migrateTabSelection()
        NetworkScanner.shared.start()
        SystemMonitor.shared.start()
        if FanThermostat.shared.enabled { SystemMonitor.shared.setThermostatActive(true) }
        authorizeFanServiceAtLaunch()
        DispatchQueue.global(qos: .utility).async { _ = PricingCatalog.builtin }
        UsageHistory.shared.start()
        NerfDetector.shared.start()
        ExchangeRates.shared.refreshIfNeeded()
        autoSyncPricesIfStale()
        DispatchQueue.global(qos: .utility).async { ProxyManager.shared.syncIfInstalled() }   // 包里脚本更新了就热替换
        updateStatus()

        let statusTimer = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.updateStatus(forceSlow: false)
        }
        statusTimer.tolerance = 1
        RunLoop.main.add(statusTimer, forMode: .common)  // 面板与后台共享同一份采集报告。
        timer = statusTimer

        setupAutoCleanTimer()
        setupWakeObserver()
    }

    /// 睡醒后 MCP 的父进程常常已经没了，这时候是收割的最好时机。
    /// 延迟 60 秒再跑：让系统先把网络/磁盘缓过来，也给 CLI 自己重连的机会。
    private func setupWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isAutoCleanEnabled else { return }
            self.log.notice("检测到系统唤醒，60 秒后巡检")
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.performSilentAutoClean(reason: "唤醒")
            }
        }
    }

    private func setupAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil

        if isAutoCleanEnabled {
            autoCleanTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
                self?.performSilentAutoClean(reason: "定时")
            }
        }
    }

    /// 触发静默清理的三个时机：定时 30 分钟、睡醒、内存吃紧。
    /// 三者共用同一条保守路径（只动连续两次扫描都是孤儿、且已孤儿 ≥120s 的），并加 5 分钟总闸防风暴。
    private var lastAutoCleanAt: TimeInterval = 0

    /// 内存吃紧该不该立刻收割（纯判断，可自测）
    public static func shouldReapForMemory(usedPct: Int, lastCleanAt: TimeInterval, now: TimeInterval) -> Bool {
        usedPct >= 85 && now - lastCleanAt >= 300
    }

    private func performSilentAutoClean(reason: String = "定时") {
        let now = Date().timeIntervalSince1970
        guard now - lastAutoCleanAt >= 300 else {
            log.debug("自动清理跳过（\(reason)）：距上次不足 5 分钟")
            return
        }
        lastAutoCleanAt = now
        log.notice("自动清理触发：\(reason)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ProcessScanner.shared.scan(forceSlow: true)
            // 静默清理更保守：只动「连续两次扫描都是孤儿」的，避开 CLI 正在重启 MCP 的瞬态
            let stable = ProcessScanner.shared.stableOrphans(report.orphans, minSeconds: 120)
            if !stable.isEmpty {
                let r = ProcessScanner.shared.killProcesses(stable)
                DispatchQueue.main.async {
                    if r.killed > 0 {
                        self?.sendNotification(
                            title: "VibeDeck 内存优化",
                            body: "已静默清理 \(r.killed) 个断链 AI 进程，回收 \(String(format: "%.0f", r.freedMB)) MB 内存。" + (r.skipped > 0 ? "（\(r.skipped) 个已自行退出，跳过）" : "")
                        )
                    }
                    self?.updateStatus()
                }
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Nonmodal status panel

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let button = statusItem.button {
            pet = MenuBarPetAnimator(button: button)
            // The pup's pace follows every CPU sample, not just the slower scan cadence.
            petSample = SystemMonitor.shared.$latest.receive(on: DispatchQueue.main).sink { [weak self] sample in
                guard let self, let cpu = sample.cpu else { return }
                self.pet?.update(cpu: cpu * 100, alert: self.petAlert, label: self.petLabel)
            }
        }
        panelPopover.behavior = .transient
        panelPopover.animates = false
        panelPopover.delegate = self
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panelPopover.isShown { closePanel() }
        else { showPanel() }
    }

    private func showPanel() {
        guard !panelPopover.isShown, let button = statusItem?.button else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        previousPanelApplication = previous?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : previous
        restorePanelFocusOnClose = false
        isPanelOpen = true
        NetworkScanner.shared.setPanelVisible(true)
        SystemMonitor.shared.setVisible(true)
        let reused = canReusePanel()
        if !reused { buildPanel() }
        panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard panelPopover.isShown else { finishClosingPanel(); return }
        // Only a user opening the panel activates it. Background refreshes never take focus.
        NSApp.activate()
        hostingView?.window?.makeKey()
        installSwipeMonitor()
        relayoutPanel()
        if reused { NotificationCenter.default.post(name: .vibeDeckPanelReopened, object: nil) }
        updateStatus()
    }

    private var panelKey: String {
        "\(UITheme.fontScale)|\(UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? "")"
    }

    private func canReusePanel() -> Bool {
        guard hostingView != nil, panelPopover.contentViewController != nil, cachedPanelKey == panelKey,
              Date().timeIntervalSince1970 - panelClosedAt < Self.panelCacheSeconds else { return false }
        return true
    }

    private func dropPanelCache() {
        panelPopover.contentViewController = nil
        hostingView = nil
        cachedPanelKey = nil
    }

    private func closePanel(restoreFocus: Bool = true) {
        restorePanelFocusOnClose = restoreFocus
        // close(), unlike performClose(), also dismisses nested info popovers.
        if panelPopover.isShown { panelPopover.close() }
        else { finishClosingPanel() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel(restoreFocus: false)
    }

    func popoverDidClose(_ notification: Notification) {
        finishClosingPanel()
    }

    private func finishClosingPanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        NetworkScanner.shared.setPanelVisible(false)
        SystemMonitor.shared.setVisible(false)
        // The generation stays: a kept panel still reports its height through the same actions.
        pendingPanelHeight = nil
        isRelayoutScheduled = false
        removeSwipeMonitor()
        // Keep the built panel for the next click; free it if it stays closed for a long time.
        let closedAt = Date().timeIntervalSince1970
        panelClosedAt = closedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelCacheSeconds) { [weak self] in
            guard let self, !self.isPanelOpen, self.panelClosedAt == closedAt else { return }
            self.dropPanelCache()
        }
        let previous = previousPanelApplication
        previousPanelApplication = nil
        let restoreFocus = restorePanelFocusOnClose
        restorePanelFocusOnClose = false
        // Escape/toggle returns to the prior app. Outside clicks and app switches keep their new target.
        if restoreFocus, NSApp.isActive,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate(from: .current, options: [])
        }
    }

    private func isPanelWindow(_ window: NSWindow?) -> Bool {
        guard let root = hostingView?.window else { return false }
        var candidate = window
        while let current = candidate {
            if current === root { return true }
            candidate = current.parent
        }
        return false
    }

    // MARK: - Panel-local keyboard shortcuts and horizontal swipe

    // Monitors exist only while the panel is open and accept only its own window's events.
    private var scrollMonitor: Any?
    private var panelKeyMonitor: Any?
    private var swipeAccum: CGFloat = 0
    private var lastSwipeAt: TimeInterval = 0
    private static let tabCount = 5

    private func installSwipeMonitor() {
        guard scrollMonitor == nil else { return }
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPanelOpen, self.isPanelWindow(event.window) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 53 && modifiers.isEmpty {
                self.closePanel()
                return nil
            }
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r":
                guard !event.isARepeat else { return nil }
                NotificationCenter.default.post(name: .refreshVibeDeckPanel, object: nil)
            case "q": self.quitAction()
            case "1", "2", "3", "4", "5":
                if let key = event.charactersIgnoringModifiers, let number = Int(key) {
                    NotificationCenter.default.post(name: .selectVibeDeckTab, object: number - 1)
                }
            default: return event
            }
            return nil
        }
        swipeAccum = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.isPanelOpen, self.isPanelWindow(event.window) else { return event }
            self.log.debug("monitor scroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue)")
            return self.handleScroll(event) ? nil : event
        }
    }

    private func removeSwipeMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = panelKeyMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        panelKeyMonitor = nil
        swipeAccum = 0
    }

    /// 返回 true = 已处理（吞掉事件）
    fileprivate func handleScroll(_ event: NSEvent) -> Bool {
        var dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dx = -dx }   // 用户关了「自然滚动」时方向要翻回来

        if event.phase == .began || event.phase == .cancelled { swipeAccum = 0 }
        guard abs(dx) > abs(dy) * 1.5 else { return false }   // 竖向为主 → 留给内容滚动
        guard event.momentumPhase == [] else { return true }  // 惯性阶段只吞掉，不再切

        swipeAccum += dx
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 45 : 3
        let now = Date().timeIntervalSince1970
        guard abs(swipeAccum) >= threshold, now - lastSwipeAt > 0.3 else { return true }

        let step = swipeAccum < 0 ? 1 : -1                   // 向左滑 = 下一个 Tab（像翻页）
        swipeAccum = 0
        lastSwipeAt = now
        let cur = UserDefaults.standard.integer(forKey: "vg.tab")
        let next = max(0, min(Self.tabCount - 1, cur + step))
        if next != cur {
            UserDefaults.standard.set(next, forKey: "vg.tab")   // @AppStorage 会跟着刷新
            log.debug("swipe tab \(cur) → \(next)")
        }
        return true
    }

    private var isScanning = false
    private var isRefreshingHealth = false

    private func refreshPanelHealth(completion: @escaping (NerfReport) -> Void) {
        // A newly opened panel must not enqueue another scan behind the previous panel's request.
        guard !isRefreshingHealth else { completion(NerfDetector.shared.snapshot()); return }
        isRefreshingHealth = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = NerfDetector.shared.refreshNow(history: UsageHistory.shared.snapshot())
            DispatchQueue.main.async {
                self?.isRefreshingHealth = false
                completion(report)
            }
        }
    }

    @objc func updateStatus(forceSlow: Bool = true) {
        guard !isScanning else { return }   // 首扫可能 4s+，别让 8s 定时器堆积
        isScanning = true
        let panelVisible = isPanelOpen
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = ProcessScanner.shared.scan(panelVisible: panelVisible, forceSlow: forceSlow)
            AccountMonitor.shared.record(report: report)
            ExchangeRates.shared.refreshIfNeeded()
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.currentReport = report
                self?.renderStatusButton(report: report)
                self?.reapIfMemoryTight(report)
            }
        }
    }

    /// 内存已用 ≥85% 且开了自动清理 → 不等 30 分钟，立刻走一次保守巡检
    private func reapIfMemoryTight(_ report: ScanReport) {
        guard isAutoCleanEnabled, report.totalMemoryGB > 0 else { return }
        let usedPct = max(0, 100 - report.freePercentage)
        guard Self.shouldReapForMemory(usedPct: usedPct, lastCleanAt: lastAutoCleanAt,
                                       now: Date().timeIntervalSince1970) else { return }
        performSilentAutoClean(reason: "内存 \(usedPct)%")
    }

    /// The status item is the menu-bar pup (MenuBarPet). Quotas never draw there, so the bar stays calm;
    /// pressure signals only go to threshold notifications and the hover tooltip.
    private func renderStatusButton(report: ScanReport) {
        evaluateExitChanges()
        guard let button = statusItem.button else { return }
        let health = NerfDetector.shared.snapshot()
        let alert = health.status == .alert
        // Free memory appears beside the pup only when it is getting tight; the tooltip always has it.
        petAlert = alert
        petLabel = report.totalMemoryGB > 0 && report.freePercentage < 20 ? "\(report.freePercentage)%" : nil
        pet?.update(cpu: (SystemMonitor.shared.latest.cpu ?? 0) * 100, alert: petAlert, label: petLabel)

        let signals = report.pressures
        var tip = ["VibeDeck · 内存可用 \(report.freePercentage)%", "模型健康：\(health.status.label) · \(health.headline)"]
        if let f = UsageHistory.shared.snapshot().forecast, f.hasData {
            tip.append("今天 API 等价 \(Fmt.money(f.todaySoFar, f.currency))，预计 \(Fmt.money(f.todayProjected, f.currency))")
        }
        tip.append("—— 以下为已用 %（越高越紧）——")
        let toolTip = (tip + signals.prefix(8).map { "\($0.short)  \($0.pct)%" + ($0.level > 0 ? "  ⚠︎" : "") }).joined(separator: "\n")
        if button.toolTip != toolTip { button.toolTip = toolTip }
        evaluateThresholds(signals)
        evaluateNerf(health)
    }

    // MARK: - 阈值通知
    // 每次扫描（8s）都评一遍，靠"同键同级只报一次"去重；掉回警告线下 5 点才解除，避免在阈值上来回抖。
    // 状态落 UserDefaults：不然每次重启 App 都把"本来就满"的池子重报一遍（实测很吵）
    private var notifiedLevel: [String: Int] = [:]
    private var notifiedAt: [String: TimeInterval] = [:]
    private var didSeedNotifyState = false
    private let notifyKey = "thresholdNotifyEnabled"

    var isThresholdNotifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: notifyKey) == nil ? true : UserDefaults.standard.bool(forKey: notifyKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey) }
    }

    var isExitChangeNotifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "exitChangeNotifyEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "exitChangeNotifyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "exitChangeNotifyEnabled") }
    }

    static func shouldNotifyExit(lastAt: TimeInterval?, now: TimeInterval) -> Bool {
        lastAt.map { now - $0 >= 600 } ?? true
    }

    private func evaluateExitChanges() {
        let events = NetworkScanner.shared.drainExitEvents()
        guard isExitChangeNotifyEnabled else { return }  // 关闭期间的变化不在重新打开时补报
        let defaults = UserDefaults.standard
        for event in events {
            let key = "vg.exitNotifiedAt.\(event.aiName)"
            let now = Date().timeIntervalSince1970
            let last = defaults.object(forKey: key) as? Double
            guard Self.shouldNotifyExit(lastAt: last, now: now) else { continue }
            defaults.set(now, forKey: key)
            sendNotification(title: (event.isCountryChange ? "⛔️ " : "⚠️ ") + "\(event.aiName) 出口变化",
                             body: "\(event.oldIP)（\(event.oldLoc)）→ \(event.newIP)（\(event.newLoc)）")
        }
    }

    private func evaluateThresholds(_ signals: [PressureSignal]) {
        let live = Set(signals.map { $0.key })
        notifiedLevel = notifiedLevel.filter { live.contains($0.key) }   // 额度换窗口 → 键变了 → 旧状态丢掉
        notifiedAt = notifiedAt.filter { live.contains($0.key) }

        // 启动后第一轮只建基线，不报：本来就满的池子（如 Gemini 三方）不该在每次开机/重启时再吼一遍。
        // 之后只有"运行期间真的越线"才提醒。
        if !didSeedNotifyState {
            didSeedNotifyState = true
            let seeded = signals.filter { notifiedLevel[$0.key] == nil }
            for s in seeded { notifiedLevel[s.key] = s.level }
            persistNotifyState()
            log.notice("阈值通知：启动基线 \(signals.count) 条信号，新建 \(seeded.count) 条，本轮不报")
            return
        }

        guard isThresholdNotifyEnabled else { return }
        let now = Date().timeIntervalSince1970
        var dirty = false

        for s in signals {
            let last = notifiedLevel[s.key] ?? 0
            if s.level > last {
                // 同一条信号 4 小时内最多吼一次，避免在阈值上抖来抖去刷屏
                if now - (notifiedAt[s.key] ?? 0) < Self.notifyCooldown { continue }
                notifiedLevel[s.key] = s.level
                notifiedAt[s.key] = now
                dirty = true
                sendNotification(
                    title: (s.level >= 2 ? "⛔️ " : "⚠️ ") + "\(s.short) \(s.pct)%",
                    body: s.detail
                )
            } else if s.level == 0, last > 0, s.pct < s.warn - 5 {
                notifiedLevel[s.key] = 0
                dirty = true
            }
        }
        if dirty { persistNotifyState() }
    }

    private static let notifyCooldown: TimeInterval = 4 * 3600

    // MARK: - 降智告警通知
    // 只报「硬证据」，每条只报一次；启动后第一轮只建基线（历史证据不在每次开机时再吼一遍）。
    private var nerfSeeded = false
    private let nerfNotifiedKey = "vg.nerfNotified"

    private func evaluateNerf(_ report: NerfReport) {
        guard report.capturedAt > 0 else { return }
        let firstRun = !nerfSeeded
        nerfSeeded = true
        var seen = Set(UserDefaults.standard.stringArray(forKey: nerfNotifiedKey) ?? [])
        let hard = report.findings.filter { $0.severity == .hard }
        let fresh = hard.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for f in fresh { seen.insert(f.id) }
        UserDefaults.standard.set(Array(seen.suffix(300)), forKey: nerfNotifiedKey)
        if firstRun { return }
        guard isThresholdNotifyEnabled else { return }
        let now = Date().timeIntervalSince1970
        for f in fresh.prefix(3) where now - f.timestamp < 3600 {
            sendNotification(title: "⚠️ 疑似降智 · \(f.source)", body: "\(f.title)：\(f.detail)" + (f.session.isEmpty ? "" : "（\(f.session)）"))
        }
    }
    private let notifyStateKey = "vg.notifyState"       // [key: "level|lastAt"]

    private func loadNotifyState() {
        guard let raw = UserDefaults.standard.dictionary(forKey: notifyStateKey) as? [String: String] else { return }
        for (k, v) in raw {
            let parts = v.split(separator: "|")
            guard parts.count == 2, let lv = Int(parts[0]), let at = Double(parts[1]) else { continue }
            notifiedLevel[k] = lv
            notifiedAt[k] = at
        }
    }

    private func persistNotifyState() {
        var raw: [String: String] = [:]
        for (k, lv) in notifiedLevel { raw[k] = "\(lv)|\(notifiedAt[k] ?? 0)" }
        UserDefaults.standard.set(raw, forKey: notifyStateKey)
    }

    // MARK: - Build the bounded SwiftUI panel
    private func buildPanel() {
        panelGeneration &+= 1
        let generation = panelGeneration
        pendingPanelHeight = nil
        isRelayoutScheduled = false

        // 面板只读取最近完成的采集快照；后台采集周期不随打开面板改变。
        let report = currentReport

        // 面板（Tab 切换，高度随当前 Tab 内容自适应，超过屏幕才滚动）。所有动作（含同步价格、字号、退出）都在面板底栏。
        var actions = PanelActions()
        actions.accountLedgerError = { AccountMonitor.shared.persistenceError() }
        actions.accountQuotas = { AccountMonitor.shared.snapshot() }
        actions.latestReport = { [weak self] in self?.currentReport }
        actions.isVisible = { [weak self] in self?.isPanelOpen == true }
        actions.cleanOrphans = { [weak self] in
            self?.closePanel()
            self?.cleanOrphansAction()
        }
        actions.cleanNPX = { [weak self] in
            self?.closePanel()
            self?.cleanNPXAction()
        }
        actions.rescan = { [weak self] in
            // A user-requested refresh must not silently keep a five-minute remote process snapshot.
            // The collector owns single-flight; normal panel opens/background ticks keep their existing cadence.
            ProcessScanner.shared.refreshRemoteSummaryIfDue(force: true)
            self?.updateStatus()
        }
        actions.refreshHealth = { [weak self] completion in
            guard let self else { completion(NerfDetector.shared.snapshot()); return }
            self.refreshPanelHealth(completion: completion)
        }
        actions.syncPrices = { [weak self] completion in
            guard let self else { completion(L("应用不可用", "App unavailable"), false); return }
            self.runPriceSync(notifyWhenUnchanged: false, completion: completion)
        }
        actions.quit = { [weak self] in self?.quitAction() }
        actions.setAutoClean = { [weak self] on in self?.isAutoCleanEnabled = on }
        actions.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        actions.setThresholdNotify = { [weak self] on in self?.isThresholdNotifyEnabled = on }
        actions.setExitChangeNotify = { [weak self] on in self?.isExitChangeNotifyEnabled = on }
        actions.setFontScale = { value in UserDefaults.standard.set(value, forKey: UITheme.scaleKey) }
        actions.installProxy = { [weak self] in
            self?.closePanel()
            self?.installProxy()
        }
        actions.uninstallProxy = { [weak self] in
            self?.closePanel()
            self?.uninstallProxy()
        }
        actions.copyProxyPrefix = { [weak self] in self?.copyProxyPrefix() }
        actions.purgeLogs = { [weak self] in
            self?.closePanel()
            self?.purgeLogsAction()
        }
        actions.relayout = { [weak self] in self?.relayoutPanel() }
        actions.panelHeightChanged = { [weak self] height in
            guard let self, self.panelGeneration == generation, height.isFinite, height > 0 else { return }
            self.pendingPanelHeight = height
            self.relayoutPanel()
        }

        let dashboard = DashboardView(
            report: report,
            settings: PanelSettings(autoClean: isAutoCleanEnabled,
                                    launchAtLogin: isLaunchAtLoginEnabled(),
                                    thresholdNotify: isThresholdNotifyEnabled,
                                    exitChangeNotify: isExitChangeNotifyEnabled,
                                    fontScale: Double(UITheme.fontScale)),
            actions: actions
        )

        let hosting = SwipeHostingView(rootView: dashboard)
        hosting.delegateRef = self
        // Begin with a bounded frame; normal SwiftUI layout reports the complete panel height.
        // Asking fittingSize here would synchronously measure the entire tree while opening the panel.
        hosting.sizingOptions = []
        let initialHeight = min(400, DashboardView.maxPanelHeight)
        hosting.frame = NSRect(x: 0, y: 0, width: DashboardView.panelWidth, height: initialHeight)
        hostingView = hosting

        // A plain root container keeps NSPopover's sizing independent of NSHostingView's intrinsic layout.
        let container = NSView(frame: hosting.frame)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = hosting.frame.size
        panelPopover.contentViewController = controller
        panelPopover.contentSize = hosting.frame.size
        cachedPanelKey = panelKey

    }

    /// 启动时若距上次同步超过 7 天就后台补一次；失败静默，绝不打扰。
    private func autoSyncPricesIfStale() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = PriceSync.pricesPath(home: FileManager.default.homeDirectoryForCurrentUser.path)
            var last: Date?
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let sync = root["_sync"] as? [String: Any], let at = sync["at"] as? String {
                last = ISO8601DateFormatter().date(from: at)
            }
            guard last.map({ Date().timeIntervalSince($0) > 7 * 86400 }) ?? false else { return }
            self?.runPriceSync(notifyWhenUnchanged: false)
        }
    }

    private func runPriceSync(notifyWhenUnchanged: Bool, completion: ((String, Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = PriceSync.sync(home: FileManager.default.homeDirectoryForCurrentUser.path)
            let changed = !outcome.added.isEmpty || !outcome.updated.isEmpty
            if changed { UsageHistory.shared.refreshSoon() }
            DispatchQueue.main.async {
                let message: String
                if !outcome.error.isEmpty { message = outcome.error }
                else if changed {
                    message = L("新增 \(outcome.added.count) 个，更新 \(outcome.updated.count) 个。", "Added \(outcome.added.count), updated \(outcome.updated.count).")
                        + (outcome.skipped.isEmpty ? "" : L("仍有 \(outcome.skipped.count) 个模型缺价。", " \(outcome.skipped.count) models still have no rate."))
                } else {
                    message = outcome.skipped.isEmpty ? L("没有需要更新的自动价格。自定义覆盖已保留。", "No synced rates need updating. Custom overrides were kept.")
                        : L("这些模型仍未找到价格：\(outcome.skipped.prefix(4).joined(separator: ", "))", "No rates found for: \(outcome.skipped.prefix(4).joined(separator: ", "))")
                }
                if let completion { completion(message, outcome.error.isEmpty) }
                else if notifyWhenUnchanged || changed {
                    self?.sendNotification(title: outcome.error.isEmpty ? L("价格同步结果", "Pricing sync result") : L("价格同步失败", "Pricing sync failed"), body: message)
                }
            }
        }
    }

    /// SwiftUI reports the complete panel height after layout; resize without a second tree measurement.
    private func relayoutPanel() {
        guard isPanelOpen, !isRelayoutScheduled, let expectedHost = hostingView else { return }
        let generation = panelGeneration
        isRelayoutScheduled = true
        DispatchQueue.main.async { [weak self, weak expectedHost] in
            guard let self, self.panelGeneration == generation else { return }
            self.isRelayoutScheduled = false
            guard self.isPanelOpen, let h = expectedHost, self.hostingView === h,
                  let measuredHeight = self.pendingPanelHeight else { return }
            let maximumHeight = min(DashboardView.maxPanelHeight, max(120, ((h.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 24))
            let size = NSSize(width: DashboardView.panelWidth, height: min(max(120, measuredHeight), maximumHeight))
            guard let controller = self.panelPopover.contentViewController else { return }
            // The popover owns its window size; keep its content and the host in sync.
            let sizes = [h.frame.size, controller.view.frame.size, controller.preferredContentSize, self.panelPopover.contentSize]
            guard sizes.contains(where: { abs($0.height - size.height) > 1 || abs($0.width - size.width) > 1 }) else { return }
            // Set the popover first. Resizing its content view beforehand makes AppKit
            // skip the window resize even though contentSize still reports the old value.
            self.panelPopover.contentSize = size
            controller.preferredContentSize = size
            controller.view.setFrameSize(size)
            h.frame = NSRect(origin: .zero, size: size)
            self.log.debug("relayout reported height=\(Int(size.height))")
        }
    }

    // MARK: - Actions
    // kill 里有 300ms 等待，rm -rf 走盘：都不在主线程做
    @objc func cleanOrphansAction() {
        let targets = currentReport.orphans
        guard !targets.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ProcessScanner.shared.killProcesses(targets)
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: "清理完成",
                    body: "已释放 \(r.killed) 个断链 AI 进程，回收 \(String(format: "%.0f", r.freedMB)) MB 内存。" + (r.skipped > 0 ? "（\(r.skipped) 个已自行退出或 pid 变化，已跳过）" : "")
                )
                self?.updateStatus()
            }
        }
    }

    /// 删文件是不可逆动作 → 先弹确认，把"删什么、删多少、会失去什么、能不能捞回来"全写清楚
    @objc func purgeLogsAction() {
        let days = ProcessScanner.shared.logRetentionDays
        let items = currentReport.disk.filter { $0.purgeable && $0.oldMB >= 1 }
        let totalMB = items.reduce(0.0) { $0 + $1.oldMB }
        let totalFiles = items.reduce(0) { $0 + $1.oldFiles }
        guard totalFiles > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "清理 \(days) 天前的会话记录？"
        alert.informativeText = items.map {
            String(format: "· %@：%d 个文件 %.0f MB\n  %@", $0.label, $0.oldFiles, $0.oldMB, $0.note)
        }.joined(separator: "\n")
        + String(format: "\n\n合计 %d 个文件 %.2f GB，移入废纸篓（可恢复）。\n近 %d 天的一个都不动。",
                 totalFiles, totalMB / 1024, days)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ProcessScanner.shared.purgeOldSessionLogs(olderThanDays: days)
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: "会话记录已清理",
                    body: String(format: "%d 个文件、%.2f GB 已移入废纸篓。", r.files, r.freedMB / 1024)
                        + (r.failed > 0 ? "（\(r.failed) 个失败，多半是权限）" : "")
                )
                self?.updateStatus()
            }
        }
    }

    @objc func cleanNPXAction() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freedMB = ProcessScanner.shared.cleanNPXCache()
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: freedMB == nil ? L("NPX 清理结果待确认", "NPX cleanup result unconfirmed") : L("NPX 缓存已清理", "NPX cache cleared"),
                    body: freedMB.map { L("已清空 ~/.npm/_npx 目录，释放约 \(String(format: "%.1f", $0)) MB 磁盘空间。", "Cleared ~/.npm/_npx, freeing approximately \(String(format: "%.1f", $0)) MB.") }
                        ?? L("无法确认清理结果或释放空间，请检查目录后重试。", "Could not confirm the cleanup result or space freed. Check the directory before retrying.")
                )
                self?.updateStatus()
            }
        }
    }

    func installProxy() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var msg = "已安装并启动，前缀 \(ProxyManager.shared.prefix)，登录自启。"
            do { try ProxyManager.shared.install() } catch { msg = "安装失败：\(error.localizedDescription)" }
            DispatchQueue.main.async {
                self?.sendNotification(title: "API 记账代理", body: msg)
                self?.updateStatus()
            }
        }
    }

    func uninstallProxy() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ProxyManager.shared.uninstall()
            DispatchQueue.main.async {
                self?.sendNotification(title: "API 记账代理", body: "已停止并卸载。记账文件保留在 ~/.config/vibedeck/。")
                self?.updateStatus()
            }
        }
    }

    func copyProxyPrefix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProxyManager.shared.prefix, forType: .string)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                print("Toggle launch error: \(error)")
            }
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
