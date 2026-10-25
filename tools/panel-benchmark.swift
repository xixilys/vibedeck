// Isolated UI-process benchmark. Never launches AppDelegate or collectors.
// The compiler-only Dashboard extension injects a mutable ReportStore into demo
// mode; production timer intervals and demo guards are never rewritten.
import AppKit
import SwiftUI
import QuartzCore
import Darwin
import Combine

@MainActor final class RenderReceipt {
    var revision = -1
    var updates = 0
}

// Receipt means SwiftUI evaluated an updated view tree, not GPU presentation.
@MainActor struct ReportReceiptView: NSViewRepresentable {
    let revision: Int
    let receipt: RenderReceipt
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        receipt.revision = revision
        receipt.updates += 1
    }
}

@MainActor final class ReportStore: ObservableObject {
    var report: ScanReport
    init(_ report: ScanReport) { self.report = report }
    func publish(_ report: ScanReport) {
        self.report = report
        NotificationCenter.default.post(name: .init("VGBenchmarkReport"), object: report)
    }
}

@MainActor final class BenchmarkScene {
    let window: NSPanel
    let store: ReportStore
    let receipt = RenderReceipt()
    var host: NSHostingView<DashboardView>?
    var visible = false
    var pendingRelayout = false
    weak var observedHost: NSHostingView<DashboardView>?

    init(report: ScanReport) {
        store = ReportStore(report)
        window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 355, height: 700),
                         styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "VibeDeck isolated UI benchmark"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
    }

    func open(history: UsageHistory.Snapshot, network: NetworkSnapshot) {
        visible = true
        var actions = PanelActions()
        actions.relayout = { [weak self] in self?.relayout() }
        actions.latestReport = { [weak self] in self?.store.report }
        actions.isVisible = { [weak self] in self?.visible == true }
        BenchmarkProbe.receipt = receipt
        let dashboard = DashboardView(benchmarkReport: store.report, history: history, network: network, benchmarkActions: actions)
        let h = NSHostingView(rootView: dashboard)
        host = h
        observedHost = h
        window.contentView = h
        h.frame = NSRect(origin: .zero, size: h.fittingSize)
        window.setContentSize(h.fittingSize)
        window.orderFrontRegardless()
    }

    func relayout() {
        if BenchmarkConfig.visibleOnly {
            guard visible, !pendingRelayout else { return }
            pendingRelayout = true
        }
        DispatchQueue.main.async { [weak self, weak expectedHost = host] in
            guard let self else { return }
            self.pendingRelayout = false
            guard let h = expectedHost, self.host === h,
                  !BenchmarkConfig.visibleOnly || self.visible else { return }
            let size = h.fittingSize
            if abs(size.height - h.frame.height) > 1 {
                h.frame.size = size
                self.window.setContentSize(size)
            }
        }
    }

    // All calls happen on the main thread. Submission/CPU metrics exclude GPU
    // completion and WindowServer; wall time can include run-loop scheduling.
    func layoutDisplay() {
        guard let h = host else { return }
        let size = h.fittingSize
        h.frame.size = size
        window.setContentSize(size)
        h.layoutSubtreeIfNeeded()
        h.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func submit(revision: Int) -> (acknowledged: Bool, layoutMS: Double, passes: Int) {
        let deadline = PanelBenchmark.uptime() + 2
        var layoutMS = 0.0, passes = 0
        repeat {
            let start = PanelBenchmark.uptime()
            layoutDisplay()
            layoutMS += (PanelBenchmark.uptime() - start) * 1000
            passes += 1
            if receipt.revision == revision { break }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        } while PanelBenchmark.uptime() < deadline
        // Flush layout/display after the observed revision entered the view tree.
        let start = PanelBenchmark.uptime()
        layoutDisplay()
        layoutMS += (PanelBenchmark.uptime() - start) * 1000
        return (receipt.revision == revision, layoutMS, passes + 1)
    }

    func closeUsingProductionPolicy() {
        visible = false
        window.orderOut(nil)
        if BenchmarkConfig.releasesHiddenHost {
            window.contentView = nil
            host = nil
        }
        // Baseline deliberately retains contentView/host, as its NSMenu does.
    }
    func dispose() {
        window.orderOut(nil)
        window.contentView = nil
        host = nil
        window.close()
    }
}

@MainActor final class ReportDelivery {
    let scene: BenchmarkScene
    let reports: [ScanReport]
    var delivered = 0
    var suppressed = 0
    init(scene: BenchmarkScene, reports: [ScanReport]) {
        self.scene = scene
        self.reports = reports
    }
    func tick() {
        if BenchmarkConfig.visibleOnly && !scene.visible { suppressed += 1; return }
        scene.store.publish(reports[delivered % reports.count])
        delivered += 1
    }
}

@main struct PanelBenchmark {
    static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { fatalError("Unable to read main-thread CPU: \(result)") }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
    static func summary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        func p(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return ["count": values.count, "mean_ms": values.reduce(0, +) / Double(values.count),
                "median_ms": p(0.5), "p95_ms": p(0.95), "max_ms": sorted.last!,
                "over_50ms": values.filter { $0 > 50 }.count]
    }

    // Built before timing. Vary values and card/row counts, preserving stable IDs
    // for surviving cards. No fixture parsing is included in refresh timing.
    static func varied(_ base: ScanReport, revision: Int) -> ScanReport {
        var r = base
        r.tokens.todayTurns = revision
        r.tokens.todayContext += Int64(revision * 1301)
        r.tokens.todayOutput += Int64(revision * 31)
        r.usedMemoryGB = 9 + Double(revision % 13)
        r.freePercentage = 100 - Int(r.usedMemoryGB / 32 * 100)
        if !r.detectedLLMs.isEmpty {
            r.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: revision % 96,
                resetsAt: BenchmarkFixtures.now + 9600, capturedAt: BenchmarkFixtures.now - 20, windowSeconds: 18000)
        }
        if revision % 2 == 0 {
            if !r.detectedLLMs.isEmpty { r.detectedLLMs.removeLast() }
            if !r.disk.isEmpty { r.disk.removeLast() }
            if !r.api.providers.isEmpty { r.api.providers.removeLast() }
        }
        for i in r.api.providers.indices { r.api.providers[i].calls += revision }
        return r
    }

    @MainActor static func steady(seconds: Double, scene: BenchmarkScene, reports: [ScanReport],
                                  phase: String) -> [String: Any] {
        let delivery = ReportDelivery(scene: scene, reports: reports)
        // Models completed report delivery only. Scanner/IO cost is absent.
        let reportTimer = Timer(timeInterval: 8, repeats: true) { _ in
            MainActor.assumeIsolated { delivery.tick() }
        }
        RunLoop.main.add(reportTimer, forMode: .common)
        let start = uptime(), cpuStart = cpu(), updatesStart = scene.receipt.updates
        var previous = start, previousCPU = cpuStart
        var samples: [[String: Any]] = []
        while uptime() - start < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(min(1, seconds - (uptime() - start))))
            let now = uptime(), used = cpu(), elapsed = now - previous
            samples.append(["offset_seconds": now - start, "elapsed_seconds": elapsed,
                            "cpu_seconds": used - previousCPU,
                            "cpu_percent_one_core": (used - previousCPU) / max(elapsed, 0.000001) * 100])
            previous = now; previousCPU = used
        }
        reportTimer.invalidate()
        let elapsed = uptime() - start, used = cpu() - cpuStart
        return ["phase": phase, "elapsed_seconds": elapsed, "cpu_seconds": used,
                "cpu_percent_one_core": used / elapsed * 100, "sample_count": samples.count,
                "raw_cpu_samples": samples, "injected_reports": delivery.delivered, "suppressed_reports": delivery.suppressed,
                "render_receipt_updates": scene.receipt.updates - updatesStart]
    }

    @MainActor static func run(output: String, seconds: Double, tab: Int) throws -> Bool {
        let fixtureStart = uptime()
        let base = BenchmarkFixtures.report(), history = BenchmarkFixtures.history(), network = BenchmarkFixtures.network()
        let reports = (1...32).map { varied(base, revision: $0) }
        let fixtureMS = (uptime() - fixtureStart) * 1000
        var opens: [[String: Any]] = []
        for _ in 0..<12 {
            autoreleasepool {
                let scene = BenchmarkScene(report: base)
                let start = uptime(), cpuStart = mainThreadCPU()
                scene.open(history: history, network: network)
                let result = scene.submit(revision: base.tokens.todayTurns)
                opens.append(["wall_ms": (uptime() - start) * 1000,
                              "main_thread_cpu_ms": (mainThreadCPU() - cpuStart) * 1000,
                              "layout_display_calls_ms": result.layoutMS,
                              "layout_passes": result.passes, "revision_acknowledged": result.acknowledged])
                scene.dispose()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let scene = BenchmarkScene(report: base)
        var refreshes: [[String: Any]] = []
        // The host must be created and detached within the same autorelease
        // scope. Draining only a new pool around close cannot release AppKit
        // objects autoreleased when the visible host was originally attached.
        let visible: [String: Any] = autoreleasepool {
            scene.open(history: history, network: network)
            _ = scene.submit(revision: base.tokens.todayTurns)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            for report in reports {
                let start = uptime(), cpuStart = mainThreadCPU()
                scene.store.publish(report)
                let mutationMS = (uptime() - start) * 1000
                let result = scene.submit(revision: report.tokens.todayTurns)
                refreshes.append(["revision": report.tokens.todayTurns,
                    "mutation_ms": mutationMS, "mutation_to_display_wall_ms": (uptime() - start) * 1000,
                    "main_thread_cpu_ms": (mainThreadCPU() - cpuStart) * 1000,
                    "layout_display_calls_ms": result.layoutMS, "layout_passes": result.passes,
                    "revision_acknowledged": result.acknowledged,
                    "platform_cards": report.detectedLLMs.count, "api_cards": report.api.providers.count])
                // Not timed: settle before the next single-report refresh.
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            print("opened steady UI-process CPU: \(seconds)s, tab \(tab)"); fflush(stdout)
            let measured = steady(seconds: seconds, scene: scene, reports: reports, phase: "opened")
            scene.closeUsingProductionPolicy()
            return measured
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let released = scene.observedHost == nil
        print("closed steady UI-process CPU: \(seconds)s, host released = \(released)"); fflush(stdout)
        let closed = steady(seconds: seconds, scene: scene, reports: reports, phase: "closed")
        scene.dispose()
        let valid = opens.allSatisfy { $0["revision_acknowledged"] as? Bool == true }
            && refreshes.allSatisfy { $0["revision_acknowledged"] as? Bool == true }
            && released == BenchmarkConfig.releasesHiddenHost
        var metadata = try JSONSerialization.jsonObject(with: Data(BenchmarkConfig.metadataJSON.utf8)) as! [String: Any]
        metadata["fixture_epoch"] = BenchmarkFixtures.now
        metadata["language"] = Locale.preferredLanguages.first ?? "unknown"
        let result: [String: Any] = ["schema": 3, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "valid": valid, "metadata": metadata, "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "tab": tab, "language": Locale.preferredLanguages.first ?? "unknown", "appearance": "dark",
            "scope": "Actual state-based Dashboard + tool-only notification report injection in NSPanel. Real SwiftUI host/layout/display submission and UI-process CPU; NOT full live app CPU or click-to-presented-frame latency.",
            "refresh_affects_visible_report_content": [0, 1, 4].contains(tab),
            "duration_each_phase_seconds": seconds, "fixture_construction_ms": fixtureMS,
            "open_raw": opens, "open_all": summary(opens.compactMap { $0["wall_ms"] as? Double }),
            "open_warm": summary(opens.dropFirst().compactMap { $0["wall_ms"] as? Double }),
            "refresh_raw": refreshes,
            "refresh_mutation_to_display_wall": summary(refreshes.compactMap { $0["mutation_to_display_wall_ms"] as? Double }),
            "refresh_main_thread_cpu": summary(refreshes.compactMap { $0["main_thread_cpu_ms"] as? Double }),
            "refresh_layout_display_calls": summary(refreshes.compactMap { $0["layout_display_calls_ms"] as? Double }),
            "visible": visible, "closed": closed, "host_released_before_closed_phase": released]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: output))
        print("wrote \(output), valid = \(valid), opens = \(opens.count), refreshes = \(refreshes.count)")
        return valid
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4, let seconds = Double(args[2]), seconds.isFinite, seconds >= 1,
              let tab = Int(args[3]), (0...4).contains(tab) else {
            fputs("Usage: panel-benchmark output.json seconds-per-phase tab(0...4)\n", stderr); exit(1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain(["uiLanguage": "en", "vg.tab": tab,
            "vg.device": "all", "vg.fiveTabsMigrated": true, "vg.heatmapHourly": false,
            "latestVersion": "", "updateCheckEnabled": false], forName: UserDefaults.argumentDomain)
        MainActor.assumeIsolated {
            do { if try !run(output: args[1], seconds: seconds, tab: tab) { exit(2) } }
            catch { fputs("benchmark failed: \(error)\n", stderr); exit(1) }
        }
    }
}

@MainActor enum BenchmarkProbe { static var receipt: RenderReceipt? }

enum BenchmarkFixtures {
    static let now: Double = Double(ProcessInfo.processInfo.environment["VG_BENCHMARK_EPOCH"] ?? "") ?? 1792147200
    static func window(_ used: Int, old: Bool = false) -> QuotaWindow {
        QuotaWindow(usedPct: used, resetsAt: now + 15000, capturedAt: now - (old ? 14400 : 20), windowSeconds: 18000)
    }
    static func report() -> ScanReport {
        var r = ScanReport()
        r.totalMemoryGB = 32; r.usedMemoryGB = 13.4; r.freePercentage = 58
        r.diskTotalGB = 994; r.diskFreeGB = 412; r.diskFreePct = 41
        r.npxCacheKnown = true; r.diskStatsKnown = true
        r.detectedLLMs = [DetectedLLMRuntime(name: "Codex", isRunning: true, tier: "Pro", detail: "Local fixture", fiveHour: window(42))]
        r.remoteHosts = ["fixture-wsl", "fixture-jp", "fixture-old"]
        r.remoteLLMs = [
            "fixture-wsl": [DetectedLLMRuntime(name: "Codex", isRunning: true, tier: "Pro", detail: "Fixture", fiveHour: window(41))],
            "fixture-jp": [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "Fixture", fiveHour: window(0), sevenDay: QuotaWindow(usedPct: 100, resetsAt: now + 86400, capturedAt: now - 20, windowSeconds: 604800))],
            "fixture-old": [DetectedLLMRuntime(name: "Claude", isRunning: false, tier: "Max", detail: "Retained fixture", fiveHour: window(11, old: true))]
        ]
        for host in r.remoteHosts { r.remoteDeviceStatus[host] = RemoteDeviceStatus(lastSuccess: now - (host == "fixture-old" ? 14400 : 20), lastAttempt: now - 20, error: host == "fixture-old" ? "Fixture offline" : "") }
        r.tokens.todayTurns = 412; r.tokens.todayContext = 86400000; r.tokens.todayOutput = 512000
        r.cliUsage = [CLIUsage(name: "Codex", requests: 96, ctx: 18300000, cacheRead: 16900000, out: 142000, think: 51000, turns: 96)]
        var api = APIProviderStatus(host: "fixture.test", provider: "Fixture API")
        api.calls = 138; api.ctx = 4800000; api.out = 184000; api.models = ["fixture-model"]; api.cost = ["USD": 8.42]
        r.api.providers = [api]; r.api.running = true
        r.disk = [DiskItem(path: "~/fixture/sessions", label: "Fixture sessions", totalMB: 2140, files: 910, oldMB: 1380, oldFiles: 620, purgeable: true)]
        return r
    }
    static func history() -> UsageHistory.Snapshot { UsageHistory.Snapshot() }
    static func network() -> NetworkSnapshot { NetworkSnapshot() }
}
