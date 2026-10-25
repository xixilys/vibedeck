import Cocoa
import SwiftUI
import Foundation

// Tool-only in-memory preferences. Never delegates writes to persistent CFPreferences.
public final class LifecycleMemoryDefaults: UserDefaults, @unchecked Sendable {
    public static let shared = LifecycleMemoryDefaults(suiteName: "vibedeck.lifecycle.ephemeral")!
    private var values: [String: Any] = [:]
    public override func object(forKey key: String) -> Any? { values[key] }
    public override func set(_ value: Any?, forKey key: String) {
        willChangeValue(forKey: key)
        values[key] = value
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    public override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    public override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    public override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    public override func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    public override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    public override func string(forKey key: String) -> String? { values[key] as? String }
    public override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    public override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    public override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    public override func dictionaryRepresentation() -> [String: Any] { values }
    public override func register(defaults registrationDictionary: [String: Any]) {
        for (key, value) in registrationDictionary where values[key] == nil { values[key] = value }
    }
    public override func synchronize() -> Bool { true }
}

public enum LifecycleHooks {
    public static var fixtureHome = ""
    static var availableScreenHeight: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["VG_LIFECYCLE_SCREEN_HEIGHT"],
           let height = Double(raw), height >= 400 { return CGFloat(height) }
        return NSScreen.main?.visibleFrame.height ?? 900
    }
    static var tab: Binding<Int>?
    static var detail: Binding<String?>?
    static var device: Binding<String>?
    static var report: Binding<ScanReport>?
    static var expanded: Binding<Bool>?
    static var usageExpanded: Binding<Bool>?
    static var platformsExpanded: Binding<Bool>?
    static var todayCLI: Binding<String>?
    static var selectedUsage: (() -> CLIUsage?)?
    static var usagePreview: (() -> AnyView)?
    static var refreshMounts: (() -> Void)?
    static var mountState: (() -> (Bool, [String: Bool]))?
    static let mountLock = NSLock()
    static let mountGate = DispatchSemaphore(value: 0)
    static var mountCalls = 0
    static var mountOnMain = false
    static func mountProbe(_ path: String) -> Bool {
        mountLock.lock(); mountCalls += 1; mountOnMain = mountOnMain || Thread.isMainThread; mountLock.unlock()
        // A broken main-thread implementation must fail without hanging the test process.
        guard !Thread.isMainThread else { return false }
        _ = mountGate.wait(timeout: .now() + 10)
        return true
    }
    static func mountObservations() -> (Int, Bool) {
        mountLock.lock(); defer { mountLock.unlock() }
        return (mountCalls, mountOnMain)
    }
    static var disclosureEnabled = false
    static var heights: [Double] = []
    static var relayoutRequests = 0
    static var collectorRequests = 0
    static var heightCallbacks: [(CGFloat) -> Void] = []
    static let fanLock = NSLock()
    static let fanGate = DispatchSemaphore(value: 0)
    static var fanBlocked = false
    static var fanCalls = 0
    static var fanOnMain = false
    static func fanSnapshot() -> Result<[FanReading], FanControlError> {
        fanLock.lock()
        fanCalls += 1; fanOnMain = fanOnMain || Thread.isMainThread
        let blocked = fanBlocked
        fanLock.unlock()
        if blocked { _ = fanGate.wait(timeout: .now() + 8) }
        return .success([FanReading(index: 0, currentRPM: 2750, targetRPM: 2750,
                                    minimumRPM: 1000, maximumRPM: 4900, isManual: true)])
    }
    static func releaseBindings() {
        tab = nil; detail = nil; device = nil; report = nil; expanded = nil
        usageExpanded = nil; platformsExpanded = nil; todayCLI = nil; selectedUsage = nil; usagePreview = nil
        refreshMounts = nil; mountState = nil
    }
}

// A stateful child tests the unchanged production scroll → Dashboard → AppDelegate chain.
// It is deliberately labeled synthetic; ordinary page tests leave this extra child absent.
struct LifecycleDisclosureFixture<Content: View>: View {
    let content: Content
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            if LifecycleHooks.disclosureEnabled {
                DisclosureGroup("LIFECYCLE FIXTURE", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<60, id: \.self) { i in
                            Text(L("验证详情 \(i)：展开后完整内容仍可到达。", "Fixture detail \(i): expanded content remains reachable at the bottom."))
                                .font(VG.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("FIXTURE BOTTOM").font(VG.body)
            }
        }
        .onAppear { LifecycleHooks.expanded = $expanded }
    }
}

func scrollView(_ view: NSView) -> SwipeScrollView? {
    if let s = view as? SwipeScrollView { return s }
    for child in view.subviews { if let s = scrollView(child) { return s } }
    return nil
}
func pump(_ seconds: TimeInterval, host: NSView? = nil) {
    let until = Date().addingTimeInterval(seconds)
    repeat {
        host?.layoutSubtreeIfNeeded()
        host?.displayIfNeeded()
        NSApplication.shared.updateWindows()
        // Dequeue through NSApplication so local event monitors participate in input checks.
        for _ in 0..<64 {
            guard let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                             inMode: .default, dequeue: true) else { break }
            NSApplication.shared.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    } while Date() < until
}
func fixtureReport(_ now: TimeInterval) -> ScanReport {
    var r = ScanReport()
    r.capturedAt = now
    r.totalMemoryGB = 32; r.usedMemoryGB = 20; r.freePercentage = 37
    r.diskTotalGB = 1000; r.diskFreeGB = 400; r.diskFreePct = 40
    r.detectedLLMs = [
        DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Pro", detail: "",
            fiveHour: QuotaWindow(usedPct: 0, resetsAt: now + 3600, capturedAt: now),
            sevenDay: QuotaWindow(usedPct: 100, resetsAt: now + 86400, capturedAt: now),
            secondaryPoolName: "3p",
            secondaryFiveHour: QuotaWindow(usedPct: 35, resetsAt: now + 3600, capturedAt: now),
            secondarySevenDay: QuotaWindow(usedPct: 67, resetsAt: now + 86400, capturedAt: now)),
        DetectedLLMRuntime(name: "Codex", isRunning: true, tier: "Pro", detail: "",
            fiveHour: QuotaWindow(usedPct: 28, resetsAt: now + 3600, capturedAt: now),
            sevenDay: QuotaWindow(usedPct: 75, resetsAt: now + 86400, capturedAt: now))]
    r.remoteHosts = ["fixture-single", "fixture-old", "fixture-offline", "fixture-missing", "fixture-expired", "fixture-undated"]
    for (host, pct, capture, reset) in [
        ("fixture-single", 31, now, now + 3600), ("fixture-old", 71, now - 1200, now + 3600),
        ("fixture-offline", 42, now, now + 3600), ("fixture-expired", 99, now - 60, now - 1)] {
        r.remoteLLMs[host] = [DetectedLLMRuntime(name: "Codex", isRunning: false, tier: "Pro", detail: "",
            fiveHour: QuotaWindow(usedPct: pct, resetsAt: reset, capturedAt: capture))]
        r.remoteDeviceStatus[host] = RemoteDeviceStatus(lastSuccess: now, lastAttempt: now)
    }
    r.remoteDeviceStatus["fixture-offline"] = RemoteDeviceStatus(lastSuccess: now - 3600, lastAttempt: now, error: "fixture offline")
    r.remoteLLMs["fixture-undated"] = [DetectedLLMRuntime(name: "Claude", isRunning: false, tier: "", detail: "",
        fiveHour: QuotaWindow(usedPct: 64, resetsAt: now + 3600, capturedAt: nil))]
    r.cliUsage = [CLIUsage(name: "Claude Code", requests: 120, ctx: 950000, cacheRead: 650000, out: 8000, think: 2500),
                  CLIUsage(name: "Grok", turns: 7, note: L("本地无 token 统计，仅轮次", "Local tokens unavailable; turns only")),
                  CLIUsage(name: "Gemini", note: L("本地无 token 统计（额度见上）", "Local tokens unavailable; see quotas above"))]
    return r
}
func fixtureHistory(_ now: TimeInterval) -> UsageHistory.Snapshot {
    var s = UsageHistory.Snapshot()
    s.capturedAt = now; s.activeDays = 12
    var t = UsageHistory.Totals()
    t.ctx = 950000; t.cacheRead = 650000; t.out = 8000; t.think = 2500; t.turns = 120; t.sessions = 4
    t.models = ["gpt-6.1-sol": UsageHistory.ModelTotals(ctx: 950000, cacheRead: 650000, out: 8000, think: 2500)]
    s.totals = ["Claude": t, "Codex · fixture-single": t]
    s.aggregate = t; s.todayBySource = s.totals
    for offset in 0..<12 {
        let key = UsageHistory.dayKey(timestamp: now - Double(offset) * 86400)
        s.days.append(UsageHistory.Day(date: key, sources: s.totals))
        s.dailyTokens[key] = t.tokenTotal
    }
    s.days.reverse(); s.earliestDate = s.days.first?.date
    return s
}

setbuf(stdout, nil)
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--input-receiver" {
    PanelInputCheck.receiver(directory: CommandLine.arguments[2])
    exit(0)
}
let output = CommandLine.arguments[1]
LifecycleHooks.fixtureHome = CommandLine.arguments[2]
precondition(NSHomeDirectory() == LifecycleHooks.fixtureHome, "Foundation home must be the empty fixture directory")
precondition(FileManager.default.homeDirectoryForCurrentUser.path == LifecycleHooks.fixtureHome,
             "FileManager home must be the empty fixture directory")
let scale = Double(CommandLine.arguments[3])!
let requestedLanguage = CommandLine.arguments.last!.contains("zh") ? "zh-Hans" : "en"
// Preserve the language in the volatile argument domain, never persistent preferences.
UserDefaults.standard.setVolatileDomain(["AppleLanguages": [requestedLanguage]], forName: UserDefaults.argumentDomain)
let language = Locale.preferredLanguages.first ?? "unknown"
precondition(language.hasPrefix(requestedLanguage.contains("zh") ? "zh" : "en"), "Actual Locale must match the requested matrix language")
print("LANGUAGE requested=\(requestedLanguage) actual=\(language)")
let override = ProcessInfo.processInfo.environment["VG_LIFECYCLE_SCREEN_HEIGHT"] ?? ""
let tag = "\(language)-\(scale)" + (override.isEmpty ? "" : "-screen\(override)")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Do not set app.delegate and do not call applicationDidFinishLaunching.
app.finishLaunching()
let defaults = LifecycleMemoryDefaults.shared
defaults.set(scale, forKey: UITheme.scaleKey)
defaults.set(0, forKey: "vg.tab")
defaults.set("all", forKey: "vg.device")
defaults.set(true, forKey: "vg.fiveTabsMigrated")
defaults.set(false, forKey: "autoCleanEnabled")
let now = Date().timeIntervalSince1970
let report = fixtureReport(now)
UsageHistory.shared.lifecycleSet(fixtureHistory(now))
var network = NetworkSnapshot()
network.capturedAt = now
network.aiExits = (0..<12).map { i in
    var exit = AIExitStatus(id: "fixture-\(i)", name: "Fixture endpoint \(i)", host: "example.invalid")
    exit.ip = "192.0.2.\(i + 1)"; exit.loc = "US"; exit.capturedAt = now
    return exit
}
NetworkScanner.shared.lifecycleSet(network)
if ProcessInfo.processInfo.environment["VG_LIFECYCLE_GEOMETRY_ONLY"] == "1" {
    let delegate = AppDelegate()
    delegate.lifecyclePrepare(report)
    pump(0.4) // Let NSStatusItem acquire its real menu-bar window before show(relativeTo:).
    var records: [[String: Any]] = []
    var interactionRows: [[String: Any]] = []
    func captureGeometry(_ host: NSView, _ name: String) {
        let popover = delegate.lifecyclePopover
        guard let window = host.window, let controller = popover.contentViewController else {
            records.append(["page": name, "error": "popover disappeared before measurement"]); return
        }
        func target(_ id: String) -> NSView? { LifecycleInputTarget.target(id, window: window) }
        func rect(_ view: NSView?) -> Any {
            guard let view else { return NSNull() }
            return ["class": String(describing: type(of: view)).components(separatedBy: "<").first!, "frame": NSStringFromRect(view.frame),
                    "bounds": NSStringFromRect(view.bounds), "visibleRect": NSStringFromRect(view.visibleRect),
                    "windowRect": NSStringFromRect(view.convert(view.bounds, to: nil)),
                    "hostRect": NSStringFromRect(view.convert(view.bounds, to: host)), "flipped": view.isFlipped] as [String: Any]
        }
        let sizes = [host.frame.size, controller.view.frame.size, controller.preferredContentSize, popover.contentSize]
        let equal = sizes.dropFirst().allSatisfy { abs($0.width - sizes[0].width) <= 1 && abs($0.height - sizes[0].height) <= 1 }
        let visible = ["header": "geometry.header", "gear": "settings.open", "footer": "geometry.footer"].mapValues { id in
            target(id).map { $0.visibleRect.contains($0.bounds) } ?? false
        }
        let row: [String: Any] = ["page": name, "host": rect(host), "hostFitting": NSStringFromSize(host.fittingSize),
            "popoverContentSize": NSStringFromSize(popover.contentSize), "preferredContentSize": NSStringFromSize(controller.preferredContentSize),
            "controllerView": rect(controller.view), "windowFrame": NSStringFromRect(window.frame), "windowContent": rect(window.contentView),
            "hostSuperview": rect(host.superview), "gear": rect(target("settings.open")), "header": rect(target("geometry.header")), "footer": rect(target("geometry.footer")),
            "fullyVisible": visible, "allFourSizesMatch": equal,
            "windowNumber": window.windowNumber, "viewport": rect(scrollView(host)),
            "document": rect(scrollView(host)?.documentView), "pendingReportedHeight": delegate.lifecyclePendingHeight ?? -1]
        records.append(row)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: output + "/geometry-" + name + "-host.png"))
            }
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output + "/geometry-" + name + "-window.png"]
        try? capture.run(); capture.waitUntilExit()
    }
    func clickGear(_ host: NSView) -> Bool {
        guard let window = host.window, let gear = LifecycleInputTarget.target("settings.open", window: window) else { return false }
        let rect = gear.convert(gear.bounds, to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { return false }
            app.postEvent(event, atStart: false)
        }
        pump(0.4, host: host)
        return true
    }
    for (name, tab) in [("overview", 0), ("stats", 2)] {
        let host = delegate.lifecycleOpen()
        pump(0.3, host: host)
        LifecycleHooks.tab?.wrappedValue = tab
        pump(0.7, host: host)
        captureGeometry(host, name)
        if name == "overview" {
            let opened = clickGear(host) && LifecycleHooks.detail?.wrappedValue == DashboardView.settingsPage
            interactionRows.append(["case": "native-gear-opens-Settings", "passed": opened])
            captureGeometry(host, "settings")
            let returned = opened && clickGear(host) && LifecycleHooks.detail?.wrappedValue == nil
            interactionRows.append(["case": "native-gear-returns-from-Settings", "passed": returned])
            captureGeometry(host, "back")
        }
        delegate.lifecycleClose(); pump(0.1)
        LifecycleHooks.releaseBindings()
    }
    let result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "language": language, "scale": scale, "rows": records, "interactions": interactionRows]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: output + "/geometry.json"))
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}
if ProcessInfo.processInfo.environment["VG_LIFECYCLE_INPUT_ONLY"] == "1" {
    let valid = PanelInputCheck.run(output: output, language: language, scale: scale, report: report)
    exit(valid ? 0 : 1)
}
if let nativeOutput = ProcessInfo.processInfo.environment["VG_LIFECYCLE_NATIVE_OUTPUT"] {
    let valid = NativePopupCheck.run(output: nativeOutput, metadataDirectory: output, language: language,
        appearance: ProcessInfo.processInfo.environment["VG_LIFECYCLE_APPEARANCE"] ?? "light", report: report)
    exit(valid ? 0 : 1)
}
var results: [[String: Any]] = []
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message); print("FAIL \(message)") }
}
func geometry(_ host: NSView, _ label: String) {
    guard let scroll = scrollView(host), let document = scroll.documentView else {
        check(false, "\(label): missing production SwipeScroll"); return
    }
    let before = document.frame
    let y = document.isFlipped ? document.bounds.maxY - 3 : document.bounds.minY
    _ = document.scrollToVisible(NSRect(x: 1, y: y, width: max(1, document.bounds.width - 2), height: 3))
    scroll.reflectScrolledClipView(scroll.contentView)
    pump(0.12, host: host)
    let bottom = document.isFlipped ? document.visibleRect.maxY >= document.bounds.maxY - 1 : document.visibleRect.minY <= document.bounds.minY + 1
    check(bottom, "\(label): programmatic bottom unreachable")
    check(abs(host.frame.width - DashboardView.panelWidth) <= 1, "\(label): outer width drift")
    check(abs(document.frame.width - (DashboardView.panelWidth - 24)) <= 1, "\(label): document width drift")
    check(before.height > 0 && host.frame.height > 0, "\(label): zero height")
    check(document.frame.width <= scroll.contentSize.width + 1, "\(label): horizontal overflow")
    let maximumHeight = min(DashboardView.maxPanelHeight, max(120, LifecycleHooks.availableScreenHeight - 24))
    let chromeHeight = host.fittingSize.height - scroll.frame.height
    check(scroll.frame.height <= max(120, maximumHeight - chromeHeight) + 1, "\(label): viewport exceeds panel content bound")
    check(host.frame.height <= maximumHeight + 1, "\(label): outer height exceeds screen bound")
    let naturalSize = host.fittingSize
    check(abs(host.frame.height - naturalSize.height) <= 2, "\(label): outer host does not match natural panel height")
    results.append(["case": label, "host": NSStringFromRect(host.frame), "document": NSStringFromRect(document.frame),
        "naturalSize": NSStringFromSize(naturalSize), "viewport": NSStringFromRect(scroll.frame), "bottomReachable": bottom, "availableScreenHeight": LifecycleHooks.availableScreenHeight, "heightCallbackCount": LifecycleHooks.heights.count,
        "relayoutRequests": LifecycleHooks.relayoutRequests])
}
func capture(_ host: NSView, _ name: String) {
    host.layoutSubtreeIfNeeded()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        // Native cacheDisplay can have transparent pixels; composite those on white
        // for a readable diagnostic PNG without changing the view or its geometry.
        guard let opaque = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: opaque) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSColor.white.setFill(); bounds.fill()
        rep.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        if let data = opaque.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(output)/\(tag)-\(name).png"))
        }
    }
}
func settleLayout(_ host: NSView) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    var previous = [host.frame.height, scrollView(host)?.documentView?.frame.height ?? 0,
                    CGFloat(LifecycleHooks.heights.count), CGFloat(LifecycleHooks.relayoutRequests)]
    var stableSince = Date()
    while Date() < deadline {
        pump(0.05, host: host)
        let current = [host.frame.height, scrollView(host)?.documentView?.frame.height ?? 0,
                       CGFloat(LifecycleHooks.heights.count), CGFloat(LifecycleHooks.relayoutRequests)]
        if current != previous { previous = current; stableSince = Date() }
        if Date().timeIntervalSince(stableSince) >= 0.2 { return true }
    }
    return false
}
let section = UnifiedQuotaSection(report: report, scope: .all, now: now, openLocal: { _ in }, openDevice: { _ in })
let readings = section.lifecycleReadings()
check(readings.map { $0["host"] as! String } == ["local", "fixture-single", "fixture-old", "fixture-offline"], "quota omission/group order")
check(readings.first?["percentages"] as? [Int] == [0, 100, 35, 67, 28, 75], "six local windows and true zero/full")
check(readings.first?["trusted"] as? [Bool] == Array(repeating: true, count: 6), "fresh readings trusted")
check(readings.suffix(2).allSatisfy { $0["trusted"] as? [Bool] == [false] }, "old/offline remain untrusted")
check(QuotaPresentation.ringFraction(usedPct: 0) == 0 && QuotaPresentation.ringFraction(usedPct: 100) == 1, "zero/full fractions")
results.append(["case": "quota-filtering", "readings": readings])
for empty in [false, true] {
    autoreleasepool {
        let quota = UnifiedQuotaSection(report: empty ? ScanReport() : report, scope: .all, now: now,
                                       openLocal: { _ in }, openDevice: { _ in })
        let host = NSHostingView(rootView: quota.padding(12).frame(width: DashboardView.panelWidth)
            .background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        pump(0.15, host: host)
        capture(host, empty ? "quota-empty" : "quota-mixed-six-one")
        check(abs(host.frame.width - DashboardView.panelWidth) <= 1, "quota fixture panel width")
        results.append(["case": empty ? "quota-empty" : "quota-mixed-six-one", "frame": NSStringFromRect(host.frame)])
        window.contentView = nil; window.close()
    }
}
let delegate = AppDelegate()
delegate.lifecyclePrepare(report)
// The production NSPopover retains its real hosting window; never reparent the view.
func attach(_ host: NSView) {
    check(host.window != nil && delegate.lifecyclePopoverShown, "real NSPopover owns the host")
}
func detach() { LifecycleHooks.releaseBindings() }

autoreleasepool {
    let host = delegate.lifecycleOpen(); attach(host)
    pump(0.65, host: host)
    check(LifecycleHooks.tab != nil, "Dashboard onAppear bridge")
    for tab in 0..<5 {
        NotificationCenter.default.post(name: .selectVibeDeckTab, object: tab)
        pump(0.45, host: host)
        check(LifecycleHooks.tab?.wrappedValue == tab, "tab \(tab) selection")
        geometry(host, "page-\(tab)")
    }
    NotificationCenter.default.post(name: .selectVibeDeckTab, object: 0)
    pump(0.4, host: host)
    let collapsed = scrollView(host)?.documentView?.frame.height ?? 0
    LifecycleHooks.platformsExpanded?.wrappedValue = true
    pump(0.4, host: host)
    check((scrollView(host)?.documentView?.frame.height ?? 0) > collapsed + 15, "real local-platform disclosure expands")
    geometry(host, "real-platforms-expanded")
    LifecycleHooks.platformsExpanded?.wrappedValue = false
    pump(0.4, host: host)
    check(abs((scrollView(host)?.documentView?.frame.height ?? 0) - collapsed) <= 2, "real local-platform disclosure collapses")
    for cli in ["Grok", "Gemini"] {
        LifecycleHooks.todayCLI?.wrappedValue = cli
        LifecycleHooks.usageExpanded?.wrappedValue = true
        pump(0.4, host: host)
        let selected = LifecycleHooks.selectedUsage?()
        check(selected?.name == cli && selected?.hasTokens == false, "\(cli) selected unknown-token row retained")
        geometry(host, "unknown-cli-\(cli)")
        if let scroll = scrollView(host), let doc = scroll.documentView {
            capture(doc, "unknown-cli-\(cli)-document")
        }
        if let preview = LifecycleHooks.usagePreview?() {
            let previewHost = NSHostingView(rootView: preview)
            previewHost.frame = NSRect(origin: .zero, size: previewHost.fittingSize)
            let previewWindow = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: previewHost.frame.size),
                                         styleMask: .borderless, backing: .buffered, defer: false)
            previewWindow.isReleasedWhenClosed = false
            previewWindow.contentView = previewHost
            pump(0.15, host: previewHost)
            capture(previewHost, "unknown-cli-\(cli)-detail")
            previewWindow.contentView = nil; previewWindow.close()
        }
    }
    LifecycleHooks.usageExpanded?.wrappedValue = false
    LifecycleHooks.todayCLI?.wrappedValue = "Claude Code"
    pump(0.3, host: host)
    var published = report
    published.capturedAt = now + 1
    published.diskStatsKnown = true
    delegate.lifecyclePublish(published)
    pump(5.25, host: host)
    check(LifecycleHooks.report?.wrappedValue.capturedAt == published.capturedAt &&
          LifecycleHooks.report?.wrappedValue.diskStatsKnown == true,
          "visible five-second tick receives the newly completed AppDelegate snapshot")
    geometry(host, "cached-report-published")
    for detail in ["Claude", DashboardView.healthPage, DashboardView.pricesPage] {
        LifecycleHooks.detail?.wrappedValue = detail
        pump(0.45, host: host)
        geometry(host, "detail-\(detail)")
        LifecycleHooks.detail?.wrappedValue = nil
        pump(0.35, host: host)
        geometry(host, "return-\(detail)")
    }
    if let scroll = scrollView(host), let doc = scroll.documentView {
        let top = doc.isFlipped ? doc.bounds.minY : max(0, doc.bounds.maxY - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.1, host: host)
    }
    capture(host, "overview")
    detach(); delegate.lifecycleClose()
}
pump(0.2)
check(delegate.lifecycleHost == nil && !delegate.lifecycleContentPresent && !delegate.lifecycleVisible &&
      delegate.lifecycleMonitorCount == 0, "popover close clears host/controller/visibility/monitors")

LifecycleHooks.disclosureEnabled = true
autoreleasepool {
    let host = delegate.lifecycleOpen(); attach(host)
    pump(0.5, host: host)
    let collapsed = scrollView(host)?.documentView?.frame.height ?? 0
    check(LifecycleHooks.expanded != nil, "internal disclosure binding")
    LifecycleHooks.expanded?.wrappedValue = true
    pump(0.55, host: host)
    let expanded = scrollView(host)?.documentView?.frame.height ?? 0
    check(expanded > collapsed + 500, "internal disclosure expansion propagates without five-second tick")
    geometry(host, "internal-disclosure-expanded")
    LifecycleHooks.expanded?.wrappedValue = false
    pump(0.55, host: host)
    check(abs((scrollView(host)?.documentView?.frame.height ?? 0) - collapsed) <= 2, "internal disclosure collapse restores height")
    geometry(host, "internal-disclosure-collapsed")
    let settledRequests = LifecycleHooks.relayoutRequests
    pump(0.25, host: host)
    check(LifecycleHooks.relayoutRequests == settledRequests, "height feedback settles after collapse")
    detach(); delegate.lifecycleClose()
}
LifecycleHooks.disclosureEnabled = false
pump(0.2)

// Hold the actual mount-existence operation in the copied source, not the UI queue.
defaults.set("slow-fixture=/fixture/slow", forKey: "mountRoots")
autoreleasepool {
    let host = delegate.lifecycleOpen(); attach(host)
    pump(0.3, host: host)
    NotificationCenter.default.post(name: .selectVibeDeckTab, object: 4)
    pump(0.25, host: host)
    for _ in 0..<20 { LifecycleHooks.refreshMounts?() }
    var mainRan = false
    DispatchQueue.main.async { mainRan = true }
    pump(0.2, host: host)
    let observed = LifecycleHooks.mountObservations()
    check(observed.0 == 1 && !observed.1, "delayed mount check is single-flight and off main")
    check(mainRan, "main queue remains runnable while mount check waits")
    check(LifecycleHooks.mountState?().0 == true && LifecycleHooks.mountState?().1.isEmpty == true,
          "in-flight mount remains unknown rather than unavailable")
    LifecycleHooks.mountGate.signal()
    pump(0.3, host: host)
    check(LifecycleHooks.mountState?().0 == false && LifecycleHooks.mountState?().1["/fixture/slow"] == true,
          "completed mount result publishes to current dashboard")
    geometry(host, "delayed-mount-check")
    results.append(["case": "mount-nonblocking", "calls": observed.0, "onMain": observed.1, "mainRan": mainRan])
    NotificationCenter.default.post(name: .selectVibeDeckTab, object: 0)
    pump(0.15, host: host)
    detach(); delegate.lifecycleClose()
}
weak var mountClosedHost: NSView?
autoreleasepool {
    let host = delegate.lifecycleOpen(); attach(host); mountClosedHost = host
    pump(0.25, host: host)
    NotificationCenter.default.post(name: .selectVibeDeckTab, object: 4)
    pump(0.25, host: host)
    check(LifecycleHooks.mountObservations().0 == 2, "second host starts its own delayed mount check")
    detach(); delegate.lifecycleClose()
}
pump(0.2)
let releasedWhileBlocked = mountClosedHost == nil
check(releasedWhileBlocked, "closed hosting view releases while mount stat remains blocked")
LifecycleHooks.mountGate.signal()
pump(0.3)
results.append(["case": "mount-close-while-blocked", "hostReleasedBeforeStatReturns": releasedWhileBlocked])
defaults.removeObject(forKey: "mountRoots")
defaults.set(0, forKey: "vg.tab")
pump(0.2)

weak var oldHost: NSView?
weak var reopenedHost: NSView?
autoreleasepool {
    let old = delegate.lifecycleOpen(); attach(old)
    pump(0.35, host: old)
    oldHost = old
    let staleHeight = LifecycleHooks.heightCallbacks.last
    check(staleHeight != nil, "candidate panel-height callback captured for stale-delivery test")
    // Enqueue both content-state and AppDelegate callbacks, close/reopen before draining them.
    LifecycleHooks.detail?.wrappedValue = "Claude"
    delegate.lifecycleRequestLayout()
    detach(); delegate.lifecycleClose()
    let fresh = delegate.lifecycleOpen(); attach(fresh); reopenedHost = fresh
    pump(0.6, host: fresh)
    check(delegate.lifecycleHost === fresh, "rapid reopen keeps fresh host")
    check(LifecycleHooks.detail?.wrappedValue == nil, "queued old detail state does not affect reopened panel")
    check(settleLayout(fresh), "fresh host reaches stable layout before explicit stale callback")
    let freshHeight = fresh.frame.height
    let pendingBefore = delegate.lifecyclePendingHeight
    let requestsBefore = LifecycleHooks.relayoutRequests
    staleHeight?(9999)
    let pendingAfter = delegate.lifecyclePendingHeight
    check(pendingAfter == pendingBefore, "stale generation cannot replace current pending panel height")
    check(LifecycleHooks.relayoutRequests == requestsBefore, "stale generation cannot schedule current relayout")
    pump(0.15, host: fresh)
    check(abs(fresh.frame.height - freshHeight) <= 1, "stale height callback cannot resize reopened panel")
    results.append(["case": "explicit-stale-generation", "heightBefore": freshHeight,
        "heightAfter": fresh.frame.height, "pendingBefore": pendingBefore.map { Double($0) } as Any? ?? NSNull(),
        "pendingAfter": pendingAfter.map { Double($0) } as Any? ?? NSNull(),
        "relayoutRequestDelta": LifecycleHooks.relayoutRequests - requestsBefore])
    geometry(fresh, "rapid-reopen-after-stale-queue")
    detach(); delegate.lifecycleClose()
}
LifecycleHooks.heightCallbacks.removeAll()
pump(0.5)
check(oldHost == nil && reopenedHost == nil, "old and reopened hosting views released after autoreleasepool")
let readsAfterClose = delegate.lifecycleReads
pump(5.25)
check(delegate.lifecycleReads == readsAfterClose, "hidden hosts produce no five-second report reads")
results.append(["case": "release-and-hidden", "oldReleased": oldHost == nil, "newReleased": reopenedHost == nil,
    "hiddenReadDelta": delegate.lifecycleReads - readsAfterClose])
let result: [String: Any] = ["valid": failures.isEmpty, "language": language, "scale": scale, "results": results, "failures": failures,
    "screenHeightOverride": override, "actualMainScreenVisibleFrame": NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero),
    "scope": "Actual copied transient NSPopover/Dashboard/AppDelegate/SwipeScroll; programmatic native lifecycle and geometry; synthetic data and injected state bindings; no collectors/hardware; no NSMenu tracking, external wheel or status-bar clicks; -Onone, no performance conclusion"]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(output)/\(tag).json"))
print(failures.isEmpty ? "PASS lifecycle/geometry" : "FAIL lifecycle/geometry: \(failures.count)")
exit(failures.isEmpty ? 0 : 1)
