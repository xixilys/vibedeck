// Tool-only complete-app native NSMenu driver. Production main is excluded.
// Source copies isolate automatic writes; no keyboard/mouse content is logged.
import Cocoa
import Darwin

private func emit(_ tag: String, _ fields: [String: Any]) {
    var record = fields
    record["pid"] = ProcessInfo.processInfo.processIdentifier
    record["uptime"] = ProcessInfo.processInfo.systemUptime
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { exit(1) }
    print("\(tag) \(json)"); fflush(stdout)
}

enum BenchmarkAudit {
    private static var observers: [NSObjectProtocol] = []
    private static var monitor: Any?
    static func note(_ name: String, _ extra: [String: Any] = [:]) {
        var fields = extra
        fields["event"] = name
        fields["own_app_active"] = NSApplication.shared.isActive
        emit("VG_AUDIT", fields)
    }
    static func start() {
        let center = NotificationCenter.default
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "own_didBecomeActive"),
                              (NSApplication.didResignActiveNotification, "own_didResignActive"),
                              (NSApplication.didChangeScreenParametersNotification, "screen_parameters_changed")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in note(label) })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in note("active_space_changed") })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            // Only event type and Escape classification. Never characters,
            // other apps, window titles, typed content, or global input hooks.
            var fields: [String: Any] = ["type": event.type.rawValue]
            if event.type == .keyDown { fields["escape"] = event.keyCode == 53 }
            note("own_received_event", fields)
            return event
        }
    }
}

private final class AppBenchmarkDriver {
    struct Phase {
        let name: String; let round: Int; let start: Double; let cpu: Double; let reports: Int
    }
    let delegate: AppDelegate
    let captureOnly = ProcessInfo.processInfo.environment["VG_CAPTURE_ONLY"] == "1"
    let language = ProcessInfo.processInfo.environment["VG_APP_LANGUAGE"] ?? "zh-Hans"
    private var timers: [Timer] = []
    private var phaseTimer: Timer?
    private var sampleTimer: Timer?
    private var phase: Phase?
    private var samples: [[String: Any]] = []
    private var integrity = true
    private var round = 0
    private var began = false
    private var validWindows = 0
    private var invalidWindows = 0
    private var captures = 0
    private let start = ProcessInfo.processInfo.systemUptime
    init(delegate: AppDelegate) { self.delegate = delegate }
    private func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
    private func state() -> [String: Any] {
        var loads = [Double](repeating: 0, count: 3)
        let count = loads.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        return ["hostAlive": delegate.benchmarkHostAlive, "visible": delegate.benchmarkMenuVisible,
                "statusIconPresent": delegate.benchmarkStatusIconPresent, "reports": delegate.benchmarkReportCount,
                "data_counts": delegate.benchmarkDataCounts, "language": Locale.preferredLanguages.first ?? "unknown",
                "system_loadavg": count > 0 ? Array(loads.prefix(Int(count))) : [],
                "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                "own_app_active": NSApplication.shared.isActive]
    }
    @discardableResult private func after(_ seconds: Double, _ action: @escaping () -> Void) -> Timer {
        timers.removeAll { !$0.isValid }
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in action() }
        timers.append(timer); RunLoop.main.add(timer, forMode: .common); return timer
    }
    private func fatal(_ message: String) -> Never {
        var fields = state(); fields["error"] = message; emit("VG_ERROR", fields); exit(1)
    }
    func scheduleAfterLaunch() {
        guard !began else { return }; began = true
        after(0.05) { [self] in begin() }
    }
    private func begin() {
        guard (Locale.preferredLanguages.first ?? "").hasPrefix(language) else { fatal("Actual locale does not match requested language") }
        guard delegate.benchmarkMenuReady else { fatal("AppDelegate menu not initialized") }
        emit("VG_START", ["rounds": captureOnly ? 0 : 3, "closed_duration": 60, "opened_duration": 60,
                          "capture_only": captureOnly, "language_requested": language, "safety_seconds": captureOnly ? 70 : 450])
        if captureOnly { after(20) { [self] in capture(index: 0) } }
        else { open(prewarm: true) }
    }
    private func point() -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { fatal("No visible screen") }
        return NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 2)
    }
    private func beginPhase(_ name: String) {
        guard phase == nil else { fatal("Overlapping phases") }
        let current = Phase(name: name, round: round, start: now(), cpu: cpu(), reports: delegate.benchmarkReportCount)
        phase = current; samples = []; integrity = delegate.benchmarkMenuVisible == (name == "opened")
        var previousTime = current.start, previousCPU = current.cpu
        let sampler = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let active = self.phase, active.round == current.round, active.name == current.name else { return }
            let time = self.now(), used = self.cpu()
            if self.delegate.benchmarkMenuVisible != (name == "opened") { self.integrity = false }
            self.samples.append(["offset_seconds": time - active.start, "elapsed_seconds": time - previousTime,
                                 "cpu_seconds": used - previousCPU, "cpu_percent_one_core": (used - previousCPU) / max(time - previousTime, 0.000001) * 100])
            previousTime = time; previousCPU = used
        }
        sampleTimer = sampler; RunLoop.main.add(sampler, forMode: .common)
        var fields = state(); fields["phase"] = name; fields["round"] = round; fields["duration"] = 60
        emit("VG_PHASE", fields)
        phaseTimer = after(60) { [self] in
            guard let active = phase, active.round == current.round, active.name == current.name else { return }
            endPhase(valid: delegate.benchmarkMenuVisible == (name == "opened"), reason: "scheduled_end")
            if name == "opened" { BenchmarkAudit.note("driver_scheduled_cancel"); delegate.benchmarkCancelMenu() }
            else {
                if delegate.benchmarkMenuVisible { delegate.benchmarkCancelMenu() }
                after(1) { [self] in open(prewarm: false) }
            }
        }
    }
    private func endPhase(valid: Bool, reason: String) {
        guard let measured = phase else { return }
        phaseTimer?.invalidate(); phaseTimer = nil; sampleTimer?.invalidate(); sampleTimer = nil
        let elapsed = now() - measured.start, used = cpu() - measured.cpu
        let accepted = valid && integrity && elapsed >= 59 && delegate.benchmarkStatusIconPresent
        var fields = state()
        fields["phase"] = measured.name; fields["round"] = measured.round; fields["duration"] = 60
        fields["elapsed"] = elapsed; fields["cpu_seconds"] = used; fields["cpu_percent_one_core"] = used / max(elapsed, 0.000001) * 100
        fields["report_delta"] = delegate.benchmarkReportCount - measured.reports
        fields["valid"] = accepted; fields["reason"] = reason; fields["raw_samples"] = samples
        emit("VG_END", fields)
        if accepted { validWindows += 1 } else { invalidWindows += 1 }
        phase = nil
    }
    private func nextRound() {
        if round < 3 { after(1) { [self] in closed() } }
        else { after(1) { [self] in finish() } }
    }
    private func closed() { round += 1; beginPhase("closed") }
    private func open(prewarm: Bool) {
        let openedAt = now()
        let windowCountBefore = validWindows + invalidWindows
        let prepare = after(2) { [self] in
            if prewarm {
                emit("VG_PREWARM", state()); BenchmarkAudit.note("driver_prewarm_cancel"); delegate.benchmarkCancelMenu()
            } else if delegate.benchmarkMenuVisible { beginPhase("opened") }
        }
        delegate.benchmarkPopUp(at: point())
        prepare.invalidate()
        if prewarm { after(20) { [self] in closed() }; return }
        if phase?.name == "opened" { endPhase(valid: false, reason: "unexpected_native_popup_close_cause_unknown") }
        else if validWindows + invalidWindows == windowCountBefore {
            invalidWindows += 1
            var fields = state(); fields["phase"] = "opened"; fields["round"] = round; fields["duration"] = 60
            fields["elapsed"] = 0; fields["popup_elapsed_seconds"] = now() - openedAt
            fields["valid"] = false; fields["reason"] = "popup_returned_before_phase_cause_unknown"
            fields["cpu_percent_one_core"] = NSNull(); fields["raw_samples"] = []
            emit("VG_END", fields)
        }
        // A premature close is an invalid window, not a successful 60s zero.
        // Its timer has been invalidated before another round is allowed.
        nextRound()
    }
    private func capture(index: Int) {
        guard index < 2 else { finish(); return }
        guard let directory = ProcessInfo.processInfo.environment["VG_CAPTURE_DIRECTORY"] else { fatal("Capture directory missing") }
        let style = index == 0 ? "light" : "dark"
        NSApplication.shared.appearance = NSAppearance(named: index == 0 ? .aqua : .darkAqua)
        var captured = false
        let timer = after(0.8) { [self] in
            if delegate.benchmarkMenuVisible, let number = delegate.benchmarkWindowNumber {
                do {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let path = directory + "/live-" + (language.hasPrefix("zh") ? "zh" : "en") + "-" + style + "-overview.png"
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-l", String(number), path]
                    try process.run(); process.waitUntilExit()
                    captured = process.terminationStatus == 0
                    var fields = state(); fields["path"] = path; fields["appearance"] = style
                    fields["outside_timing"] = true; fields["valid"] = captured; emit("VG_CAPTURE", fields)
                    if captured { captures += 1 }
                } catch { emit("VG_CAPTURE_ERROR", ["error": String(describing: error), "appearance": style]) }
            }
            BenchmarkAudit.note("driver_capture_cancel"); delegate.benchmarkCancelMenu()
        }
        delegate.benchmarkPopUp(at: point()); timer.invalidate()
        if !captured { emit("VG_CAPTURE_INVALID", ["appearance": style, "reason": "capture_unavailable_or_popup_closed_early"]) }
        after(1) { [self] in capture(index: index + 1) }
    }
    private func finish() {
        phaseTimer?.invalidate(); sampleTimer?.invalidate()
        var fields = state(); fields["rounds"] = round; fields["valid_windows"] = validWindows
        fields["invalid_windows"] = invalidWindows; fields["captures"] = captures; fields["capture_only"] = captureOnly
        fields["elapsed"] = now() - start; emit("VG_FINISH", fields)
        timers.forEach { $0.invalidate() }; NSApplication.shared.terminate(nil)
    }
}

@main private struct PanelAppBenchmark {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--inspect-status-pid", let pid = Int(arguments[2]) {
            let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let windows = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.map { row in
                ["window": row[kCGWindowNumber as String] ?? 0, "layer": row[kCGWindowLayer as String] ?? 0,
                 "bounds": row[kCGWindowBounds as String] ?? [:], "onscreen": row[kCGWindowIsOnscreen as String] ?? false]
            }
            emit("VG_STATUS_WINDOWS", ["target_pid": pid, "windows": windows]); return
        }
        signal(SIGPIPE, SIG_IGN)
        let captureOnly = ProcessInfo.processInfo.environment["VG_CAPTURE_ONLY"] == "1"
        let language = ProcessInfo.processInfo.environment["VG_APP_LANGUAGE"] ?? "zh-Hans"
        UserDefaults.standard.setVolatileDomain([
            "autoCleanEnabled": false, "thresholdNotifyEnabled": false, "exitChangeNotifyEnabled": false,
            "updateCheckEnabled": false, "AppleLanguages": [language], "vg.tab": 0, "vg.device": "all",
            "vg.fiveTabsMigrated": true
        ], forName: UserDefaults.argumentDomain)
        precondition(!UserDefaults.standard.bool(forKey: "autoCleanEnabled"))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (captureOnly ? 70 : 450)) {
            fputs("VG_ERROR {\"error\":\"safety deadline exceeded\"}\n", stdout); fflush(stdout); _exit(2)
        }
        let app = NSApplication.shared; app.appearance = NSAppearance(named: .darkAqua)
        if arguments.contains("--preflight-language") {
            let actual = Locale.preferredLanguages.first ?? "unknown"
            emit("VG_LANGUAGE", ["requested": language, "actual": actual])
            precondition(actual.hasPrefix(language)); return
        }
        let owner = AppDelegate()
        let driver = AppBenchmarkDriver(delegate: owner)
        // Use exactly one production delegate/collector owner.
        app.delegate = owner; BenchmarkAudit.start()
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: app, queue: nil) { _ in driver.scheduleAfterLaunch() }
        withExtendedLifetime((owner, driver, observer)) { app.run() }
    }
}

// Tool-only destinations. Never replace the user's defaults or collector caches.
enum BenchmarkState {
    private static let lock = NSLock()
    private static var paths: [String: String] = [:]
    private static var overrides: [String: Any] = [:]
    static var directory: String {
        guard let path = ProcessInfo.processInfo.environment["VG_BENCH_STATE_DIR"] else {
            fatalError("VG_BENCH_STATE_DIR is required")
        }
        return path
    }
    static func cachePath(original: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let path = paths[original] { return path }
        let path = directory + "/" + URL(fileURLWithPath: original).lastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: original) && !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.copyItem(atPath: original, toPath: path)
            }
        } catch { fatalError("Unable to prepare private collector state: \(error)") }
        paths[original] = path
        return path
    }
    static func set(_ value: Any, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        overrides[key] = value
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key] = value
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: overrides, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: directory + "/defaults-writes.plist"), options: .atomic)
        } catch { fatalError("Unable to preserve private default writes: \(error)") }
    }
}
