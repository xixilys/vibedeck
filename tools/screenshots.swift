import AppKit
import SwiftUI

// Fictional inputs for visual review; live data is captured by the full-app driver.
enum ReviewFixtures {
    static let now = Double(ProcessInfo.processInfo.environment["VG_REVIEW_EPOCH"] ?? "") ?? Date().timeIntervalSince1970
    static func window(_ used: Int, seconds: Double = 18000, old: Bool = false) -> QuotaWindow {
        QuotaWindow(usedPct: used, resetsAt: now + seconds * 0.53, capturedAt: now - (old ? 14400 : 20), windowSeconds: seconds)
    }
    static func report() -> ScanReport {
        var r = ScanReport()
        r.totalMemoryGB = 32; r.usedMemoryGB = 13.4; r.freePercentage = 58
        r.swapUsedGB = 0.4; r.compressorGB = 2.1; r.loadAvg1m = 3.2; r.loadAvg5m = 3.6
        r.diskTotalGB = 994; r.diskFreeGB = 412; r.diskFreePct = 41
        r.npxCacheKnown = true; r.diskStatsKnown = true; r.npxCacheMB = 410
        r.activeMCPProcessCount = 46; r.activeMCPTotalMemMB = 1900
        r.detectedLLMs = [
            DetectedLLMRuntime(name: "Codex", isRunning: true, tier: "Pro", detail: L("本机", "Local"), fiveHour: window(42), sevenDay: window(67, seconds: 604800)),
            DetectedLLMRuntime(name: "Gemini", isRunning: true, tier: "AI Pro", detail: L("1 会话", "1 session"), fiveHour: window(22), sevenDay: window(35, seconds: 604800), secondaryPoolName: "三方", secondaryFiveHour: window(8), secondarySevenDay: window(14, seconds: 604800), isFullWidth: true)
        ]
        r.remoteHosts = ["fixture-wsl", "fixture-jp", "fixture-old"]
        r.remoteLLMs = [
            "fixture-wsl": [DetectedLLMRuntime(name: "Codex", isRunning: true, tier: "Pro", detail: "WSL", fiveHour: window(41))],
            "fixture-jp": [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "SSH", fiveHour: window(0), sevenDay: window(100, seconds: 604800))],
            "fixture-old": [DetectedLLMRuntime(name: "Claude", isRunning: false, tier: "Max", detail: "SSH", fiveHour: window(11, old: true))]
        ]
        for host in r.remoteHosts { r.remoteDeviceStatus[host] = RemoteDeviceStatus(lastSuccess: now - (host == "fixture-old" ? 14400 : 20), lastAttempt: now - 20, error: host == "fixture-old" ? L("离线", "Offline") : "") }
        r.tokens.todayTurns = 412; r.tokens.todayContext = 86400000; r.tokens.todayOutput = 512000; r.tokens.todayCacheRead = 83900000; r.tokens.todayThinking = 148000
        r.tokens.recentInteractions = [InteractionRecord(id: "review-turn", model: "claude-opus-5", timestamp: now - 40, contextTokens: 612000, cacheReadTokens: 609800, outputTokens: 3812, thinkingTokens: 1904)]
        r.tokens.todayByProject = [ProjectUsage(path: "~/code/example-app", turns: 188, ctx: 41200000, out: 238000, think: 71000, clis: ["Claude"])]
        r.cliUsage = [CLIUsage(name: "Codex", requests: 96, ctx: 18300000, cacheRead: 16900000, out: 142000, think: 51000, turns: 96),
                      CLIUsage(name: "Grok", turns: 7, note: L("仅记录轮次，token 不可用", "Only turns recorded; tokens unavailable")),
                      CLIUsage(name: "Gemini", note: L("本机没有可用 token 记录", "No local token records"))]
        var api = APIProviderStatus(host: "api.example.test", provider: L("演示 API", "Demo API"))
        api.calls = 138; api.ctx = 4800000; api.out = 184000; api.models = ["gpt-6.1-sol"]; api.cost = ["USD": 8.42]
        api.lastTS = now - 22
        r.api.providers = [api]; r.api.running = true; r.api.installed = true; r.api.callsSinceStart = 138
        r.api.hasPriceTable = true; r.api.priceAsOf = "2026-10-16"
        r.disk = [DiskItem(path: "~/example/sessions", label: L("会话记录", "Session logs"), totalMB: 2140, files: 910, oldMB: 1380, oldFiles: 620, purgeable: true, note: L("删除后无法恢复会话", "Deleting prevents session resume"))]
        r.diskTotalAIGB = 2.14
        return r
    }
    static func history() -> UsageHistory.Snapshot {
        var s = UsageHistory.Snapshot()
        var hourly: [String: [Double]] = [:]
        for back in (0..<42).reversed() {
            let date = Date(timeIntervalSince1970: now - Double(back) * 86400)
            let key = UsageHistory.dayKey(timestamp: date.timeIntervalSince1970)
            let amount = Int64(12000000 + (back * 3700000) % 50000000)
            let models = ["gpt-6.1-sol": UsageHistory.ModelTotals(ctx: amount, cacheRead: amount * 8 / 10, out: amount / 60, think: amount / 150)]
            let local = UsageHistory.Totals(ctx: amount, cacheRead: amount * 8 / 10, out: amount / 60, think: amount / 150, turns: 40 + back, sessions: 3, models: models)
            let remote = UsageHistory.Totals(ctx: amount / 2, cacheRead: amount / 3, out: amount / 100, turns: 20 + back, sessions: 2, models: models)
            s.days.append(UsageHistory.Day(date: key, sources: ["Codex": local, "Codex · fixture-wsl": remote]))
            s.dailyTokens[key] = local.tokenTotal + remote.tokenTotal
            s.dailyCost[key] = Double(30 + back % 30)
            hourly[key] = (0..<24).map { (9...18).contains($0) ? Double(30 + back % 30) / 10 : 0 }
            s.aggregate.merge(local); s.aggregate.merge(remote)
            var total = s.totals["Codex"] ?? UsageHistory.Totals(); total.merge(local); s.totals["Codex"] = total
            var wsl = s.totals["Codex · fixture-wsl"] ?? UsageHistory.Totals(); wsl.merge(remote); s.totals["Codex · fixture-wsl"] = wsl
            if back == 0 { s.todayBySource = ["Codex": local, "Codex · fixture-wsl": remote] }
        }
        s.earliestDate = s.days.first?.date; s.activeDays = 42; s.capturedAt = now
        s.processedFiles = 2410; s.totalFiles = 2410; s.priceCurrency = "USD"; s.builtinPriceAsOf = "2026-10-16"
        s.costByCurrency = ["USD": 2233.8]; s.costBySource = ["Codex": ["USD": 1842.6], "Codex · fixture-wsl": ["USD": 391.2]]
        s.forecasts = ["USD": UsageForecast.compute(hourly: hourly, lastHourCost: 4.2, currency: "USD", now: Date(timeIntervalSince1970: now))]
        return s
    }
    static func network() -> NetworkSnapshot {
        var n = NetworkSnapshot()
        n.aiExits = [("claude", "Claude", "api.anthropic.com", 182), ("chatgpt", "ChatGPT/Codex", "chatgpt.com", 176), ("openai", "OpenAI API", "api.openai.com", 171)].map { id, name, host, ms in
            var e = AIExitStatus(id: id, name: name, host: host)
            e.ip = "203.0.113.24"; e.loc = "US"; e.colo = "SJC"; e.latencyMS = ms; e.attemptedAt = now - 30; e.capturedAt = now - 30
            return e
        }
        n.proxy.running = true; n.proxy.version = "mihomo"
        n.proxy.groups = [ProxyGroupStatus(name: "AI", type: "Selector", now: "Example West")]
        n.local.gateway = "192.0.2.1"; n.local.interfaceName = "en0"; n.local.ipv4 = "192.0.2.23"
        n.local.dnsServers = ["198.51.100.2"]; n.local.wifiName = "Example Wi-Fi"
        n.local.uploadBPS = 186000; n.local.downloadBPS = 2450000; n.local.capturedAt = now
        n.leak.ipv6Blocked = true; n.leak.ipv6Message = L("IPv6 出站已阻断", "IPv6 egress blocked")
        n.leak.dnsVerdict = .proxyOK; n.leak.checkedAt = now - 30; n.capturedAt = now
        return n
    }
}

@main struct ReviewScreenshots {
    static func option(_ key: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    @MainActor static func render<V: View>(_ body: V, path: String, dark: Bool) {
        let host = NSHostingView(rootView: body.background(dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance; window.contentView = host
        for _ in 0..<3 {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard host.bounds.width > 0, host.bounds.height > 0, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap for \(path)") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fatalError("\(error)") }
        print("render \(path) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
        window.contentView = nil; window.close()
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--interactive") {
            app.setActivationPolicy(.regular)
            let delegate = ReviewWindowDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        app.setActivationPolicy(.prohibited)
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { _ = PricingCatalog.builtin; ready.signal() }
        _ = ready.wait(timeout: .now() + 10)
        let out = option("--output") ?? "review-shots/final"
        let lang = (option("--language") ?? "en").hasPrefix("zh") ? "zh" : "en"
        print("REQUESTED_LANGUAGE \(lang) actual_startup=\(Locale.preferredLanguages)")
        let pages: [(String, Int, String?)] = [("overview",0,nil),("api",1,nil),("stats",2,nil),("network",3,nil),("system",4,nil),("health",0,DashboardView.healthPage),("prices",0,DashboardView.pricesPage)]
        for scale in [0.85, 1.0, 1.3] {
            for dark in [false,true] {
                let style = dark ? "dark" : "light"
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for (name,tab,drill) in pages {
                    UserDefaults.standard.setVolatileDomain(["AppleLanguages":[ReviewScreenshots.option("--language") ?? "en"],"vg.fiveTabsMigrated":true,"vg.tab":tab,"vg.device":"all","fontScale":scale],forName:UserDefaults.argumentDomain)
                    precondition(Locale.preferredLanguages.first?.hasPrefix(lang) == true, "Screenshot language mismatch")
                    let view = DashboardView.review(report: ReviewFixtures.report(),history: ReviewFixtures.history(),network: ReviewFixtures.network(),drill:drill)
                    render(view.renderBody,path:"\(out)/\(lang)-\(style)-\(scale)-\(name).png",dark:dark)
                }
                UserDefaults.standard.setVolatileDomain(["AppleLanguages":[ReviewScreenshots.option("--language") ?? "en"],"vg.fiveTabsMigrated":true,"vg.tab":0,"vg.device":"all","fontScale":scale],forName:UserDefaults.argumentDomain)
                let view = DashboardView.review(report: ReviewFixtures.report(),history: ReviewFixtures.history(),network: ReviewFixtures.network())
                render(view.reviewSettingsSection,path:"\(out)/\(lang)-\(style)-\(scale)-settings-section.png",dark:dark)
                render(view.reviewDeviceSection,path:"\(out)/\(lang)-\(style)-\(scale)-devices-wsl.png",dark:dark)
            }
        }
    }
}


/// Visible fixture window for inspecting the production controls with Accessibility.
/// This process owns no collectors and writes no production preferences.
@MainActor final class ReviewWindowDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let dark = ReviewScreenshots.option("--appearance") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        UserDefaults.standard.setVolatileDomain(["AppleLanguages":[ReviewScreenshots.option("--language") ?? "en"],"vg.fiveTabsMigrated":true,"vg.tab":0,"vg.device":"all","fontScale":1.0],forName:UserDefaults.argumentDomain)
        let win = NSWindow(contentRect: NSRect(x:0,y:0,width:380,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        win.title = "VibeDeck Panel Review"
        win.isReleasedWhenClosed = false
        var actions = PanelActions()
        actions.isVisible = { false }
        actions.panelHeightChanged = { [weak win] height in
            guard height.isFinite, height > 0 else { return }
            win?.setContentSize(NSSize(width:380,height:min(height, NSScreen.main!.visibleFrame.height-80)))
        }
        actions.quit = { NSApp.terminate(nil) }
        var view = DashboardView.review(report: ReviewFixtures.report(),history: ReviewFixtures.history(),network: ReviewFixtures.network())
        view.actions = actions
        win.contentView = NSHostingView(rootView:view)
        window = win; win.center(); win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        Timer.scheduledTimer(withTimeInterval:240,repeats:false) { _ in NSApp.terminate(nil) }
        print("INTERACTIVE_READY pid=\(ProcessInfo.processInfo.processIdentifier) window=\(win.windowNumber)")
        fflush(stdout)
    }
}
