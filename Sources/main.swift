import Cocoa
import SwiftUI
import SQLite3

// `VibeDeck --fan-set <rpm>` / `--fan-auto`：由管理员授权后的子进程执行，只碰 SMC 风扇键。
if let code = FanCommandLine.run(CommandLine.arguments) { exit(code) }

// `VibeDeck --install-proxy` / `--uninstall-proxy`：命令行装卸 API 记账代理（与菜单同一条代码路径）
if CommandLine.arguments.contains("--install-proxy") {
    do {
        try ProxyManager.shared.install()
        print("已安装并启动：\(ProxyManager.shared.prefix)  日志 \(ProxyManager.shared.logPath)")
    } catch {
        print("安装失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
if CommandLine.arguments.contains("--uninstall-proxy") {
    ProxyManager.shared.uninstall()
    print("已卸载")
    exit(0)
}

// `VibeDeck --sync-prices`：补齐缺价并刷新未被手改的自动价，保留内置完整计价规则。
if CommandLine.arguments.contains("--sync-prices") {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let outcome = PriceSync.sync(home: home)
    if !outcome.error.isEmpty { print(outcome.error) }
    print("新增 \(outcome.added.count) 个：" + (outcome.added.isEmpty ? "—" : outcome.added.joined(separator: ", ")))
    print("更新 \(outcome.updated.count) 个：" + (outcome.updated.isEmpty ? "—" : outcome.updated.joined(separator: ", ")))
    print("社区库里也没有 \(outcome.skipped.count) 个：" + (outcome.skipped.isEmpty ? "—" : outcome.skipped.joined(separator: ", ")))
    print("价目表：\(PriceSync.pricesPath(home: home))")
    if !outcome.backupPath.isEmpty { print("备份：\(outcome.backupPath)") }
    exit(outcome.error.isEmpty ? 0 : 1)
}

// Read-only diagnostics wait for discovery explicitly; normal UI readers use the cache.
if CommandLine.arguments.contains("--debug-devices") || CommandLine.arguments.contains("--debug-remote") {
    let discovery = DispatchSemaphore(value: 0)
    RemoteCollector.refreshDiscoveryIfDue(force: true) { discovery.signal() }
    _ = discovery.wait(timeout: .now() + 6)
}

// `VibeDeck --debug-devices`: quota snapshots only, without transcript/history scans or credentials.
if CommandLine.arguments.contains("--debug-devices") {
    let hosts = RemoteCollector.hosts()
    print("Remote devices: \(hosts.count)")
    for host in hosts {
        print("\(RemoteCollector.displayName(for: host)) [\(host)]")
        switch RemoteCollector.pullQuotas(host: host) {
        case .failure(let error): print("  error: \(error.message)")
        case .success(let rows):
            for row in rows {
                func window(_ value: QuotaWindow?) -> String {
                    guard let value else { return "unknown" }
                    return "\(value.usedPct)% captured=\(value.capturedAt.map(String.init(describing:)) ?? "unknown") reset=\(value.resetsAt.map(String.init(describing:)) ?? "unknown") expired=\(value.isExpired())"
                }
                print("  \(row.name) tier=\(row.tier) \(row.detail) 5h=\(window(row.fiveHour)) week=\(window(row.sevenDay)) secondary=\(row.secondaryPoolName) 5h=\(window(row.secondaryFiveHour)) week=\(window(row.secondarySevenDay))")
            }
        }
    }
    exit(0)
}

// `VibeDeck --debug-remote`：排查远程用量拉取（脚本是否找到 / 主机列表 / 每台的结果或失败原因）
if CommandLine.arguments.contains("--debug-remote") {
    var lines: [String] = []
    lines.append("采集脚本: " + (RemoteCollector.script() == nil ? "读不到" : "已找到"))
    lines.append("主机列表: \(RemoteCollector.hosts())")
    func appendSpeeds(_ records: [UsageHistory.Record], to lines: inout [String]) {
        let cutoff = Date().timeIntervalSince1970 - 86400
        let grouped = Dictionary(grouping: records.filter { $0.timestamp >= cutoff && $0.timestamp <= Date().timeIntervalSince1970 }, by: { "\($0.source) / \($0.model)" })
        for key in grouped.keys.sorted() {
            let speeds = grouped[key]!.compactMap { $0.timing?.speed(output: $0.usage.out, proxy: false) }
            guard !speeds.isEmpty else { continue }
            lines.append(String(format: "  %@: estimated tok/s p50=%.1f p90=%.1f n=%d (24h)", key,
                                PerformanceStats.percentile(speeds, 0.5)!, PerformanceStats.percentile(speeds, 0.9)!, speeds.count))
        }
    }
    for host in RemoteCollector.hosts() {
        switch RemoteCollector.pullUsage(host: host, since: 0) {
        case .success(let pull):
            lines.append("\(host): OpenCode 成功 \(pull.records.count) 条 · maxUpdated=\(pull.maxUpdated)")
            appendSpeeds(pull.records, to: &lines)
        case .failure(let reason): lines.append("\(host): OpenCode 失败 · \(reason.message)")
        }
        switch RemoteCollector.pullCLIRecords(host: host, since: Int64((Date().timeIntervalSince1970 - 86400) * 1000)) {
        case .success(let pull):
            lines.append("\(host): CLI 成功 \(pull.records.count) 条 · maxMtime=\(pull.maxMtime)")
            appendSpeeds(pull.records, to: &lines)
        case .failure(let reason): lines.append("\(host): CLI 失败 · \(reason.message)")
        }
    }
    let text = lines.joined(separator: "\n") + "\n"
    try? text.write(toFile: "/tmp/vibedeck-remote-debug.txt", atomically: true, encoding: .utf8)
    print(text, terminator: "")
    exit(0)
}

// `VibeDeck --debug-usage`：采集一次后打印各来源的首字样本、今日用量和历史累计，排查哪些来源没有接通。
if CommandLine.arguments.contains("--debug-usage") {
    _ = NSApplication.shared
    let discovered = DispatchSemaphore(value: 0)
    RemoteCollector.refreshDiscoveryIfDue(force: true) { discovered.signal() }
    _ = discovered.wait(timeout: .now() + 6)
    UsageHistory.shared.start()
    var waited = 0.0
    while (UsageHistory.shared.snapshot().capturedAt == 0 || UsageHistory.shared.snapshot().isScanning) && waited < 400 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)); waited += 0.5
    }
    let h = UsageHistory.shared.snapshot(), now = Date().timeIntervalSince1970
    print("hosts:", RemoteCollector.hosts())
    print("== turn latencies by source (count / last 1h ok / newest age s)")
    for (source, rows) in Dictionary(grouping: h.turnLatencies, by: \.source).sorted(by: { $0.key < $1.key }) {
        let recent = rows.filter { !$0.failed && $0.milliseconds > 0 && $0.timestamp >= now - 3600 }
        print("  \(source): \(rows.count) / \(recent.count) / \(Int(now - (rows.map(\.timestamp).max() ?? 0)))")
    }
    print("== proxy performance samples by source:", Dictionary(grouping: h.performance, by: \.source).mapValues(\.count))
    print("== today (account ledger) by source")
    for (source, t) in h.accountUsage.todayBySource.sorted(by: { $0.key < $1.key }) {
        print("  \(source): \(t.usage.tokenTotal) tok · \(t.requests) req · \(t.equivalentCostByCurrency)")
    }
    print("== today (history) by source")
    for (source, t) in h.todayBySource.sorted(by: { $0.key < $1.key }) { print("  \(source): \(t.tokenTotal) tok · \(t.turns) turns") }
    print("== all-time totals by source")
    for (source, t) in h.totals.sorted(by: { $0.key < $1.key }) { print("  \(source): \(t.tokenTotal) tok · \(t.turns) turns · \(h.costBySource[source] ?? [:])") }
    print("notes:", h.sourceNotes, "error:", h.error)
    exit(0)
}

// `VibeDeck --render-panel <目录>`：不开菜单，把各页面板渲染成 PNG（深色 / 浅色各一套），给 README 截图和界面检查用。
// `VibeDeck --render-pet <dir>`: every pup pose at 8×, for reviewing the menu-bar artwork.
if let i = CommandLine.arguments.firstIndex(of: "--render-pet") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let poses: [(String, MenuBarPet.Pose, Bool, String?)] = [("run0", .run(0), false, nil), ("run1", .run(1), false, nil), ("run2", .run(2), false, nil),
        ("run3", .run(3), false, nil), ("sit", .sit, false, nil), ("blink", .blink, false, nil), ("alert", .sit, true, nil), ("tight", .run(1), false, "14%")]
    for (name, pose, alert, label) in poses {
        let image = MenuBarPet.image(pose: pose, alert: alert, label: label)
        let scale: CGFloat = 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/pet-\(name).png"))
    }
    print("pet poses → \(dir)")
    exit(0)
}

// `VibeDeck --render-icon <png>`: the 1024 px app icon — the sitting pup, white on the brand gradient.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon") {
    let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "AppIcon_1024.png"
    let side = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824 pt body inset 100 pt, continuous-looking corner.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.55, green: 0.38, blue: 1.0, alpha: 1), NSColor(red: 0.24, green: 0.56, blue: 1.0, alpha: 1)])!
        .draw(in: shape, angle: -60)
    // A soft glass highlight across the top.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // The pup, tinted white, with a little ground shadow.
    let pet = MenuBarPet.image(pose: .sit, alert: false, label: nil)
    let tinted = NSImage(size: pet.size, flipped: false) { rect in
        pet.draw(in: rect)
        NSColor.white.set(); rect.fill(using: .sourceAtop)
        return true
    }
    NSColor.black.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: NSRect(x: 300, y: 222, width: 440, height: 46)).fill()
    let petRect = NSRect(x: 512 - 290, y: 236, width: 580, height: 580 * pet.size.height / pet.size.width)
    tinted.draw(in: petRect)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("icon → \(path)")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-panel") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    _ = NSApplication.shared
    NetworkScanner.shared.start()
    SystemMonitor.shared.start()
    SystemMonitor.shared.setVisible(true)
    var report = ProcessScanner.shared.scan(refreshRemote: false)
    if CommandLine.arguments.contains("--live-devices") {
        let discovered = DispatchSemaphore(value: 0)
        RemoteCollector.refreshDiscoveryIfDue(force: true) { discovered.signal() }
        _ = discovered.wait(timeout: .now() + 6)
        report.remoteHosts = RemoteCollector.devices()
        for host in RemoteCollector.hosts() {
            let attempted = Date().timeIntervalSince1970
            switch RemoteCollector.pullQuotas(host: host) {
            case .success(let rows):
                report.remoteLLMs[host] = rows
                report.remoteDeviceStatus[host] = RemoteDeviceStatus(lastSuccess: Date().timeIntervalSince1970, lastAttempt: attempted)
            case .failure(let error):
                report.remoteDeviceStatus[host] = RemoteDeviceStatus(lastAttempt: attempted, error: error.message)
            }
        }
    }
    UsageHistory.shared.start()
    let liveDevices = CommandLine.arguments.contains("--live-devices")
    var waited = 0.0
    while (UsageHistory.shared.snapshot().capturedAt == 0 || (liveDevices && UsageHistory.shared.snapshot().isScanning) || NetworkScanner.shared.snapshot().capturedAt == 0) && waited < 300 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        waited += 0.5
    }
    guard UsageHistory.shared.snapshot().capturedAt > 0, !liveDevices || !UsageHistory.shared.snapshot().isScanning else {
        print("Panel rendering timed out waiting for complete device history")
        exit(1)
    }
    NerfDetector.shared.refreshNow(history: UsageHistory.shared.snapshot())
    let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    let pages: [(name: String, tab: Int, drill: String?)] = [("subscription", 0, nil), ("api", 1, nil), ("stats", 2, nil),
                                                             ("network", 3, nil), ("system", 4, nil), ("health", 0, DashboardView.healthPage),
                                                             ("prices", 0, DashboardView.pricesPage), ("settings", 0, DashboardView.settingsPage)]
        + AccountPresentation.cards(usage: UsageHistory.shared.snapshot().accountUsage, quotas: AccountUsage.quotaObservations(report: report),
                                    now: Date().timeIntervalSince1970)
            .filter { $0.account != nil }.prefix(2).enumerated().map { ("account\($0.offset)", 0, "account:" + $0.element.id) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for dark in [true, false] {
        for page in pages {
            var arguments = savedArguments
            arguments["vg.tab"] = page.tab
            if let index = CommandLine.arguments.firstIndex(of: "--render-device"), CommandLine.arguments.count > index + 1 {
                arguments["vg.device"] = CommandLine.arguments[index + 1]
            }
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let body = DashboardView(report: report, settings: PanelSettings(fontScale: Double(UITheme.fontScale)), actions: PanelActions(), preload: true, drill: page.drill)
                .renderBody
                .background(dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(red: 0.95, green: 0.95, blue: 0.96))
                .environment(\.colorScheme, dark ? .dark : .light)
            MainActor.assumeIsolated {
                // NSHostingView 离屏绘制：ImageRenderer 画不出分段 Picker / 按钮这类 AppKit 控件（会变成黄底禁止符号）
                let started = CFAbsoluteTimeGetCurrent()
                let host = NSHostingView(rootView: body)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                // Opening the panel builds this same tree; the first-layout cost is what the user waits for.
                FileHandle.standardError.write(Data(String(format: "render %@ %@: %.0f ms\n", page.name, dark ? "dark" : "light",
                                                           (CFAbsoluteTimeGetCurrent() - started) * 1000).utf8))
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(dir)/panel-\(page.name)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
    UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    let h = UsageHistory.shared.snapshot()
    for (source, cost) in h.costBySource.sorted(by: { $0.key < $1.key }) { print("  \(source): \(Fmt.money(cost)) · \(h.totals[source].map { Fmt.tokens($0.tokenTotal) } ?? "-")") }
    if let f = h.forecast { print("  预测：今天 \(f.todaySoFar) → \(f.todayProjected)；本月 \(f.monthSoFar) → \(f.monthProjected)") }
    let month = UsageHistory.dayKey(timestamp: Date().timeIntervalSince1970).prefix(7)
    print("  本月逐日：" + h.dailyCost.filter { $0.key.hasPrefix(month) }.sorted { $0.key < $1.key }.map { "\($0.key.suffix(2))=\(Int($0.value))" }.joined(separator: " "))
    print("已渲染到 \(dir)")
    exit(0)
}

// `VibeDeck --selftest`：不起 UI，校验纯函数 + 打印一次完整扫描结果（档位/额度/Token 去重后数据）
if CommandLine.arguments.contains("--selftest") {
    FanServiceSelfTest.run()
    FanThermostatSelfTest.run()
    // 风扇：Apple Silicon 是 native float，老 Intel 是 fpe2；目标转速必须夹在硬件范围内。
    precondition(FanSMC.keyCode("F0Ac") == 0x4630_4163)
    precondition(FanSMC.decodeRPM([0x00, 0x80, 0x89, 0x44], size: 4) == 1100)
    precondition(FanSMC.decodeRPM([0x0f, 0xa0], size: 2) == 1000)
    precondition(FanSMC.decodeRPM([0x00], size: 1) == nil)
    precondition(FanSMC.clampRPM(500, minimum: 1000, maximum: 4900) == 1000)
    precondition(FanSMC.clampRPM(2000, minimum: 1000, maximum: 4900) == 2000)
    precondition(FanSMC.clampRPM(6000, minimum: 1000, maximum: 4900) == 4900)
    // stat(2) probe: same shape the scan needs, without the xattr lookup.
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-fileprobe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("quota.json")
        try! Data("{}".utf8).write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_700_000_123.25)
        try! FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let probe = vgFileStat(file.path)
        precondition(probe?.size == 2)
        precondition(abs((probe?.mtime ?? 0) - stamp.timeIntervalSince1970) < 0.01)
        precondition(probe?.isDirectory == false)
        precondition(vgFileStat(root.path)?.isDirectory == true)
        precondition(vgFileStat(root.appendingPathComponent("missing").path) == nil)
    }

    // The native path must preserve memory_pressure's free-percentage semantics.
    do {
        let native = ProcessScanner.shared.memorySnapshot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        let pipe = Pipe(); process.standardOutput = pipe
        try! process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = text.components(separatedBy: "\n").first { $0.contains("System-wide memory free percentage:") }!
        let reference = Int(line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))!
        precondition(abs(native.freePercentage - reference) <= 2, "Native and memory_pressure free% differ by more than 2 points")
        precondition(native.compressorGB >= 0 && native.swapUsedGB >= 0)
        print("Memory native/reference free%: \(native.freePercentage)/\(reference)")
    }

    // Slow-layer scheduling uses a monotonic clock, and opening the panel restores 8s freshness.
    precondition(ProcessScanner.slowScanDue(last: nil, now: 0, panelVisible: false))
    precondition(!ProcessScanner.slowScanDue(last: 100, now: 108, panelVisible: false))
    precondition(!ProcessScanner.slowScanDue(last: 100, now: 129.9, panelVisible: false))
    precondition(ProcessScanner.slowScanDue(last: 100, now: 130, panelVisible: false))
    precondition(ProcessScanner.slowScanDue(last: 100, now: 108, panelVisible: true))
    precondition(!ProcessScanner.slowScanDue(last: 100, now: 107.9, panelVisible: true))
    precondition(ProcessScanner.slowScanDue(last: 100, now: 101, panelVisible: false, force: true))
    // Directory-cache invalidation: unchanged roots, append, nested creation, expiry and cold files.
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-index-" + UUID().uuidString)
        let fm = FileManager.default
        try! fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date().timeIntervalSince1970
        let hot = root.appendingPathComponent("nested/hot.jsonl")
        let cold = root.appendingPathComponent("cold.jsonl")
        try! Data("a".utf8).write(to: hot); try! Data("old".utf8).write(to: cold)
        // Exercise subsecond timestamps in both discovery and the cached stat path.
        let precise = Date(timeIntervalSince1970: now.rounded(.down) + 0.3001792)
        try! fm.setAttributes([.modificationDate: precise], ofItemAtPath: hot.path)
        try! fm.setAttributes([.modificationDate: precise], ofItemAtPath: root.appendingPathComponent("nested").path)
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: now-90000)], ofItemAtPath: cold.path)
        var index = ProcessScanner.RecentLogIndex()
        let first = index.snapshots(roots: [root.path], horizon: now-86400, now: now)
        precondition(first.count == 1 && index.enumerations == 1)
        precondition(index.snapshots(roots: [root.path], horizon: now-86400, now: now+1) == first && index.enumerations == 1)
        let handle = try! FileHandle(forWritingTo: hot); try! handle.seekToEnd(); try! handle.write(contentsOf: Data("append".utf8)); try! handle.close()
        let appended = index.snapshots(roots: [root.path], horizon: now-86400, now: now+2)
        precondition(appended.first!.size > first.first!.size && index.enumerations == 1)
        let next = root.appendingPathComponent("nested/new.jsonl")
        try! Data("new".utf8).write(to: next)
        // Explicit directory mtime avoids relying on filesystem timestamp resolution in the fixture.
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: now+3)], ofItemAtPath: root.appendingPathComponent("nested").path)
        precondition(index.snapshots(roots: [root.path], horizon: now-86400, now: now+3).count == 2 && index.enumerations == 2)
        _ = index.snapshots(roots: [root.path], horizon: now-86400, now: now+123)
        precondition(index.enumerations == 3)
        try! fm.removeItem(at: next)
        precondition(index.snapshots(roots: [root.path], horizon: now-86400, now: now+124).count == 1 && index.enumerations == 4)
    }
    // Cached civil-day intervals preserve timezone and DST boundaries for out-of-order records.
    for zone in ["UTC", "America/New_York", "Asia/Shanghai", "Pacific/Apia"] {
        let timeZone = TimeZone(identifier: zone)!
        var days = UsageHistory.DayKeyCache(timeZone: timeZone)
        let starts: [TimeInterval] = [1_773_000_000, 1_793_400_000, 1_325_000_000]
        for base in starts {
            for step in stride(from: 180, through: -180, by: -1) {
                let timestamp = base + Double(step) * 1800
                precondition(days.key(timestamp) == UsageHistory.dayKey(timestamp: timestamp, timeZone: timeZone))
            }
        }
    }
    // Regression: compact reset labels preserve unknown/reset and boundary semantics.
    do {
        let clock: TimeInterval = 1_700_000_000
        precondition(QuotaPresentation.compactReset(to: nil, now: clock) == nil)
        precondition(QuotaPresentation.compactReset(to: .infinity, now: clock) == nil)
        precondition(QuotaPresentation.compactReset(to: clock + 60, now: .nan) == nil)
        precondition(QuotaPresentation.compactReset(to: clock, now: clock) == L("已重置", "Reset"))
        precondition(QuotaPresentation.compactReset(to: clock + 59, now: clock) == L("<1分", "<1m"))
        precondition(QuotaPresentation.compactReset(to: clock + 60, now: clock) == L("1分", "1m"))
        precondition(QuotaPresentation.compactReset(to: clock + 9540, now: clock) == L("2时39分", "2h39m"))
        precondition(QuotaPresentation.compactReset(to: clock + 86400, now: clock) == L("1天", "1d"))
        precondition(QuotaPresentation.compactReset(to: clock + 320400, now: clock) == L("3天17时", "3d17h"))
    }
    precondition(QuotaPresentation.usageLabel(100) == L("已用尽", "Exhausted"))
    precondition(QuotaPresentation.usageLabel(99) == L("即将用尽", "Near limit"))
    precondition(QuotaPresentation.usageLabel(20, predictedDepletion: true) == L("预计耗尽", "May run out"))
    do {
        let clock: TimeInterval = 1_700_000_000
        var fast = QuotaWindow(usedPct: 35, resetsAt: clock + 4 * 3600, capturedAt: clock, windowSeconds: 5 * 3600)
        fast.recentPctPerHour = 30
        fast.recentSpanMinutes = 20
        precondition(QuotaPresentation.usageLabel(fast, trusted: true, now: clock) == L("约 2时10分 耗尽", "Out in ~2h10m"))
        precondition(QuotaPresentation.usageLabel(fast, trusted: false, now: clock) == nil, "Disconnected or retained readings must not show a forecast")
        fast.capturedAt = clock - 601
        precondition(QuotaPresentation.usageLabel(fast, trusted: true, now: clock) == nil, "Old readings must not show a forecast")
        fast.capturedAt = clock + 61
        precondition(QuotaPresentation.usageLabel(fast, trusted: true, now: clock) == nil, "Future readings must not show a forecast")
        fast.capturedAt = nil
        precondition(QuotaPresentation.usageLabel(fast, trusted: true, now: clock) == nil)
        fast.capturedAt = clock
        fast.resetsAt = clock
        precondition(QuotaPresentation.usageLabel(fast, trusted: true, now: clock) == nil)

        var slow = QuotaWindow(usedPct: 40, resetsAt: clock + 3600, capturedAt: clock, windowSeconds: 5 * 3600)
        slow.recentPctPerHour = 24
        slow.recentSpanMinutes = 20
        precondition(QuotaPresentation.usageLabel(slow, trusted: true, now: clock) == L("重置时≈64%", "~64% at reset"))
        slow.usedPct = 86
        slow.recentPctPerHour = 2
        precondition(QuotaPresentation.usageLabel(slow, trusted: true, now: clock) == L("重置时≈88%", "~88% at reset"), "High usage without depletion still shows the reset projection")
        slow.usedPct = 10
        slow.recentPctPerHour = 0
        precondition(QuotaPresentation.usageLabel(slow, trusted: true, now: clock) == L("重置时≈13%", "~13% at reset"), "Window-average burn also supplies a forecast")
        slow.windowSeconds = 0
        precondition(QuotaPresentation.usageLabel(slow, trusted: true, now: clock) == nil, "Uncomputable burn preserves the original usage label")
        slow.windowSeconds = 5 * 3600
        slow.usedPct = 100
        precondition(QuotaPresentation.usageLabel(slow, trusted: true, now: clock) == nil, "Already exhausted readings preserve the exhausted label")
    }

    // Regression: quota warning thresholds and stale-sample forecast semantics.
    precondition(VGUsageLevel.evaluate(0) == .normal)
    precondition(VGUsageLevel.evaluate(59) == .normal)
    precondition(VGUsageLevel.evaluate(60) == .elevated)
    precondition(VGUsageLevel.evaluate(85) == .elevated)
    precondition(VGUsageLevel.evaluate(86) == .critical)
    precondition(VGUsageLevel.evaluate(100) == .critical)
    precondition(VGUsageLevel.evaluate(20, predictedDepletion: true) == .critical)
    do {
        let clock: TimeInterval = 1_700_000_000
        var fast = QuotaWindow(usedPct: 20, resetsAt: clock + 4 * 3600, capturedAt: clock, windowSeconds: 5 * 3600)
        fast.recentPctPerHour = 30
        fast.recentSpanMinutes = 20
        precondition(QuotaPresentation.predictedDepletion(fast, now: clock))
        fast.capturedAt = clock - 601
        precondition(!QuotaPresentation.predictedDepletion(fast, now: clock), "Old samples do not generate live warnings")
        fast.capturedAt = clock
        fast.resetsAt = clock
        precondition(!QuotaPresentation.predictedDepletion(fast, now: clock))
    }

    // App-only language changes update labels and formatting without changing system preferences.
    do {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        func selectLanguage(_ value: String) {
            var arguments = original
            arguments[AppLanguage.defaultsKey] = value
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        selectLanguage("en")
        precondition(L("中文", "English") == "English" && formatTokens(10000) == "10K")
        precondition(UITheme.presets.first?.title == "Small")
        let englishAgo = UIFormat.ago(60)
        selectLanguage("zh-Hans")
        precondition(L("中文", "English") == "中文" && formatTokens(10000) == "1万")
        precondition(UITheme.presets.first?.title == "小" && UIFormat.ago(60) != englishAgo)
        selectLanguage("en")
        precondition(UITheme.presets.first?.title == "Small", "switching back must not retain cached labels")
        selectLanguage("unknown")
        precondition(AppLanguage.current == .system)
        precondition(AppLanguage.current.isChinese == (Locale.preferredLanguages.first?.hasPrefix("zh") == true))
    }

    // UI formatting and device priority must preserve the meaning of cached limits.
    do {
        precondition(formatTokens(999, chinese: false) == "999")
        precondition(formatTokens(1_000, chinese: false) == "1K")
        precondition(formatTokens(999_999, chinese: false) == "1M")
        precondition(formatTokens(1_000_000, chinese: false) == "1M")
        precondition(formatTokens(1_000_000_000, chinese: false) == "1B")
        precondition(formatTokens(9_999, chinese: true) == "9,999")
        precondition(formatTokens(10_000, chinese: true) == "1万")
        precondition(formatTokens(99_999_999, chinese: true) == "1亿")
        precondition(formatTokens(100_000_000, chinese: true) == "1亿")
        precondition(formatTokens(12_345, chinese: true) == "1.2万")
        precondition(formatTokens(12_345, chinese: false) == "12.3K")
        precondition(UIFormat.tier("个人 OAuth") == L("个人 OAuth", "Personal OAuth"))
        precondition(UIFormat.tier("Custom plan") == "Custom plan")
        precondition(UIFormat.metadata("角色") == L("角色", "Role"))
        precondition(UIFormat.metadata("Codex 会话记录") == L("Codex 会话记录", "Codex session logs"))
        precondition(UIFormat.metadata("Custom identifier") == "Custom identifier")
        let now: TimeInterval = 1_800_000_000
        precondition(UIFormat.countdown(to: nil, now: now) == nil)
        precondition(UIFormat.countdown(to: now - 1, now: now) == L("已重置", "Reset"))
        let duration = UIFormat.countdown(to: now + 3600, now: now)!
        precondition(!duration.contains("in ") && !duration.contains("后") && !duration.isEmpty)
        precondition(VG.heat(59) == .accentColor && VG.heat(60) == .orange && VG.heat(85) == .orange && VG.heat(86) == .red)
        let current = DetectedLLMRuntime(name: "Current", isRunning: true, tier: "Pro", detail: "",
                                        fiveHour: QuotaWindow(usedPct: 10, resetsAt: now + 3600, capturedAt: now - 60))
        let old = DetectedLLMRuntime(name: "Old", isRunning: true, tier: "Pro", detail: "",
                                    fiveHour: QuotaWindow(usedPct: 100, resetsAt: now + 3600, capturedAt: now - 601))
        let rank: (DetectedLLMRuntime) -> Int = { QuotaPresentation.priority($0, now: now) }
        precondition(rank(current) > rank(old))
        var secondary = current
        secondary.secondaryFiveHour = QuotaWindow(usedPct: 95, resetsAt: now + 3600, capturedAt: now - 60)
        precondition(rank(secondary) > rank(current))
        precondition(QuotaPresentation.primaryWindowIndex(secondary, now: now) == 1)
        precondition(QuotaPresentation.primaryWindowIndex(old, now: now) == nil)
        var mixed = current
        mixed.sevenDay = old.fiveHour
        precondition(QuotaPresentation.primaryWindowIndex(mixed, now: now) == 0)
        mixed.sevenDay = current.fiveHour
        precondition(QuotaPresentation.primaryWindowIndex(mixed, now: now) == 0)
        precondition(QuotaPresentation.primaryWindowIndex(secondary, status: RemoteDeviceStatus(lastSuccess: now, lastAttempt: now, error: "offline"), isRemote: true, now: now) == nil)
        precondition(QuotaPresentation.priority(secondary, status: RemoteDeviceStatus(lastSuccess: now, lastAttempt: now, error: "offline"), isRemote: true, now: now) < rank(current))
        precondition(QuotaPresentation.priority(secondary, status: nil, isRemote: true, now: now) < rank(current))
        var sharedAccount = current
        sharedAccount.quotaNote = "The same account may appear on several devices"
        precondition(!QuotaPresentation.isRetained(sharedAccount) && rank(sharedAccount) == rank(current))
        sharedAccount.quotaNote = L("未取得新额度，保留上次读数", "Quota missing; showing last reading")
        precondition(QuotaPresentation.isRetained(sharedAccount) && rank(sharedAccount) < rank(current))
        precondition(QuotaPresentation.primaryWindowIndex(sharedAccount, now: now) == nil)
        var expired = secondary
        expired.fiveHour = QuotaWindow(usedPct: 100, resetsAt: now, capturedAt: now - 60)
        expired.secondaryFiveHour = nil
        precondition(rank(expired) < rank(current))
        precondition(QuotaPresentation.primaryWindowIndex(expired, now: now) == nil)
        precondition(QuotaPresentation.ringFraction(usedPct: 0) == 0)
        precondition(QuotaPresentation.ringFraction(usedPct: 100) == 1)
        precondition(QuotaPresentation.ringFraction(usedPct: -1) == nil)
        precondition(QuotaPresentation.ringFraction(usedPct: 101) == nil)
        precondition(QuotaPresentation.displayable(current.fiveHour!, now: now))
        precondition(QuotaPresentation.displayable(old.fiveHour!, now: now))
        precondition(!QuotaPresentation.displayable(expired.fiveHour!, now: now))
        precondition(!QuotaPresentation.displayable(QuotaWindow(usedPct: 50), now: now))
        precondition(!QuotaPresentation.displayable(QuotaWindow(usedPct: 50, capturedAt: .infinity), now: now))
        precondition(QuotaPresentation.deviceColumns(scale: 0.85) == 2)
        precondition(QuotaPresentation.deviceColumns(scale: 1.3) == 1)
    }
    // Real find/stat output must remain parseable for paths containing spaces and quotes.
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vg-storage ' fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".codex/sessions")
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let oldFile = sessions.appendingPathComponent("old ' file.bin")
        let newFile = sessions.appendingPathComponent("new file.bin")
        try! Data(repeating: 0x61, count: 2048).write(to: oldFile)
        try! Data(repeating: 0x62, count: 1024).write(to: newFile)
        let scanner = ProcessScanner(home: root.path)
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(scanner.logRetentionDays + 1) * 86400)], ofItemAtPath: oldFile.path)
        let measured = scanner.measureDiskStatsForTesting()!
        let item = measured.items.first { $0.path == sessions.path }!
        precondition(item.files == 2 && item.oldFiles == 1)
        precondition(abs(item.totalMB - 3072.0 / 1_048_576) < 0.000001)
        precondition(abs(item.oldMB - 2048.0 / 1_048_576) < 0.000001)
    }
    // Herdr discovery validation, normalized quota parsing, stale/missing preservation.
    do {
        let devices = RemoteCollector.parseHerdrMachines("""
        [{"target":"fixture-ssh","label":"Research","enabled":true},
         {"target":"fixture-ssh","label":"Duplicate","enabled":true},
         {"target":"disabled","enabled":false},{"target":"invalid;echo","enabled":true},
         {"target":"not-a-bool","enabled":1}]
        """)
        precondition(devices?.count == 1 && devices?.first?.target == "fixture-ssh" && devices?.first?.label == "Research")
        precondition(RemoteCollector.parseHerdrMachines("{}") == nil)
        precondition(RemoteCollector.finiteNumber(true) == nil)
        precondition(RemoteCollector.finiteNumber(Double.infinity) == nil)
        precondition(RemoteCollector.parseQuotaWindow(["used_percentage": true]) == nil)
        precondition(RemoteCollector.parseQuotaWindow(["used_percentage": 101]) == nil)
        precondition(RemoteCollector.parseQuotaWindow(["used_percentage": 42, "resets_at": 1e300, "captured_at": 1e300])?.resetsAt == nil)
        let text = """
        {"__summary__":{"platforms":{"claude":{"tier":"Max","sessions":2,"captured_at":1700000000,"quota":{"five_hour":{"used_percentage":31.5,"resets_at":1700000300,"window_seconds":18000},"seven_day":{"used_percentage":false}}},"codex":{"sessions":0,"quota":{}},"grok":{"sessions":true,"note":"session_count_unavailable","quota":{"seven_day":{"used_percentage":0,"captured_at":1700000100}}},"agy":{"sessions":1,"quota":{"secondary_name":"3p","secondary_five_hour":{"used_percentage":75,"captured_at":1700000200}}}}}}
        {"__ok__":true}
        """
        let rows = RemoteCollector.parseQuotas(text)!
        precondition(rows.map { $0.name } == ["Claude", "Codex", "Grok", "Antigravity"])
        let claude = rows[0]
        precondition(claude.fiveHour?.usedPct == 32 && claude.fiveHour?.capturedAt == 1700000000)
        precondition(claude.fiveHour?.windowSeconds == 18000 && claude.fiveHour!.isExpired(now: 1800000000))
        precondition(claude.sevenDay == nil && claude.isRunning)
        precondition(!rows[1].hasQuota && rows[2].sevenDay?.usedPct == 0 && !rows[2].isRunning)
        precondition(rows[2].detail == L("会话数未知", "Sessions unknown"))
        precondition(rows[3].secondaryFiveHour?.capturedAt == 1700000200)
        precondition(RemoteCollector.parseQuotas(text.replacingOccurrences(of: "\"__ok__\":true", with: "\"__ok__\":false")) == nil)
        precondition(RemoteCollector.parseQuotas(text.replacingOccurrences(of: "\"__ok__\":true", with: "\"__ok__\":1")) == nil)
        let missing = DetectedLLMRuntime(name: "Claude", isRunning: false, tier: "", detail: "")
        let retained = ProcessScanner.retainingMissingQuotas([missing], previous: [claude])[0]
        precondition(retained.fiveHour == claude.fiveHour && !retained.isRunning && !retained.quotaNote.isEmpty)
        let omitted = ProcessScanner.retainingMissingQuotas([], previous: [claude])[0]
        precondition(omitted.fiveHour == claude.fiveHour && !omitted.isRunning)
        let realZero = DetectedLLMRuntime(name: "Claude", isRunning: false, tier: "", detail: "", fiveHour: QuotaWindow(usedPct: 0))
        precondition(ProcessScanner.retainingMissingQuotas([realZero], previous: [claude])[0].fiveHour?.usedPct == 0)
        let now: TimeInterval = 1800000000
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, resetsAt: now + 3600, capturedAt: now - 60), now: now) == .current)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, capturedAt: now - 601), now: now) == .old)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, capturedAt: now - 600), now: now) == .current)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42), now: now) == .undated)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, resetsAt: now, capturedAt: now - 60), now: now) == .reset)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, capturedAt: now + 61), now: now) == .old)
        precondition(QuotaReadingState.evaluate(QuotaWindow(usedPct: 42, capturedAt: now + 60), now: now) == .current)
        precondition(UsageHistory.remoteSourceNote(cli: "Claude", hasHistory: true, isRefreshing: false, failure: "offline")?.contains("offline") == true)
        precondition(UsageHistory.remoteSourceNote(cli: "Claude", hasHistory: false, isRefreshing: false, failure: "offline") != UsageHistory.remoteSourceNote(cli: "Claude", hasHistory: true, isRefreshing: false, failure: "offline"))
        precondition(UsageHistory.remoteSourceNote(cli: "Claude", hasHistory: true, isRefreshing: false, failure: nil) == nil)
        precondition(UsageHistory.remoteSourceNote(cli: "Claude", hasHistory: true, isRefreshing: true, failure: "offline")?.contains("offline") == false)
    }
    precondition(Fmt.modelDisplayName("claude-fable-5-1") == "Fable 5.1")
    precondition(Fmt.modelDisplayName("claude-opus-5") == "Opus 5")
    precondition(Fmt.modelDisplayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
    precondition(Fmt.modelDisplayName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
    precondition(ProcessScanner.codexPlanLabel("prolite") == "Pro Lite")
    precondition(ProcessScanner.codexPlanLabel("plus") == "Plus")
    let now = Date().timeIntervalSince1970
    precondition(QuotaWindow(usedPct: 66, resetsAt: now - 1, capturedAt: nil).effectivePct(now: now) == 0)
    precondition(QuotaWindow(usedPct: 66, resetsAt: now + 100, capturedAt: nil).effectivePct(now: now) == 66)
    precondition(Fmt.countdown(to: now + 90, now: now) == "1m")
    precondition(Fmt.countdown(to: now + 6540, now: now) == "1h49m")
    precondition(Fmt.countdown(to: now + 2 * 86400 + 10 * 3600, now: now) == "2d10h")
    precondition(Fmt.countdown(to: now - 5, now: now) == "已重置")
    precondition(Fmt.parseISODate("2026-09-19T10:34:27.346461+00:00") != nil)   // grok 6 位小数秒
    precondition(Fmt.parseISODate("2026-09-17T09:07:45.133Z") != nil)           // claude 3 位
    precondition(Fmt.parseISODate("2026-09-17T03:14:39Z") != nil)               // 无小数

    // 探测只看可执行文件路径：别人 grep 这些名字不该算"在跑"
    precondition(ProcessScanner.isClaudeCLISession(cmd: "claude --resume abc"))
    precondition(!ProcessScanner.isClaudeCLISession(cmd: "/bin/zsh -c ps -ax | grep claude"))
    precondition(ProcessScanner.isCodexCLISession(cmd: "node /Users/x/.npm-global/bin/codex --foo"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "/Users/x/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "ssh host codex mcp-server"))

    // Codex 额度耗尽文案里的重置时刻
    precondition(Fmt.parseUsageLimitReset("You've hit your usage limit. Visit https://x to purchase more credits or try again at Sep 19th, 2026 5:03 PM.") != nil)
    precondition(Fmt.parseUsageLimitReset("try again at Oct 1st, 2026 12:00 AM") != nil)
    precondition(Fmt.parseUsageLimitReset("no reset info here") == nil)

    // 压力信号排序：按"离各自报警线的距离"，不按百分比（内存 60% 不该压住额度 55%）
    do {
        var s = ScanReport()
        s.totalMemoryGB = 64; s.freePercentage = 40          // 内存已用 60%，线 85 → margin -25
        s.diskTotalGB = 1000; s.diskFreeGB = 500; s.diskFreePct = 50   // 已用 50%，线 90 → margin -40
        s.detectedLLMs = [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "",
                                             fiveHour: QuotaWindow(usedPct: 55, resetsAt: now + 3600, capturedAt: now))]
        precondition(s.tightest?.short == "内存", "60% 内存该压住 55% 额度（离线更近）")
        precondition(s.tightest?.level == 0)
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 82, resetsAt: now + 3600, capturedAt: now)
        precondition(s.tightest?.short == "Claude 5h" && s.tightest?.level == 1, "额度 82% 越线 → 最紧且报警")
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 99, resetsAt: now - 1, capturedAt: now)
        precondition(s.pressures.first(where: { $0.short == "Claude 5h" })?.pct == 0, "过了重置点的旧值不许再报警")
        precondition(s.pressures.contains { $0.short == "磁盘" })
    }

    // 百分位取最近秩：p95 一定落在某次真实调用上
    precondition(Fmt.percentile([100], 0.95) == 100)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
    precondition(Fmt.percentile([], 0.5) == 0)
    precondition(Fmt.ms(0) == "—" && Fmt.ms(312) == "312ms" && Fmt.ms(4298) == "4.3s" && Fmt.ms(62_000) == "1m02s")

    // 价目表：ctx 是"全部输入"，算价前要把缓存读/写扣出来，否则新鲜 token 会被重复计价
    do {
        let t = ProcessScanner.PriceTable(json: [
            "_currency": "CNY", "_asof": "2026-09-18",
            "glm-4.7": ["in": 4.0, "cache_read": 1.0, "cache_write": 5.0, "out": 12.0],
            "zero-price-placeholder": ["in": 0, "out": 0],
        ])
        // 新鲜 60w + 缓存读 30w + 缓存写 10w + 输出 10w
        let c = t.cost(model: "glm-4.7", ctx: 1_000_000, cacheRead: 300_000, cacheWrite: 100_000, out: 100_000)!
        precondition(abs(c - (0.6 * 4.0 + 0.3 * 1.0 + 0.1 * 5.0 + 0.1 * 12.0)) < 1e-9, "算出来 \(c)")
        precondition(t.cost(model: "glm-4.7-flash", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0) != nil, "前缀命中")
        precondition(t.cost(model: "unknown-model", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "没价的模型不许估")
        precondition(t.cost(model: "zero-price-placeholder", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "占位行不算价")
        precondition(ProcessScanner.PriceTable().isEmpty)
    }

    // 用户覆盖价只按行内 Fast 倍率加价，不继承内置 priority 价或重复乘倍率。
    do {
        let row: [String: Any] = ["in": 10, "cache_read": 1, "cache_write": 12.5, "out": 50, "fast_multiplier": 2]
        let engine = CostEngine(user: ProcessScanner.PriceTable(json: ["gpt-6-astra": row]))
        func cost(_ tier: String?) -> Double {
            engine.cost(model: "gpt-6-astra", ctx: 1_000_000, cacheRead: 200_000, cacheWrite: 200_000, out: 100_000, tier: tier)!.value
        }
        precondition(abs(cost(nil) - 13.7) < 1e-9)
        for tier in ["fast", "priority", "  FAST\n", " Priority "] {
            precondition(abs(cost(tier) - 27.4) < 1e-9, "自定义 Fast 只能加价一次：\(tier)")
        }
        precondition(abs(cost("default") - 13.7) < 1e-9 && abs(cost("unknown") - 13.7) < 1e-9)
        for (ctx, read, write, out, expected): (Int64, Int64, Int64, Int64, Double) in [
            (1_000_000, 0, 0, 0, 20), (1_000_000, 1_000_000, 0, 0, 2),
            (1_000_000, 0, 1_000_000, 0, 25), (0, 0, 0, 1_000_000, 100),
        ] {
            precondition(engine.cost(model: "gpt-6-astra", ctx: ctx, cacheRead: read, cacheWrite: write, out: out, tier: "fast")!.value == expected)
        }
        var plain = row; plain.removeValue(forKey: "fast_multiplier")
        precondition(CostEngine(user: ProcessScanner.PriceTable(json: ["gpt-6-astra": plain])).cost(model: "gpt-6-astra", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0, tier: "priority")!.value == 10)
        for value: Any in [1, true, false, 0, 0.5, -1, "2", NSNull(), Double.infinity, -Double.infinity, Double.nan] {
            var invalid = row; invalid["fast_multiplier"] = value
            let table = ProcessScanner.PriceTable(json: ["gpt-6-astra": invalid])
            precondition(table.rows["gpt-6-astra"]?.fastMultiplier == 1)
            precondition(table.cost(model: "gpt-6-astra", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0, tier: "fast") == 10)
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"gpt-6-astra":{"in":10,"fast_multiplier":true}}"#.utf8)) as! [String: Any]
        precondition(ProcessScanner.PriceTable(json: parsed).rows["gpt-6-astra"]?.fastMultiplier == 1, "JSON boolean 不能当倍率")
    } catch { preconditionFailure("自定义 Fast 价自测失败：\(error)") }

    // 峰谷价：同一模型同一用量，峰时按峰价、闲时按闲价；没配 _peak/offpeak 就恒用峰价（老行为）
    do {
        let json: [String: Any] = [
            "_currency": "CNY",
            "_peak": ["tz": "Asia/Shanghai", "windows": ["09:00-12:00", "14:00-18:00"]],
            "ds": ["in": 9.0, "cache_read": 0.3, "out": 27.0, "fast_multiplier": 2, "offpeak": ["in": 4.5, "cache_read": 0.15, "out": 13.5]],
            "flat": ["in": 2.0, "out": 4.0],
        ]
        let t = ProcessScanner.PriceTable(json: json)
        func at(_ hhmm: String) -> Date {
            var comp = DateComponents()
            comp.year = 2026; comp.month = 9; comp.day = 22
            comp.hour = Int(hhmm.prefix(2)); comp.minute = Int(hhmm.suffix(2))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return cal.date(from: comp)!
        }
        // 100 万新鲜输入 + 100 万输出
        precondition(abs((t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("10:00")) ?? -1) - 36.0) < 1e-9, "峰时该是 9+27")
        precondition(abs((t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("20:00")) ?? -1) - 18.0) < 1e-9, "闲时该是 4.5+13.5")
        precondition(abs((t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("12:30")) ?? -1) - 18.0) < 1e-9, "12:30 落在窗口外")
        precondition(t.cost(model: "flat", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("20:00")) == 6.0, "没配闲时价就全天同价")
        precondition(t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000) == 36.0, "不传时间恒用峰价")
        precondition(t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("10:00"), tier: "fast") == 72.0)
        precondition(t.cost(model: "ds", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000_000, at: at("20:00"), tier: "priority") == 36.0)
    }

    // 价格同步：0 价不算价；同名模型在多 provider 下出现时，优先 provider 的那条赢
    do {
        let root: [String: Any] = [
            "deepseek": ["models": ["deepseek-v4-pro": ["cost": ["input": 0.435, "output": 0.87, "cache_read": 0.003625]]]],
            "some-aggregator": ["models": ["deepseek-v4-pro": ["cost": ["input": 9.0, "output": 27.0]]]],
            "empty-provider": ["models": ["nothing": ["cost": ["input": 0, "output": 0]]]],
        ]
        let parsed = PriceSync.parse(root)
        precondition(parsed["deepseek-v4-pro"]?["in"] == 0.435, "优先 provider 该赢，实际 \(String(describing: parsed["deepseek-v4-pro"]))")
        precondition(parsed["nothing"] == nil, "0 价不算价")
        precondition(parsed.count == 1, "实际 \(parsed.count) 条")
    }

    // 订阅制 Coding Plan 的额度估算：滚动窗口内的请求数 ÷ 上限
    do {
        let stamps: [TimeInterval] = (0..<600).map { now - Double($0) * 10 }      // 最近 100 分钟里 600 次
        let w = ProcessScanner.rollingWindow(stamps, seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(w.usedPct == 50, "600/1200 该是 50%，实际 \(w.usedPct)")
        precondition(abs((w.resetsAt ?? 0) - (stamps.min()! + 5 * 3600)) < 1, "重置点 = 窗口内最早一次 + 窗口长")
        let old = ProcessScanner.rollingWindow([now - 6 * 3600], seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(old.usedPct == 0, "窗口外的调用不该算")
        precondition(ProcessScanner.rollingWindow(stamps, seconds: 3600, limit: 0, now: now) == nil, "没填上限就不估")
    }

    // 内存吃紧才立刻收割，且 5 分钟内不重复
    precondition(AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: 0, now: now))
    precondition(!AppDelegate.shouldReapForMemory(usedPct: 60, lastCleanAt: 0, now: now), "内存不紧就别动")
    precondition(!AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: now - 60, now: now), "1 分钟前刚清过")
    precondition(AppDelegate.shouldReapForMemory(usedPct: 90, lastCleanAt: now - 400, now: now))

    // 限流响应头 → 额度（各家写法不同，统一按"去掉 limit/remaining/reset 后同族"配对）
    do {
        // Anthropic：族名在前，reset 是 ISO8601
        let a = ProcessScanner.parseRateLimitHeaders([
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "900",
            "anthropic-ratelimit-requests-reset": "2026-09-18T12:00:00Z",
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "20000",      // 更紧 → 应该选这族
            "anthropic-ratelimit-tokens-reset": "2026-09-18T12:00:00Z",
        ], now: now)!
        precondition(a.usedPct == 80 && a.label == "tokens", "实际 \(a)")
        precondition(a.resetsAt != nil)

        // OpenAI：kind 在中间，reset 是时长
        let o = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit-requests": "500",
            "x-ratelimit-remaining-requests": "125",
            "x-ratelimit-reset-requests": "6m0s",
        ], now: now)!
        precondition(o.usedPct == 75 && o.label == "requests", "实际 \(o)")
        precondition(abs((o.resetsAt ?? 0) - (now + 360)) < 1, "6m0s = 360 秒")

        // GitHub/通用：epoch 秒（真实抓的样本形态）
        let g = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit": "60", "x-ratelimit-remaining": "58",
            "x-ratelimit-used": "2", "x-ratelimit-resource": "core",
            "x-ratelimit-reset": "1789727826",
        ], now: now)!
        precondition(g.usedPct == 3, "58/60 → 已用 3%，实际 \(g.usedPct)")
        precondition(abs((g.resetsAt ?? 0) - 1789727826) < 1)

        // 毫秒时间戳 / 纯相对秒数
        precondition(abs((ProcessScanner.parseResetValue("1789727826000", now: now) ?? 0) - 1789727826) < 1)
        precondition(abs((ProcessScanner.parseResetValue("30", now: now) ?? 0) - (now + 30)) < 1)
        precondition(abs((ProcessScanner.parseResetValue("1h2m3s", now: now) ?? 0) - (now + 3723)) < 1)
        // 没有 limit/remaining 配对就不瞎猜
        precondition(ProcessScanner.parseRateLimitHeaders(["x-ratelimit-reset": "60"], now: now) == nil)
        precondition(ProcessScanner.parseRateLimitHeaders(["content-type": "application/json"], now: now) == nil)
    }

    // 记账覆盖体检：只抠变量名与主机，同一行的 key 一律不碰
    do {
        let pfx = "http://127.0.0.1:18790/"
        let a = ProcessScanner.parseBaseURLLine("  export ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic", proxyPrefix: pfx)!
        precondition(a.name == "ANTHROPIC_BASE_URL" && a.host == "open.bigmodel.cn" && a.proxied)
        let b = ProcessScanner.parseBaseURLLine("OPENAI_API_BASE='https://api.deepseek.com/v1'", proxyPrefix: pfx)!
        precondition(b.host == "api.deepseek.com" && !b.proxied)
        precondition(ProcessScanner.parseBaseURLLine("# ANTHROPIC_BASE_URL=https://x.com", proxyPrefix: pfx) == nil, "注释行不算")
        precondition(ProcessScanner.parseBaseURLLine("export ANTHROPIC_API_KEY=sk-ant-xxxx", proxyPrefix: pfx) == nil, "key 行不该被当成 BASE_URL")
        precondition(ProcessScanner.parseBaseURLLine("alias cc='claude'", proxyPrefix: pfx) == nil)
        // zsh 里这些行普遍以续行符结尾，别被它吃掉
        let c = ProcessScanner.parseBaseURLLine("    ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://openrouter.ai/api \\", proxyPrefix: pfx)!
        precondition(c.host == "openrouter.ai" && c.proxied, "实际 \(c)")
        let d = ProcessScanner.parseBaseURLLine("  ANTHROPIC_BASE_URL=\"http://127.0.0.1:18790/http://localhost:18080\" \\", proxyPrefix: pfx)!
        precondition(d.host == "localhost:18080" && d.proxied, "实际 \(d)")
    }

    // 燃烧速率：窗口长度 + 重置点 → 不用攒历史采样
    do {
        // 5h 窗口过了 1 小时用掉 20% → 4%/h，到重置(还剩 4h)会到 100%
        let w = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        let b = w.burn(now: now)!
        precondition(abs(b.pctPerHour - 20.0) < 0.01, "1 小时用 20% = 20%/h，实际 \(b.pctPerHour)")
        precondition(b.projectedAtReset == 100, "实际 \(b.projectedAtReset)")
        precondition(b.exhaustAt != nil && abs(b.exhaustAt! - (now + 4 * 3600)) < 60)
        // 慢速：4h 才用 10% → 到重置只有 12%，不该报"会打满"
        let slow = QuotaWindow(usedPct: 10, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600)
        precondition(slow.burn(now: now)!.exhaustAt == nil)
        // 窗口刚开头 / 没窗口长度 / 已过重置 → 一律不推算，不瞎猜
        precondition(QuotaWindow(usedPct: 5, resetsAt: now + 17_500, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)  // 窗口才过 500 秒
        precondition(QuotaWindow(usedPct: 50, resetsAt: now + 3600, capturedAt: now).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 50, resetsAt: now - 1, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 100, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil, "已打满不推算")

        // 近期速度优先：窗口均速只有 4%/h，但近 30 分钟在以 60%/h 猛烧 → 必须按近期算
        var hot = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        hot.recentPctPerHour = 60; hot.recentSpanMinutes = 30
        let hb = hot.burn(now: now)!
        precondition(hb.isRecent && hb.basis == "近 30 分钟")
        precondition(hb.projectedAtReset == 260, "20 + 60*4 = 260，实际 \(hb.projectedAtReset)")
        precondition(hb.exhaustAt != nil && abs(hb.exhaustAt! - (now + 80.0 / 60 * 3600)) < 60)
        // 跨度不足 10 分钟 → 噪声太大，退回窗口均速
        var noisy = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        noisy.recentPctPerHour = 60; noisy.recentSpanMinutes = 3
        precondition(noisy.burn(now: now)!.basis == "本窗口均")
        // 有近期速度时，窗口刚开头也能算（不必等满 15 分钟）
        var early = QuotaWindow(usedPct: 2, resetsAt: now + 17_700, capturedAt: now, windowSeconds: 5 * 3600)
        early.recentPctPerHour = 12; early.recentSpanMinutes = 15
        precondition(early.burn(now: now)?.isRecent == true)
    }

    // 会话日志保留期硬下限 7 天（本工具自己要读近两天的文件算额度）
    precondition(ProcessScanner.effectiveRetention(30) == 30)
    precondition(ProcessScanner.effectiveRetention(3) == 7)
    precondition(ProcessScanner.effectiveRetention(0) == 7)
    precondition(ProcessScanner.effectiveRetention(-99) == 7)

    // ssh 主机名会被拼进 shell 命令 → 只放行合法主机名
    precondition(ProcessScanner.isValidSSHHost("fixture-host"))
    precondition(ProcessScanner.isValidSSHHost("fixture@192.0.2.9"))
    precondition(!ProcessScanner.isValidSSHHost("-Fx"))
    precondition(!ProcessScanner.isValidSSHHost("-oProxyCommand=x"))
    precondition(!ProcessScanner.isValidSSHHost("-fixture@host"))
    precondition(!ProcessScanner.isValidSSHHost("fixture@-host"))
    precondition(!ProcessScanner.isValidSSHHost("fixture-host; rm -rf ~"))
    precondition(!ProcessScanner.isValidSSHHost("$(whoami)"))
    precondition(!ProcessScanner.isValidSSHHost("a`id`b"))
    precondition(!ProcessScanner.isValidSSHHost(""))

    // 网络解析只用文档地址；不把本机出口、节点或账户信息写进测试。
    do {
        let trace = parseTrace("fl=fixture\nip=192.0.2.7\nloc=US\ncolo=SJC\n")!
        precondition(trace.ip == "192.0.2.7" && trace.loc == "US" && trace.colo == "SJC")
        precondition(parseTrace(" colo=NRT\r\nloc=JP\r\nip=198.51.100.8\r\n")?.colo == "NRT")
        precondition(parseTrace("ip=not-an-ip\nloc=US\ncolo=SJC") == nil)
        precondition(parseTrace("ip=192.0.2.7\nloc=US") == nil)
        precondition(parseTrace("<html>unavailable</html>") == nil)
        precondition(rate(prev: UInt64(100), cur: 300, dt: 2) == 100)
        precondition(rate(prev: UInt64(100), cur: 100, dt: 2) == 0)
        precondition(rate(prev: UInt64.max, cur: 2, dt: 2) == nil)
        precondition(rate(prev: UInt64(100), cur: 1, dt: 2) == nil)
        precondition(rate(prev: UInt64(0), cur: 1, dt: 0) == nil)
        precondition(rate(prev: UInt64(0), cur: 1, dt: .infinity) == nil)
        precondition(rate(prev: Int64(-1), cur: 1, dt: 2) == nil)
        precondition(ipv6Verdict(traceIP: "149.119.151.8", httpStatus: 200).blocked)  // IPv4 映射：走隧道，不是泄漏
        precondition(!ipv6Verdict(traceIP: "240e:390::1", httpStatus: 200).blocked)
        precondition(ipv6Verdict(traceIP: nil, httpStatus: 0).blocked)
        precondition(!ipv6Verdict(traceIP: nil, httpStatus: 200).blocked)
        precondition(dnsVerdict([]) == .unknown)
        precondition(dnsVerdict(["192.0.2.1"]) == .unknown)
        precondition(dnsVerdict(["198.18.0.1", "127.0.0.1"]) == .proxyOK)
        precondition(dnsVerdict(["198.19.255.254"]) == .proxyOK)
        precondition(dnsVerdict(["198.20.0.1"]) == .unknown)
        precondition(dnsVerdict(["198.18.0.999"]) == .unknown)
        precondition(dnsVerdict(["127.0.0.1", "192.0.2.1"]) == .unknown)
        // 这是 DNS 规则中必须识别的公共服务地址，不是本机或节点地址。
        precondition(dnsVerdict(["127.0.0.1", "223.5.5.5"]) == .domesticWarning)
        let dns = "nameserver[0] : 203.0.113.1\nresolver #11\n nameserver[0] : 203.0.113.2\nresolver #1\n nameserver[0] : 192.0.2.1\n nameserver[1] : 198.51.100.1\nresolver #2\n nameserver[0] : 203.0.113.3"
        precondition(NetworkScanner.parseDNS(dns) == ["192.0.2.1", "198.51.100.1"])
        precondition(NetworkScanner.parseDNS("resolver #1\n nameserver[0] : 192.0.2.1\nresolver #1\n nameserver[0] : 203.0.113.1") == ["192.0.2.1"])
        let counters = NetworkScanner.parseNetstat("Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#1> fixture 1 0 1024 2 0 2048 0", iface: "en0")!
        precondition(counters.input == 1024 && counters.output == 2048)
        precondition(NetworkScanner.parseNetstat("no counters", iface: "en0") == nil)
        precondition(NetworkScanner.isGlobalIPv6("2001:db8::1"))
        precondition(!NetworkScanner.isGlobalIPv6("fe80::1") && !NetworkScanner.isGlobalIPv6("fd00::1"))
        precondition(NetworkScanner.validatedClashURL("http://127.0.0.1:9090") != nil)
        precondition(NetworkScanner.validatedClashURL("http://localhost:9090")?.host == "127.0.0.1")
        precondition(NetworkScanner.validatedClashURL("http://192.0.2.1:9090") == nil)
        precondition(NetworkScanner.validatedClashURL("http://127.0.0.1:9090/?url=fixture") == nil)
        let connections = NetworkScanner.parseConnections(["connections": [
            ["metadata": ["host": "API.OPENAI.COM."], "chains": ["fixture-exit", "fixture-select"], "rule": "DomainSuffix", "rulePayload": "openai.com"],
            ["metadata": ["host": "api.openai.com"], "chains": ["fixture-exit", "fixture-select"]],
            ["metadata": ["host": "chatgpt.com"], "chains": ["fixture-direct"]],
            ["metadata": ["host": "generativelanguage.googleapis.com"], "chains": ["fixture-gemini"]],
            ["metadata": ["host": "notopenai.com"], "chains": ["fixture-unmatched"]]
        ]])!
        let api = connections.first { $0.name == "OpenAI API" }!
        precondition(api.count == 2 && api.chains == ["fixture-exit → fixture-select"] && api.rules == ["DomainSuffix:openai.com"])
        precondition(connections.first { $0.name == "ChatGPT/Codex" }?.count == 1)
        precondition(connections.first { $0.name == "Gemini" }?.count == 1)
        precondition(NetworkScanner.parseConnections([:]) == nil)
        var first = AIExitStatus(id: "fixture", name: "Fixture AI", host: "example.test")
        var second = first
        second.ip = "192.0.2.1"; second.loc = "US"; second.capturedAt = 1
        precondition(exitChange(previous: first, current: second) == nil)
        first = second
        precondition(exitChange(previous: first, current: second) == nil)
        second.ip = "198.51.100.1"
        precondition(exitChange(previous: first, current: second)?.isCountryChange == false)
        second = first; second.loc = "JP"
        precondition(exitChange(previous: first, current: second)?.isCountryChange == true)
        precondition(AppDelegate.shouldNotifyExit(lastAt: nil, now: 1))
        precondition(!AppDelegate.shouldNotifyExit(lastAt: 1, now: 600))
        precondition(AppDelegate.shouldNotifyExit(lastAt: 1, now: 601))
    }

    do {
        let suite = "vibedeck-selftest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 4)
        defaults.set(2, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 2, "迁移只能执行一次")
        // 隐藏 API 页后，旧选择不能停在已经不存在的分段上；重新打开时保留。
        defaults.set(false, forKey: "vg.showAPITab")
        defaults.set(1, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 0, "隐藏 API 页要退出 1")
        defaults.set(true, forKey: "vg.showAPITab")
        defaults.set(1, forKey: "vg.tab")
        DashboardView.migrateTabSelection(defaults: defaults)
        precondition(defaults.integer(forKey: "vg.tab") == 1, "显示 API 页时保留 1")
    }

    // 设备作用域：序列化往返 + 「来源属于哪台设备」的归属判定
    do {
        precondition(DeviceScope.from(key: "all") == .all)
        precondition(DeviceScope.from(key: "local") == .local)
        precondition(DeviceScope.from(key: "remote:wsl") == .remote("wsl"))
        precondition(DeviceScope.from(key: "remote:") == .all, "空主机名回落全部")
        precondition(DeviceScope.from(key: "nonsense") == .all)
        precondition(DeviceScope.all.key == "all")
        precondition(DeviceScope.local.key == "local")
        precondition(DeviceScope.remote("wsl").key == "remote:wsl")
        precondition(DeviceScope.from(key: DeviceScope.remote("box").key) == .remote("box"))
        precondition(DeviceScope.remote("gone").resolved(hosts: ["wsl", "gpu"]) == .all, "主机被删后回落全部")
        precondition(DeviceScope.remote("wsl").resolved(hosts: ["wsl", "gpu"]) == .remote("wsl"))

        let hosts = ["wsl", "gpu"]
        precondition(DeviceScope.includes(source: "Claude", scope: .all, hosts: hosts))
        precondition(DeviceScope.includes(source: "OpenCode · wsl", scope: .all, hosts: hosts))
        precondition(DeviceScope.includes(source: "Claude", scope: .local, hosts: hosts))
        precondition(DeviceScope.includes(source: "OpenCode", scope: .local, hosts: hosts))
        precondition(DeviceScope.includes(source: "API · GLM", scope: .local, hosts: hosts), "API 记账算本机")
        precondition(!DeviceScope.includes(source: "OpenCode · wsl", scope: .local, hosts: hosts), "远程来源不算本机")
        precondition(!DeviceScope.includes(source: "OpenCode · removed", scope: .local, hosts: hosts), "已移除远程设备的历史不混入本机")
        precondition(DeviceScope.includes(source: "OpenCode · wsl", scope: .remote("wsl"), hosts: hosts))
        precondition(!DeviceScope.includes(source: "OpenCode · gpu", scope: .remote("wsl"), hosts: hosts), "别的远程主机不算")
        precondition(!DeviceScope.includes(source: "Claude", scope: .remote("wsl"), hosts: hosts), "本机来源不算远程")

        var localCodex = CLIUsage(name: "Codex")
        localCodex.ctx = 100; localCodex.cacheRead = 60; localCodex.out = 10; localCodex.requests = 2
        let localRows = [localCodex, CLIUsage(name: "Claude Code")]
        let today: [String: UsageHistory.Totals] = [
            "Codex": .init(ctx: 150, cacheRead: 60, out: 15, turns: 3),
            "Codex · wsl": .init(ctx: 300, cacheRead: 200, out: 30, think: 5, turns: 3),
            "Codex · gpu": .init(ctx: 500, cacheRead: 400, out: 50, think: 7, turns: 4),
            "OpenCode": .init(ctx: 20, out: 2, turns: 1),
            "API · Codex": .init(ctx: 9000, out: 900, turns: 90)
        ]
        let allRows = DeviceScope.todayUsage(local: localRows, history: today, scope: .all)
        let allCodex = allRows.first { $0.name == "Codex" }!
        precondition(allCodex.ctx == 950 && allCodex.out == 95 && allCodex.cacheRead == 660 && allCodex.think == 12)
        precondition(allCodex.requests == 10, "全部合并各设备，本机实时行和 API 代理不重复计数")
        precondition(allRows.first { $0.name == "opencode" }?.ctx == 20)
        let localOnly = DeviceScope.todayUsage(local: localRows, history: today, scope: .local)
        precondition(localOnly.first { $0.name == "Codex" }?.ctx == 150, "以包括归档记录的历史为准")
        let wslOnly = DeviceScope.todayUsage(local: localRows, history: today, scope: .remote("wsl"))
        precondition(wslOnly.count == 1 && wslOnly[0].ctx == 300 && wslOnly[0].requests == 3)
        precondition(DeviceScope.todayUsage(local: localRows, history: [:], scope: .remote("wsl")).isEmpty)
        precondition(DeviceScope.todayUsage(local: localRows, history: [:], scope: .local).first { $0.name == "Codex" }?.ctx == 0)
        precondition(DeviceScope.todayUsage(local: localRows, history: [:], scope: .all, historyReady: false).first { $0.name == "Codex" }?.ctx == 100)
        precondition(DeviceScope.todayUsage(local: localRows, history: today, scope: .remote("wsl"), historyReady: false).isEmpty)
        var grok = CLIUsage(name: "Grok"); grok.turns = 7; grok.note = "no token fields"
        // Grok now has per-turn usage history; the live turn-only row is replaced by it once history is ready.
        precondition(DeviceScope.todayUsage(local: [grok], history: today, scope: .all, historyReady: false).first { $0.name == "Grok" }?.turns == 7)
        var grokToday = today; grokToday["Grok · wsl"] = .init(ctx: 40, out: 4, turns: 2)
        let grokRow = DeviceScope.todayUsage(local: [grok], history: grokToday, scope: .all).first { $0.name == "Grok" }
        precondition(grokRow?.ctx == 40 && grokRow?.requests == 2, "Grok rows come from collected history")
        do {
            // GLM quota: unit 3 = hours (5h window), unit 6 = weeks.
            let wire: [String: Any] = ["code": 200, "data": ["level": "pro", "limits": [
                ["unit": 6, "number": 1, "percentage": 24, "nextResetTime": 1793181302976],
                ["unit": 3, "number": 5, "percentage": 2, "nextResetTime": 1793037465914]]]]
            let glm = ProcessScanner.parseGLMQuota(wire, key: "abcd1234", now: 1793022443)!
            precondition(glm.tier == "Coding Pro" && glm.fiveHour?.usedPct == 2 && glm.fiveHour?.windowSeconds == 18000)
            precondition(glm.weekly?.usedPct == 24 && glm.weekly?.windowSeconds == 604800 && glm.weekly?.resetsAt == 1793181302.976)
            precondition(ProcessScanner.parseGLMQuota(["code": 401, "msg": "expired"], key: "k", now: 0) == nil)
            // Grok usage.json → per-turn records with xAI's own cost.
            let dir = NSTemporaryDirectory() + "vibedeck-grok-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let usage = #"{"sessionId":"s1","turns":[{"turnNumber":1,"endedAt":"2026-10-26T10:34:27.549822720+00:00","inputTokens":17394,"outputTokens":39,"cachedReadTokens":1664,"cacheCreationTokens":0,"reasoningTokens":31,"costUsdTicks":110588400,"primaryModelId":"grok-4.7-build"}]}"#
            FileManager.default.createFile(atPath: dir + "/usage.json", contents: Data(usage.utf8))
            let turn = GrokUsage.records(path: dir + "/usage.json")["grok:s1:1"]!
            precondition(turn.usage.ctx == 17394 && turn.usage.cacheRead == 1664 && turn.usage.out == 39 && turn.usage.think == 31)
            precondition(abs(turn.billed!.value - 0.01105884) < 1e-9 && turn.billed!.currency == "USD" && turn.model == "grok-4.7-build")
            precondition(abs(turn.timestamp - 1793010867.549) < 0.01)
            // DSH ledger split by provider:model keeps DSH's own CNY cost; free relay models cost 0.
            let ledger = #"{"days":{"2026-10-25":{"input":10,"output":2,"cacheRead":5,"byProviderModel":{"deepseek-official:deepseek-flash":{"input":8,"output":2,"cacheRead":5,"costCny":0.5},"magpie:opencode-zen-free/glm-5.3-flash-free":{"input":2,"output":0,"cacheRead":0,"costCny":0}}}}}"#
            FileManager.default.createFile(atPath: dir + "/ledger.json", contents: Data(ledger.utf8))
            let dsh = DSHUsage.read(path: dir + "/ledger.json", now: 1793022443)!.records
            precondition(dsh.count == 2 && dsh["dsh:2026-10-25:deepseek-official:deepseek-flash"]?.billed == .init(value: 0.5, currency: "CNY"))
            precondition(dsh["dsh:2026-10-25:magpie:opencode-zen-free/glm-5.3-flash-free"]?.model == "opencode-zen-free/glm-5.3-flash-free")
            try? FileManager.default.removeItem(atPath: dir)
            // Remote DSH / Grok records and their reported cost.
            let remote = RemoteCollector.parseCLIRecords(jsonl: """
            {"k":"dsh","id":"m1","t":1793018920.3,"m":"deepseek-flash","p":"magpie","in":5560,"cr":384,"cw":0,"out":95,"th":0,"s":"session-a"}
            {"k":"dsh","id":"m2","t":1793018921.3,"m":"opencode-zen-free/x-free","in":10,"cr":0,"out":1,"c":0,"cur":"USD"}
            {"k":"grok","id":"s1:1","t":1793010867.5,"m":"grok-4.7-build","in":17394,"cr":1664,"out":39,"th":31,"c":0.011,"cur":"USD"}
            {"__ok__":true,"count":3,"max_mtime":1}
            """, host: "wsl")
            precondition(remote.ok && remote.records.count == 3)
            precondition(remote.records.contains { $0.source == "DSH · wsl" && $0.id == "dsh:m1" && $0.billed == nil && $0.usage.ctx == 5560 })
            precondition(remote.records.contains { $0.id == "dsh:m2" && $0.billed?.value == 0 })
            precondition(remote.records.contains { $0.source == "Grok · wsl" && $0.billed?.value == 0.011 })
        }
        var snapshot = UsageHistory.Snapshot()
        let midnight = Fmt.parseISODate("2026-10-01T16:00:00Z")!
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        snapshot.capturedAt = midnight - 1; snapshot.todayBySource = today
        precondition(snapshot.currentDaySources(at: midnight - 1, timeZone: timeZone) == today)
        let nextDay = snapshot.currentDaySources(at: midnight, timeZone: timeZone)
        precondition(nextDay.isEmpty)
        precondition(DeviceScope.todayUsage(local: localRows, history: nextDay, scope: .all,
                                          historyReady: snapshot.capturedAt > 0).first { $0.name == "Codex" }?.ctx == 0,
                     "昨日快照进入新一天后不能回退旧的本机今日行")
    }

    do {
        precondition(UsageHistory.levels([]) == [])
        precondition(UsageHistory.levels([0, 0, -1]) == [0, 0, 0])
        precondition(UsageHistory.levels([0, 1, 2, 3, 4, 5]) == [0, 1, 2, 3, 4, 5])
        precondition(Set(UsageHistory.levels([10, 10, 10])).count == 1)
        let boundary = Fmt.parseISODate("2026-09-18T16:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        precondition(UsageHistory.dayKey(timestamp: boundary, timeZone: zone) == "2026-09-19")
        precondition(UsageHistory.dayKey(timestamp: boundary - 1, timeZone: zone) == "2026-09-18")
        precondition(UsageHistory.dayKey(timestamp: boundary, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-09-18")
        let last = UsageHistory.codexLastTokenUsage(["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10, "reasoning_output_tokens": 2])
        precondition(last.ctx == 100 && last.cacheRead == 40 && last.out == 10 && last.think == 2)
        let delta = UsageHistory.codexCumulativeDelta(previous: ["input_tokens": 100, "output_tokens": 10], current: ["input_tokens": 130, "output_tokens": 15])!
        precondition(delta.ctx == 30 && delta.out == 5)
        precondition(UsageHistory.codexCumulativeDelta(previous: ["input_tokens": 100], current: ["input_tokens": 10]) == nil)
        var prior: [String: Int64]?
        let one: [String: Int64] = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10]
        let two: [String: Int64] = ["input_tokens": 200, "cached_input_tokens": 80, "output_tokens": 20]
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": one], previous: &prior)?.usage.ctx == 100)
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": two], previous: &prior)?.usage.ctx == 100)
        precondition(UsageHistory.codexUsage(info: ["last_token_usage": one, "total_token_usage": two], previous: &prior) == nil)
        precondition(UsageHistory.codexUsage(info: [:], previous: &prior) == nil)
        let a = UsageHistory.Record(id: "fixture-request", source: "Claude", timestamp: boundary, model: "fixture-model", usage: last)
        var updated = a; updated.usage.out = 20
        let merged = UsageHistory.deduplicateClaude(["file-a": [a, updated], "file-b": [updated]])
        precondition(merged.count == 1 && merged[a.id]?.usage.out == 20)
        precondition(Fmt.tokens(10_000) == "1.0 万" && Fmt.tokens(100_000_000) == "1.00 亿")
    }

    // opencode：total = input + output + reasoning + cache.read + cache.write，映射后必须等于 ctx + out
    do {
        let row = OpenCodeUsage.Row(id: "msg_fixture", session: "ses_fixture", provider: "deepseek", model: "deepseek-v4-pro",
                                    createdAt: 1_781_494_632, input: 22_011, output: 328, reasoning: 72, cacheRead: 3_968, cacheWrite: 0, seconds: 4)
        let totals = OpenCodeUsage.totals(row)
        precondition(totals.ctx == 25_979 && totals.cacheRead == 3_968 && totals.cacheWrite == 0, "实际 \(totals)")
        precondition(totals.out == 400 && totals.think == 72, "思考要含在输出里")
        precondition(totals.tokenTotal == 26_379, "必须等于 opencode 的 total")
        let records = OpenCodeUsage.records(rows: [row])
        precondition(records["msg_fixture"]?.source == "OpenCode" && records["msg_fixture"]?.session == "ses_fixture")
        precondition(records["msg_fixture"]?.model == "deepseek-v4-pro")
        precondition(records["msg_fixture"]?.timing?.speed(output: 400, proxy: false) == 100)
        for seconds in [0.5, 601, -1] {
            var invalid = row; invalid.seconds = seconds
            precondition(OpenCodeUsage.records(rows: [invalid])[invalid.id]?.timing?.speed(output: 400, proxy: false) == nil)
        }
        let blank = OpenCodeUsage.Row(id: "", session: nil, provider: "", model: "", createdAt: 0,
                                      input: 1, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)
        precondition(OpenCodeUsage.records(rows: [blank]).isEmpty, "没有 id 的行不许进统计")
    }

    // 远程采集：坏行跳过、哨兵说成功才认、max_u 供增量游标
    do {
        let jsonl = """
        {"id":"msg_a","t":1781494632,"u":1781494641564,"s":"ses_1","m":"deepseek-v4-flash","p":"deepseek","in":229,"out":387,"r":28,"cr":7680,"cw":0,"seconds":5}
        这一行不是 JSON
        {"id":"msg_b","t":1781494641,"u":1781494646770,"s":"ses_1","m":"deepseek-v4-flash","p":"deepseek","in":0,"out":0,"r":0,"cr":0,"cw":0}
        {"__ok__":true,"count":2,"max_u":1781494646770}
        """
        let parsed = RemoteCollector.parse(jsonl: jsonl, source: "OpenCode · fixture-host")
        precondition(parsed.ok && parsed.records.count == 2, "实际 \(parsed.records.count) 条")
        precondition(parsed.maxUpdated == 1_781_494_646_770, "实际 \(parsed.maxUpdated)")
        precondition(parsed.records.allSatisfy { $0.source == "OpenCode · fixture-host" })
        precondition(parsed.records.first { $0.id == "msg_a" }?.usage.tokenTotal == 8_324)
        precondition(parsed.records.first { $0.id == "msg_a" }?.timing?.speed(output: 415, proxy: false) == 83)
        precondition(parsed.records.first { $0.id == "msg_b" }?.timing == nil, "old collector remains compatible")
        precondition(!RemoteCollector.parse(jsonl: #"{"__ok__":false,"error":"x"}"#, source: "s").ok, "哨兵说失败就不认")
        precondition(!RemoteCollector.parse(jsonl: #"{"id":"a","t":1}"#, source: "s").ok, "没有哨兵不能当成功")
    }

    // opencode 真库路径：临时建库 → 走完整汇总 → 库被删/读坏都要保留已缓存历史
    do {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibedeck-opencode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("opencode.db").path
        var handle: OpaquePointer?
        precondition(sqlite3_open(dbPath, &handle) == SQLITE_OK && handle != nil, "临时库建不出来")
        defer { sqlite3_close(handle) }
        let seed = """
        CREATE TABLE message(id text primary key, session_id text not null, time_created integer not null, time_updated integer not null, data text not null);
        INSERT INTO message VALUES ('msg_1','ses_1',1781494632598,1781494632598,'{"role":"assistant","providerID":"deepseek","modelID":"deepseek-v4-pro","time":{"created":1781494632598,"completed":1781494636598},"tokens":{"total":26379,"input":22011,"output":328,"reasoning":72,"cache":{"read":3968,"write":0}}}');
        INSERT INTO message VALUES ('msg_2','ses_1',1781494641355,1781494641355,'{"role":"assistant","providerID":"deepseek","modelID":"deepseek-v4-flash","tokens":{"total":8324,"input":229,"output":387,"reasoning":28,"cache":{"read":7680,"write":0}}}');
        INSERT INTO message VALUES ('msg_user','ses_1',1781494630000,1781494630000,'{"role":"user"}');
        INSERT INTO message VALUES ('msg_none','ses_1',1781494640000,1781494640000,'{"role":"assistant"}');
        """
        precondition(sqlite3_exec(handle, seed, nil, nil, nil) == SQLITE_OK, "灌数据失败")
        let rawRows = OpenCodeUsage.read(dbPath: dbPath)!
        precondition(rawRows["msg_1"]?.timing?.speed(output: 400, proxy: false) == 100, "SQLite created/completed timing")
        precondition(rawRows["msg_2"]?.timing == nil, "unfinished/old OpenCode records remain untimed")
        let collector = UsageHistory(home: root.path, opencodeDB: dbPath)
        collector.scanNowForTesting()
        var opencode = collector.snapshot().totals["OpenCode"]
        precondition(opencode?.ctx == 33_888 && opencode?.out == 815, "实际 \(String(describing: opencode))")
        precondition(opencode?.turns == 2 && opencode?.sessions == 1, "同一 session 的两条消息只算一个会话")
        precondition(opencode?.models["deepseek-v4-pro"]?.ctx == 25_979)
        precondition(collector.snapshot().error.isEmpty)
        try? FileManager.default.removeItem(atPath: dbPath)
        collector.scanNowForTesting()
        opencode = collector.snapshot().totals["OpenCode"]
        precondition(opencode?.turns == 2, "库被删也要保留已缓存历史")
        try? Data("这不是一个数据库".utf8).write(to: URL(fileURLWithPath: dbPath))
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals["OpenCode"]?.turns == 2, "库读坏也要保留上次汇总")
    }

    PricingCatalog.normalizationSelfTest()
    OverviewMetricPresentation.selfTest()
    AccountQuotaRingPresentation.selfTest()
    SystemNetworkCounters.selfTest()
    CodexProcessMonitor.selfTest()
    AccountPresenceCollector.selfTest()
    AccountPresentation.selfTest()
    MoneyDisplay.selfTest()
    AccountUsage.selfTest()
    UsageHistory.accountingSelfTest()
    RemoteCollector.accountCollectorSelfTest()
    UsageHistory.historyCacheSelfTest()
    UsageHistory.performanceSelfTest()
    do {
        let success = PerformanceSample(source: "API", model: "fixture", timestamp: 0, context: 100, output: 100, cacheRead: 0,
                                        timing: PerformanceTiming(ttftMS: 500, status: 200))
        var failed = success
        failed.timing = PerformanceTiming(ttftMS: 10, status: 429)
        var cli = success
        cli.source = "Codex"
        cli.timing = PerformanceTiming(ttftMS: 1)
        precondition(PerformanceStats.ttft([success, failed, cli]) == 500, "TTFT excludes error responses and CLI records")
        precondition(PerformanceStats.ttft([failed, cli]) == nil, "missing successful proxy timing stays unavailable")
    }

    // 临时目录覆盖真实增量路径：重启、跨文件去重、追加半行、重写、模型成本重算。
    do {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibedeck-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ relative: String, _ text: String, append: Bool = false) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
            } else { try Data(text.utf8).write(to: url) }
        }
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        func claude(_ id: String, _ ts: String, _ input: Int, _ output: Int, read: Int = 0, cacheWrite: Int = 0) throws -> String {
            try line(["type": "assistant", "timestamp": ts, "requestId": id, "message": ["model": "fixture-priced", "usage": ["input_tokens": input, "cache_read_input_tokens": read, "cache_creation_input_tokens": cacheWrite, "output_tokens": output]]])
        }
        func codex(_ ts: String, total: [String: Int], last: [String: Int]? = nil) throws -> String {
            var info: [String: Any] = ["total_token_usage": total]
            if let last { info["last_token_usage"] = last }
            return try line(["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": info]])
        }
        let before = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -600))
        let after = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -598))
        let ca = ".claude/projects/fixture/a.jsonl", cb = ".claude/projects/fixture/b.jsonl"
        let codexA = ".codex/sessions/2026/09/18/a.jsonl", codexB = ".codex/sessions/2026/09/18/b.jsonl"
        let request = try claude("fixture-1", before, 10, 6, read: 20, cacheWrite: 5)
        try write(ca, try claude("fixture-1", before, 10, 3, read: 20, cacheWrite: 5) + request + claude("fixture-2", after, 10, 4))
        try write(cb, request)
        let u1 = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10]
        let u2 = ["input_tokens": 200, "cached_input_tokens": 80, "output_tokens": 20]
        let u3 = ["input_tokens": 240, "cached_input_tokens": 96, "output_tokens": 24]
        try write(codexA, try line(["type": "turn_context", "payload": ["model": "fixture-priced"]])
                  + codex(before, total: u1, last: u1) + codex(after, total: u2, last: u1)
                  + codex(after, total: u2, last: u1) + codex(after, total: u3)
                  + line(["type": "event_msg", "timestamp": after, "payload": ["type": "token_count", "info": NSNull()]]))
        try write(codexB, try codex(before, total: ["input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 5])
                  + codex(after, total: ["input_tokens": 80, "cached_input_tokens": 16, "output_tokens": 8]))
        try write(".config/vibedeck/api-calls.jsonl", try line(["ts": after, "host": "example.test", "provider": "Fixture A", "model": "fixture-priced", "ctx": 30, "cache_read": 5, "out": 3])
                  + line(["ts": after, "host": "example.test", "provider": "Fixture B", "model": "fixture-unpriced", "ctx": 50, "cache_write": 10, "out": 4]))
        let collector = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("no-opencode.db").path)
        collector.scanNowForTesting()
        var snap = collector.snapshot()
        precondition(snap.totals["Claude"]?.ctx == 45 && snap.totals["Claude"]?.out == 10 && snap.totals["Claude"]?.turns == 2 && snap.totals["Claude"]?.sessions == 2)
        precondition(snap.totals["Codex"]?.ctx == 320 && snap.totals["Codex"]?.out == 32 && snap.totals["Codex"]?.turns == 5 && snap.totals["Codex"]?.sessions == 2)
        precondition(snap.totals["API · Fixture A"]?.ctx == 30 && snap.totals["API · Fixture B"]?.ctx == 50)
        precondition(snap.costByCurrency.isEmpty && !snap.hasPriceTable && snap.error.isEmpty)
        let cacheURL = root.appendingPathComponent(".config/vibedeck/usage-daily.json")
        func checkCachePermissions() throws {
            let file = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
            let dir = try FileManager.default.attributesOfItem(atPath: cacheURL.deletingLastPathComponent().path)
            precondition(file[.posixPermissions] as? Int == 0o600 && dir[.posixPermissions] as? Int == 0o700)
        }
        try checkCachePermissions()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cacheURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.deletingLastPathComponent().path)
        // 保存有节流，重启实例并追加空行才能触发真实写入，同时保持统计结果不变。
        try write(ca, "\n", append: true)
        UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("no-opencode.db").path).scanNowForTesting()
        try checkCachePermissions()
        let diskData = try Data(contentsOf: cacheURL)
        let envelope = try PropertyListSerialization.propertyList(from: diskData, options: [], format: nil) as! [String: Any]
        let payload = try ((envelope["archive"] as! Data) as NSData).decompressed(using: .lzfse) as Data
        let disk = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as! [String: Any]
        let states = disk["files"] as! [String: [String: Any]]
        let codexSize = try Data(contentsOf: root.appendingPathComponent(codexA)).count
        let codexStates = states.filter { $0.key.hasSuffix("/" + codexA) }
        precondition(codexStates.count == 1 && (codexStates.first?.value["offset"] as? NSNumber)?.intValue == codexSize)
        // 人工测试价目表只作用于临时目录中的 fixture 模型，不提供任何生产默认价格。
        try write(".config/vibedeck/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 1, "cache_read": 2, "cache_write": 3, "out": 4]]))
        collector.scanNowForTesting(); snap = collector.snapshot()
        precondition(abs((snap.costByCurrency["TEST"] ?? -1) - 0.000594) < 1e-10 && snap.unpricedModels == 2)
        try write(".config/vibedeck/prices.json", try line(["_currency": "TEST", "fixture-priced": ["in": 2, "cache_read": 4, "cache_write": 6, "out": 8]]))
        collector.scanNowForTesting()
        precondition(abs((collector.snapshot().costByCurrency["TEST"] ?? -1) - 0.001188) < 1e-10)
        let added = try claude("fixture-3", after, 7, 1)
        let split = added.index(added.startIndex, offsetBy: added.count / 2)
        try write(ca, String(added[..<split]), append: true)
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals["Claude"]?.turns == 2, "半行不能提前计入")
        try write(ca, String(added[split...]), append: true)
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals["Claude"]?.turns == 3)
        try write(cb, try claude("fixture-4", after, 10, 2))
        try write(ca, try claude("fixture-5", after, 3, 1))
        collector.scanNowForTesting(); snap = collector.snapshot()
        precondition(snap.totals["Claude"]?.turns == 2 && snap.totals["Claude"]?.ctx == 13, "重写必须撤销旧文件贡献")
        let restarted = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("no-opencode.db").path)
        restarted.scanNowForTesting()
        precondition(restarted.snapshot().totals == snap.totals && restarted.snapshot().error.isEmpty)
    } catch { preconditionFailure("统计临时日志自测失败：\(error)") }

    // 内置价：归一化、最长前缀（gpt-5 不许抢 gpt-5.6-x）、别名、1h 缓存、长上下文整单升档、priority 明码价、用户价优先
    do {
        let cat = PricingCatalog.parse([
            "_asof": "2026-09-28", "_aliases": ["gpt-reserve": "gpt-5.6-luna"],
            "claude-opus-5": ["in": 5, "out": 25, "cr": 0.5, "cw": 6.25, "cw1h": 10],
            "gpt-6-astra": ["in": 10, "out": 50, "cr": 1, "cw": 12.5, "lc": ["threshold": 272000, "in": 20, "out": 75, "cr": 2, "cw": 25],
                            "pri": ["in": 20, "out": 100, "cr": 2], "fast": 2],
            "gpt-5": ["in": 1.25, "out": 10, "cr": 0.125],
            "gpt-5.6-luna": ["in": 0.2, "out": 1.2, "cr": 0.02],
        ])
        precondition(cat.asOf == "2026-09-28" && cat.entries.count == 4)
        precondition(PricingCatalog.normalize("anthropic/claude-opus-4.5-20251101[1m]") == "claude-opus-4-5", PricingCatalog.normalize("anthropic/claude-opus-4.5-20251101[1m]"))
        precondition(PricingCatalog.entry(for: "claude-opus-5-20260101", in: cat) != nil)
        precondition(PricingCatalog.entry(for: "gpt-5.6-sol", in: cat) == nil, "gpt-5 不许抢走 gpt-5.6-x")
        precondition(PricingCatalog.entry(for: "gpt-5-mini", in: cat) == nil, "独立模型不能借用同族价格")
        precondition(PricingCatalog.entry(for: "gpt-5-high", in: cat) == cat.entries["gpt-5"], "日志的推理档位后缀允许匹配")
        precondition(PricingCatalog.entry(for: "gpt-reserve", in: cat) == cat.entries["gpt-5.6-luna"])
        let opus = PricingCatalog.entry(for: "claude-opus-5", in: cat)!
        let c1 = PricingCatalog.cost(opus, ctx: 4_000_000, cacheRead: 2_000_000, cacheWrite: 1_000_000, cacheWrite1h: 400_000, out: 100_000)
        precondition(abs(c1 - 16.25) < 1e-9, "opus 1h 缓存算出 \(c1)")
        let astra = cat.entries["gpt-6-astra"]!
        precondition(abs(PricingCatalog.cost(astra, ctx: 100_000, cacheRead: 50_000, cacheWrite: 0, out: 10_000) - 1.05) < 1e-9)
        precondition(abs(PricingCatalog.cost(astra, ctx: 300_000, cacheRead: 100_000, cacheWrite: 0, out: 10_000) - 4.95) < 1e-9, "超过 272k 整单按长上下文价")
        precondition(abs(PricingCatalog.cost(astra, ctx: 100_000, cacheRead: 50_000, cacheWrite: 0, out: 10_000, tier: "priority") - 2.1) < 1e-9)
        let engine = CostEngine(user: ProcessScanner.PriceTable(json: ["_currency": "CNY", "gpt-6-astra": ["in": 1, "out": 1]]), catalog: cat)
        precondition(engine.cost(model: "gpt-6-astra", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0)?.currency == "CNY", "用户价优先")
        precondition(engine.cost(model: "claude-opus-5", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0)?.currency == "USD")
        precondition(engine.isPriced("chatgpt-web/pro") && engine.cost(model: "chatgpt-web/pro", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 1_000)?.value == 0, "网页订阅记 0 成本")
        let builtinEngine = CostEngine(catalog: PricingCatalog.builtin)
        let g3 = builtinEngine.cost(model: "gemini-3-pro-high", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0)?.value ?? 0
        precondition(abs(g3 - 4.0) < 1e-9, "gemini-3-pro 超 200k 走长上下文价 $4/M")
        precondition(abs((builtinEngine.cost(model: "gemini-3-pro-preview", ctx: 100_000, cacheRead: 0, cacheWrite: 0, out: 100_000)?.value ?? 0) - 1.4) < 1e-9)
        precondition(engine.cost(model: "unknown-x", ctx: 1, cacheRead: 0, cacheWrite: 0, out: 1) == nil, "没价的模型不许估")
        precondition(!PricingCatalog.builtin.isEmpty, "内置价没打进 bundle（build.sh 要拷 prices.builtin.json）")
        precondition(PricingCatalog.entry(for: "gpt-6-sol") != nil && PricingCatalog.entry(for: "claude-opus-4-8") != nil)
        let sol61 = PricingCatalog.builtin.entries["gpt-6.1-sol"]!
        precondition(sol61.base.cacheRead == 0.1 && sol61.base.cacheWrite == 2.5)
        precondition(abs(PricingCatalog.cost(sol61, ctx: 272001, cacheRead: 100000, cacheWrite: 50000, out: 10000, tier: "fast") - 1.816008) < 1e-9)
        precondition(PricingCatalog.entry(for: "gpt-5.3-codex-spark") == nil)
        let opus55 = PricingCatalog.builtin.entries["claude-opus-5-5"]!
        let opusStandard = PricingCatalog.cost(opus55, ctx: 1_000_000, cacheRead: 300_000, cacheWrite: 200_000, cacheWrite1h: 100_000, out: 100_000)
        precondition(abs(PricingCatalog.cost(opus55, ctx: 1_000_000, cacheRead: 300_000, cacheWrite: 200_000, cacheWrite1h: 100_000, out: 100_000, tier: "fast") - opusStandard * 2) < 1e-9)
    }

    // 金额预测：作息曲线 + 余量法，本月 = 已花 + 今天预测 + 剩余天数 × 日均；历史不足时按近 1 小时速度
    do {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: Fmt.parseISODate("2026-09-18T04:00:00Z")!)   // 本地 12:00
        let today = cal.startOfDay(for: now)
        func key(_ back: Int) -> String { UsageHistory.dayKey(timestamp: cal.date(byAdding: .day, value: -back, to: today)!.timeIntervalSince1970, timeZone: cal.timeZone) }
        var hourly: [String: [Double]] = [:]
        for back in 1...10 { hourly[key(back)] = (0..<24).map { (9...20).contains($0) ? 1.0 : 0 } }
        hourly[key(0)] = (0..<24).map { (9...11).contains($0) ? 1.0 : 0 }
        let f = UsageForecast.compute(hourly: hourly, lastHourCost: 1, currency: "USD", now: now, calendar: cal)
        precondition(abs(f.todaySoFar - 3) < 1e-9 && abs(f.todayProjected - 12) < 1e-6, "今天预测 \(f.todayProjected)")
        precondition(abs(f.todayLow - 12) < 1e-6 && abs(f.todayHigh - 12) < 1e-6)
        precondition(abs(f.monthProjected - 276) < 1e-6, "本月预测 \(f.monthProjected)")
        precondition(f.recentCosts.count == 14 && f.recentCosts.last == 3 && f.profileDays == 10)
        let thin = UsageForecast.compute(hourly: [key(0): hourly[key(0)]!], lastHourCost: 2, currency: "USD", now: now, calendar: cal)
        precondition(abs(thin.todayProjected - 5) < 1e-9 && thin.basis.contains("不足"))
        precondition(thin.monthConfidence == .insufficient && thin.historyDays == 0)
        let early = ISO8601DateFormatter().date(from: "2026-09-30T16:05:00Z")!
        var prior = Array(repeating: 0.0, count: 24); prior[23] = 254.89333333333335
        var current = Array(repeating: 0.0, count: 24); current[0] = 3.41
        let sparse = UsageForecast.compute(hourly: ["2026-09-30": prior, "2026-10-01": current], lastHourCost: 32.22, currency: "USD", now: early, calendar: cal)
        precondition(sparse.historyDays == 1 && sparse.monthConfidence == .insufficient)
        precondition(abs(sparse.todayProjected - 35.63) < 1e-9 && abs(sparse.monthProjected - 35.63) < 1e-9, "稀疏月初历史不外推整月")
        precondition(sparse.monthLow >= sparse.monthSoFar && sparse.monthHigh >= sparse.monthProjected)
        let t = now.timeIntervalSince1970
        let block = UsageForecast.currentBlock([.init(timestamp: t - 3 * 3600, cost: 1), .init(timestamp: t - 2 * 3600, cost: 1),
                                                .init(timestamp: t - 3600, cost: 1)], currency: "USD", now: t)!
        precondition(block.isActive && block.requests == 3 && abs(block.perHour - 1) < 1e-9 && abs(block.projected - 5) < 1e-9, "块 \(block)")
    }

    // 峰谷价：按配置时区、星期与例外日期，周末/国庆不能只按钟点计峰价。
    do {
        let table = ProcessScanner.PriceTable(json: [
            "_currency": "CNY", "_peak": ["tz": "Asia/Shanghai", "windows": ["09:00-12:00", "14:00-18:00"],
                                             "weekdays": [2, 3, 4, 5, 6], "excluded_dates": ["2026-10-01"]],
            "deepseek-flash": ["in": 2, "out": 8, "cache_read": 0.04, "offpeak": ["in": 1, "out": 4, "cache_read": 0.02]]
        ])
        func cost(_ iso: String) -> Double {
            table.cost(model: "deepseek-flash", ctx: 1_000_000, cacheRead: 500_000, cacheWrite: 0, out: 100_000,
                       at: ISO8601DateFormatter().date(from: iso))!
        }
        precondition(abs(cost("2026-09-30T02:00:00Z") - 1.82) < 1e-9, "工作日峰时")
        precondition(abs(cost("2026-10-01T02:00:00Z") - 0.91) < 1e-9, "节假日为空闲价")
        precondition(abs(cost("2026-10-04T02:00:00Z") - 0.91) < 1e-9, "周末为空闲价")
        precondition(abs(cost("2026-10-08T02:00:00Z") - 1.82) < 1e-9, "例外日之后恢复工作日峰价")
    }

    // 降智：模型比较（移植 is-gpt-nerfed）+ 真实路径扫描临时日志
    do {
        precondition(NerfDetector.compare("gpt-6-astra", "gpt-5.6-sol").direction == "downgrade")
        precondition(NerfDetector.compare("gpt-5.6-sol", "gpt-6-sol").direction == "upgrade")
        precondition(NerfDetector.compare("claude-opus-4-8", "claude-sonnet-5").direction == "downgrade", "Claude 先比档位")
        precondition(NerfDetector.compare("gpt-6-sol", "gpt-reserve", hidden: ["gpt-reserve"]).direction == "downgrade")
        precondition(NerfDetector.compare("gpt-5.4", "gpt-5.4-mini").direction == "downgrade")
        let v = NerfDetector.modelVersion("claude-sonnet-4-5-20250929")
        precondition(v?.0 == 4 && v?.1 == 5)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibedeck-nerf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter()
        let ts = iso.string(from: Date(timeIntervalSinceNow: -600))
        func lines(_ rows: [[String: Any]]) -> Data {
            Data((rows.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n").utf8)
        }
        let codexURL = root.appendingPathComponent(".codex/sessions/2026/09/28/rollout-fixture.jsonl")
        try? FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines([
            ["type": "session_meta", "timestamp": ts, "payload": ["cwd": "/tmp/fixture-proj"]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-6-astra", "collaboration_mode": ["settings": ["reasoning_effort": "xhigh"]]]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": ["model_context_window": 490200]]],
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-5.6-sol", "collaboration_mode": ["settings": ["reasoning_effort": "medium"]]]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": ["model_context_window": 258400]]],
        ]).write(to: codexURL)
        let claudeURL = root.appendingPathComponent(".claude/projects/p/s.jsonl")
        try? FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines([
            ["type": "assistant", "timestamp": ts, "message": ["model": "claude-opus-5"]],
            ["type": "assistant", "timestamp": ts, "message": ["model": "claude-sonnet-5"]],
            ["type": "user", "timestamp": ts, "message": ["content": "<command-name>/model</command-name>"]],
            ["type": "assistant", "timestamp": ts, "message": ["model": "claude-opus-5"]],
            ["type": "assistant", "timestamp": ts, "isSidechain": true, "message": ["model": "claude-haiku-4-5"]],
        ]).write(to: claudeURL)
        let r = NerfDetector(home: root.path).refreshNow()
        let kinds = Set(r.findings.map { $0.id.components(separatedBy: "|").dropFirst().first ?? "" })
        precondition(r.status == .alert, "应判为疑似降智：\(r.findings.map { $0.title })")
        precondition(kinds.isSuperset(of: ["silent_model_change", "silent_effort_change", "context_window_change", "claude_model"]), "\(kinds)")
        precondition(r.findings.filter { $0.source == "Claude" && $0.severity == .hard }.count == 1, "/model 之后的切换只算提示，子代理不算")
        precondition(r.currentModels["Codex"] == "gpt-5.6-sol · medium")
    }

    // 远程逐条记录：解析、来源带设备名、id 加种类前缀、压缩往返；设备作用域 & 挂载配置
    do {
        let jsonl = """
        {"k":"claude","id":"r1","t":1790000000,"m":"claude-opus-5","in":35,"cr":20,"cw":5,"c1":5,"out":100,"th":0,"s":"s1","seconds":2.5}
        {"k":"codex","id":"resp_1","t":1790000001,"m":"gpt-6-sol","in":100,"cr":40,"cw":0,"out":10,"th":2,"s":"rollout-a.jsonl","tier":"priority"}
        坏行
        {"__ok__":true,"count":2,"max_mtime":1790000000123}
        """
        let parsed = RemoteCollector.parseCLIRecords(jsonl: jsonl, host: "wsl")
        precondition(parsed.ok && parsed.records.count == 2 && parsed.maxMtime == 1_790_000_000_123)
        precondition(parsed.records.contains { $0.source == "Claude · wsl" && $0.cw1h == 5 && $0.id == "claude:r1" })
        precondition(parsed.records.contains { $0.source == "Codex · wsl" && $0.tier == "priority" && $0.session == "rollout-a.jsonl" })
        precondition(parsed.records.first { $0.id == "claude:r1" }?.timing?.speed(output: 100, proxy: false) == 40)
        precondition(parsed.records.first { $0.id == "codex:resp_1" }?.timing == nil)
        let invalid = RemoteCollector.parseCLIRecords(jsonl: jsonl.replacingOccurrences(of: "\"seconds\":2.5", with: "\"seconds\":true"), host: "wsl")
        precondition(invalid.records.first { $0.id == "claude:r1" }?.timing == nil)
        let blob = try (Data(jsonl.utf8) as NSData).compressed(using: .zlib) as Data
        precondition(RemoteCollector.inflate(blob.base64EncodedString()) == jsonl, "压缩往返")
        precondition(RemoteCollector.inflate("{\"a\":1}") == "{\"a\":1}")
        precondition(DeviceScope.includes(source: "Claude · wsl", scope: .remote("wsl"), hosts: ["wsl"]))
        precondition(!DeviceScope.includes(source: "Codex · wsl", scope: .local, hosts: ["wsl"]))
        precondition(DeviceScope.includes(source: "API · GLM", scope: .local, hosts: ["wsl"]))
        precondition(UsageHistory.device(of: "OpenCode · gpu") == "gpu" && UsageHistory.device(of: "API · GLM") == nil && UsageHistory.cli(of: "Codex · wsl") == "Codex")
        let mounts = UsageHistory.parseMountRoots("wsl=/Volumes/w/home/me; /Volumes/lab ;bad label=/x")
        precondition(mounts.map { $0.label } == ["wsl", "lab"] && mounts.first?.path == "/Volumes/w/home/me", "\(mounts)")
    } catch { preconditionFailure("远程记录自测失败：\(error)") }

    // 新口径：token_usage_record（response_id 去重）+ priority 档 + 归档副本只算一次 + Claude 1h 缓存 + 内置价
    do {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibedeck-cost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ relative: String, _ rows: [[String: Any]]) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: url)
        }
        let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -300))
        func u(_ i: Int, _ c: Int, _ o: Int) -> [String: Any] { ["input_tokens": i, "cached_input_tokens": c, "cache_write_input_tokens": 0, "output_tokens": o, "reasoning_output_tokens": 0] }
        let rollout: [[String: Any]] = [
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-6-astra"]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]]],
            ["type": "token_usage_record", "timestamp": ts, "payload": ["response_id": "resp_1", "usage": u(100, 40, 10)]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": ["total_token_usage": u(100, 40, 10), "last_token_usage": u(100, 40, 10)]]],
            ["type": "token_usage_record", "timestamp": ts, "payload": ["response_id": "resp_2", "usage": u(50, 10, 5)]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": ["total_token_usage": u(150, 50, 15), "last_token_usage": u(50, 10, 5)]]],
        ]
        try put(".codex/sessions/2026/09/18/rollout-x.jsonl", rollout)
        try put(".codex/archived_sessions/rollout-x.jsonl", rollout)
        try put(".claude/projects/p/a.jsonl", [["type": "assistant", "timestamp": ts, "requestId": "q1",
            "message": ["model": "claude-opus-5", "usage": ["input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5,
                                                         "output_tokens": 9, "cache_creation": ["ephemeral_1h_input_tokens": 5]]]]])
        let cat = PricingCatalog.parse(["_asof": "fixture",
            "claude-opus-5": ["in": 5, "out": 25, "cr": 0.5, "cw": 6.25, "cw1h": 10],
            "gpt-6-astra": ["in": 10, "out": 50, "cr": 1, "pri": ["in": 20, "out": 100, "cr": 2]]])
        let collector = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("none.db").path, catalog: cat)
        collector.scanNowForTesting()
        let snap = collector.snapshot()
        precondition(snap.totals["Codex"]?.turns == 2 && snap.totals["Codex"]?.ctx == 150, "Codex \(String(describing: snap.totals["Codex"]))")
        precondition(snap.totals["Claude"]?.turns == 1)
        precondition(abs((snap.costBySource["Codex"]?["USD"] ?? -1) - 0.0036) < 1e-12, "priority 价 \(snap.costBySource)")
        precondition(abs((snap.costBySource["Claude"]?["USD"] ?? -1) - 0.000335) < 1e-12, "1h 缓存价 \(snap.costBySource)")
        precondition(!snap.hasPriceTable && snap.builtinPriceAsOf == "fixture" && snap.primaryCurrency == "USD")
        precondition(abs((snap.forecastsByDevice["local"]?["USD"]?.recentCosts.reduce(0, +) ?? -1) - 0.003935) < 1e-12)
        precondition(snap.forecastsByDevice["remote:wsl"] == nil, "本机预测不会伪造远程设备数据")
    } catch { preconditionFailure("新口径自测失败：\(error)") }

    // 历史记录 priority → default：修改真实 prices.json 后重算两档，token 与请求数保持不变。
    do {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vibedeck-custom-fast-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ relative: String, _ rows: [[String: Any]]) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: url)
        }
        let ts = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -300))
        func usage(_ i: Int, _ c: Int, _ o: Int) -> [String: Any] {
            ["input_tokens": i, "cached_input_tokens": c, "output_tokens": o]
        }
        try put(".codex/sessions/2026/09/18/custom-fast.jsonl", [
            ["type": "turn_context", "timestamp": ts, "payload": ["model": "gpt-6-astra"]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": "priority"]]],
            ["type": "token_usage_record", "timestamp": ts, "payload": ["response_id": "fast", "usage": usage(100, 40, 10)]],
            ["type": "event_msg", "timestamp": ts, "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]]],
            ["type": "token_usage_record", "timestamp": ts, "payload": ["response_id": "standard", "usage": usage(50, 10, 5)]],
        ])
        let pricesPath = ".config/vibedeck/prices.json"
        var price: [String: Any] = ["in": 1, "cache_read": 0.1, "out": 5]
        try put(pricesPath, [["_currency": "TEST", "gpt-6-astra": price]])
        let collector = UsageHistory(home: root.path, opencodeDB: root.appendingPathComponent("none.db").path)
        collector.scanNowForTesting()
        let before = collector.snapshot()
        precondition(before.totals["Codex"]?.turns == 2 && before.totals["Codex"]?.ctx == 150 && before.totals["Codex"]?.out == 15)
        precondition(abs((before.costBySource["Codex"]?["TEST"] ?? -1) - 0.00018) < 1e-12, "旧覆盖价保持最终价")
        price["fast_multiplier"] = 2
        try put(pricesPath, [["_currency": "TEST", "gpt-6-astra": price]])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(pricesPath))) as! [String: Any]
        precondition(ProcessScanner.PriceTable(json: json).rows["gpt-6-astra"]?.fastMultiplier == 2)
        collector.scanNowForTesting()
        let after = collector.snapshot()
        precondition(after.totals == before.totals, "价格重算不能改变 token 或请求数")
        // priority: (60×1 + 40×0.1 + 10×5)×2；default: 40×1 + 10×0.1 + 5×5。
        precondition(abs((after.costBySource["Codex"]?["TEST"] ?? -1) - 0.000294) < 1e-12, "只有 priority 记录加价一次")
        collector.scanNowForTesting()
        precondition(collector.snapshot().totals == after.totals && collector.snapshot().costBySource == after.costBySource, "再次扫描不能重复加价")
    } catch { preconditionFailure("历史自定义 Fast 价自测失败：\(error)") }

    NetworkScanner.shared.start()
    UsageHistory.shared.start()

    let t0 = Date()
    let r = ProcessScanner.shared.scan(refreshRemote: false)
    let t1 = Date()
    precondition(r.capturedAt >= t0.timeIntervalSince1970 && r.capturedAt <= t1.timeIntervalSince1970, "Completed reports need a current publication timestamp")
    print(String(format: "scan 耗时 %.0f ms", t1.timeIntervalSince(t0) * 1000))
    print(String(format: "内存 可用%d%%  已用 %.1f/%.1f GB  swap %.2f GB  压缩 %.2f GB", r.freePercentage, r.usedMemoryGB, r.totalMemoryGB, r.swapUsedGB, r.compressorGB))
    let npxSummary = r.npxCacheKnown ? String(format: "%.0f MB", r.npxCacheMB) : (r.npxCachePending ? "计算中" : "未知")
    print(String(format: "磁盘 剩余 %.1f/%.1f GB  负载 %.2f  NPX %@  MCP %d 进程 %.0f MB", r.diskFreeGB, r.diskTotalGB, r.loadAvg1m, npxSummary, r.activeMCPProcessCount, r.activeMCPTotalMemMB))
    print("孤儿 \(r.totalOrphanCount) 个 \(Int(r.totalOrphanMemMB)) MB: " + r.orphanedGroups.map { "\($0.serviceName)x\($0.processCount)" }.joined(separator: ", "))
    if !r.orphans.isEmpty || !r.protected.isEmpty {
        print("--- 会被清理的（逐条）---")
        for o in r.orphans { print(String(format: "  pid %-7d %5.0f MB  %@", o.pid, o.memMB, String(o.cmd.prefix(90)))) }
        print("--- 规则放过的（原因）---")
        for p in r.protected { print(String(format: "  pid %-7d %5.0f MB  [%@]  %@", p.pid, p.memMB, p.reason, String(p.cmd.prefix(70)))) }
    }
    if r.diskStatsKnown {
        print(String(format: "--- 磁盘：最近统计 AI 工具目录合计 %.2f GB，可清理（%d 天前的会话记录）%.2f GB ---",
                     r.diskTotalAIGB, ProcessScanner.shared.logRetentionDays, r.purgeableMB / 1024))
    } else {
        print(r.diskStatsPending ? "--- 磁盘：后台计算中 ---" : "--- 磁盘：统计暂不可用 ---")
    }
    for d in r.disk {
        print(String(format: "  %@ %-16@ %7.0f MB (%d 文件)%@  %@", d.purgeable ? "🧹" : "🔒", d.label, d.totalMB, d.files,
                     d.purgeable ? String(format: "  其中旧 %.0f MB/%d 个", d.oldMB, d.oldFiles) : "", d.note))
    }
    print("--- 压力信号（图标画第一条）---")
    for s in r.pressures.prefix(8) {
        print(String(format: "  %-16@ %3d%%  线 %d/%d  margin %+d  level %d  %@", s.short, s.pct, s.warn, s.crit, s.margin, s.level, s.detail))
    }
    print("--- 平台 ---")
    func w(_ label: String, _ q: QuotaWindow?) -> String {
        guard let q = q else { return "" }
        let reset = Fmt.countdown(to: q.resetsAt, now: now) ?? "?"
        let age = q.ageSeconds(now: now).map { Fmt.ago($0) } ?? "?"
        let burn = q.burn(now: now).map {
            String(format: ", %.1f%%/h→重置时 %d%%%@", $0.pctPerHour, $0.projectedAtReset,
                   $0.exhaustAt.flatMap { Fmt.countdown(to: $0, now: now) }.map { " ⚡\($0)后打满" } ?? "")
        } ?? ""
        return "  \(label)=\(q.effectivePct(now: now))%(raw \(q.usedPct), 重置 \(reset), 采集 \(age)\(burn))"
    }
    for l in r.detectedLLMs {
        print("\(l.isRunning ? "●" : "○") \(l.name) [\(l.tier)] \(l.detail)" + w("5H", l.fiveHour) + w("W", l.sevenDay) + w("\(l.secondaryPoolName)5H", l.secondaryFiveHour) + w("\(l.secondaryPoolName)W", l.secondarySevenDay) + (l.hasQuota ? "" : "  | \(l.quotaSubtitle)"))
    }
    let rs = ProcessScanner.shared.codexRemoteStatus()
    print(rs.hosts.isEmpty ? "Codex 远程：未配置" : "Codex 远程 \(rs.hosts.joined(separator: ", ")): \(rs.ok ? "已连上" : "未连上") · \(rs.ageSeconds)s 前拉取")
    let a = r.api
    let cov = a.coverage
    print("--- 记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处走代理 ---")
    for e in cov.entries { print("  \(e.proxied ? "✓" : "✗") \(e.name) → \(e.host)  (\(e.file):\(e.line))") }
    print("--- API 代理 --- 安装=\(a.installed) 运行=\(a.running) 端口=\(a.port) 启动后调用=\(a.callsSinceStart)")
    print("  价目表: " + (a.hasPriceTable ? "已配置 \(a.priceAsOf)" : "未配置（~/.config/vibedeck/prices.json）"))
    for p in a.providers {
        print("  \(p.provider) [\(p.host)] 今日 \(p.calls) 次 ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) 模型 \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.monthly.map { "M \($0.usedPct)%" } ?? "") \(p.quotaError)")
        print(String(format: "    延迟 p50 %@ p95 %@ 最慢 %@ · 错误 %d(%.1f%%) 429 %d · 花费 %@ · key %@",
                     Fmt.ms(p.p50ms), Fmt.ms(p.p95ms), Fmt.ms(p.maxms), p.errors, p.errorRate, p.count429,
                     p.cost.isEmpty ? "—" : Fmt.money(p.cost),
                     p.keys.map { "\($0.fingerprint):\($0.calls)" }.joined(separator: " ")))
        if let hw = p.headerWindow { print("    限流头: \(p.headerLabel) 已用 \(hw.usedPct)% 重置 \(Fmt.countdown(to: hw.resetsAt, now: now) ?? "?")") }
        if p.quotaIsEstimate { print("    额度=估算 · \(p.estimateNote) · 上限 \(p.planLimitText)") }
    }
    print("--- Token ---")
    let t = r.tokens
    print(String(format: "今日 %d 次调用  上下文 %lld  缓存读 %lld  命中 %.1f%%  输出 %lld  思考 %lld", t.todayTurns, t.todayContext, t.todayCacheRead, t.todayCacheHitRate, t.todayOutput, t.todayThinking))
    for i in t.recentInteractions {
        print(String(format: "  %@ %@  ctx %d  out %d  think %d  hit %.1f%%  [%@]", Fmt.modelDisplayName(i.model), Fmt.ago(Int(now - i.timestamp)), i.contextTokens, i.outputTokens, i.thinkingTokens, i.cacheHitRate, i.id))
    }
    print("--- 今日按项目归因 ---")
    for p in t.todayByProject.prefix(8) {
        print(String(format: "  %-28@ %5d 轮  ctx %-10lld out %-8lld  [%@]", p.name, p.turns, p.ctx, p.out, p.clis.joined(separator: "+")))
    }
    print("--- 各 CLI 今日用量 ---")
    for u in r.cliUsage {
        if u.hasTokens {
            print(String(format: "  %@: ctx %lld  cache %lld  out %lld  think %lld  %d 次  命中 %.1f%%", u.name, u.ctx, u.cacheRead, u.out, u.think, u.requests, u.cacheHitRate))
        } else {
            print("  \(u.name): \(u.turns) 轮 · \(u.note)")
        }
    }

    let t2 = Date()
    _ = ProcessScanner.shared.scanTokens()
    _ = ProcessScanner.shared.scanActiveLLMs()
    print(String(format: "二次轻量刷新耗时 %.0f ms (ticker 每秒跑的就是这个)", Date().timeIntervalSince(t2) * 1000))
    let historyDeadline = Date().addingTimeInterval(600)
    var progressAt = Date.distantPast
    while UsageHistory.shared.snapshot().capturedAt == 0 || NetworkScanner.shared.snapshot().capturedAt == 0 {
        precondition(Date() < historyDeadline, "后台首次采集超时，不能把未完成汇总标为通过")
        if Date().timeIntervalSince(progressAt) > 15 {
            let progress = UsageHistory.shared.snapshot()
            print("历史汇总进度：\(progress.processedFiles)/\(progress.totalFiles) 文件")
            progressAt = Date()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    func maskedIP(_ ip: String) -> String {
        if ip.contains(":") { return ip.split(separator: ":").prefix(2).joined(separator: ":") + ":x:x" }
        let parts = ip.split(separator: ".")
        return parts.count == 4 ? parts.prefix(2).joined(separator: ".") + ".x.x" : "查不到"
    }
    precondition(maskedIP("192.0.2.7") == "192.0.x.x")
    let network = NetworkScanner.shared.snapshot()
    print("--- 网络 ---")
    for item in network.aiExits where !item.isGemini {
        if item.error.isEmpty {
            print("\(item.name): \(maskedIP(item.ip)) · \(item.loc) · \(item.colo) · \(item.latencyMS)ms")
        } else { print("\(item.name): 查不到 · \(item.error)") }
    }
    let gemini = network.proxy.connections.first { $0.name == "Gemini" }
    print("Gemini: " + (!network.proxy.error.isEmpty ? "查不到出口：代理连接表不可用" : ((gemini?.count ?? 0) > 0 ? "\(gemini!.count) 个活动连接 · 出站链路 \(gemini!.chains.count) 条" : "无活动连接，查不到出口")))
    print("代理内核: " + (network.proxy.error.isEmpty ? "\(network.proxy.version) · \(network.proxy.groups.count) 个分组" : network.proxy.error))
    print("本机: \(network.local.interfaceName.isEmpty ? "查不到接口" : network.local.interfaceName) · 网关 \(maskedIP(network.local.gateway)) · IPv4 \(maskedIP(network.local.ipv4))")
    print("IPv6: \(network.leak.ipv6Message)" + (network.leak.ipv6Country.isEmpty ? "" : " · \(network.leak.ipv6Country)"))
    print("DNS: \(network.leak.dnsVerdict.rawValue)")
    let history = UsageHistory.shared.snapshot()
    print(L("--- 速度 ---", "--- Speed ---"))
    let speedGroups = Dictionary(grouping: history.performance.filter { $0.speed != nil }, by: { $0.source + " · " + $0.model })
    for key in speedGroups.keys.sorted() {
        let samples = speedGroups[key]!
        let hour = samples.filter { $0.timestamp >= now - 3600 }
        let today = samples.filter { UsageHistory.dayKey(timestamp: $0.timestamp) == UsageHistory.dayKey(timestamp: now) }
        let estimate = UsageHistory.isProxySource(samples[0].source) ? "" : L(" · 估算", " · estimated")
        print(String(format: "  %@: p50 %.1f tok/s · p90 %.1f · n=%d%@ · 1h p50 %@ · today p50 %@", key,
                     PerformanceStats.speed(samples) ?? 0, PerformanceStats.speed(samples, percentile: 0.9) ?? 0, samples.count, estimate,
                     PerformanceStats.speed(hour).map { String(format: "%.1f", $0) } ?? "—",
                     PerformanceStats.speed(today).map { String(format: "%.1f", $0) } ?? "—"))
    }
    print("--- 统计 ---")
    print("已处理 \(history.processedFiles)/\(history.totalFiles) 文件 · 自 \(history.earliestDate ?? "查不到最早日期") · \(history.activeDays) 个活跃日")
    print("累计 token \(history.tokenTotal) · 输入 \(history.ctx) · 缓存读 \(history.cacheRead) · 输出 \(history.aggregate.out)")
    print("缓存命中率 " + (history.cacheHitRate.map { String(format: "%.2f%%", $0 * 100) } ?? "查不到：无输入用量"))
    for source in ["Claude", "Codex", "OpenCode"] {
        if let total = history.totals[source] { print("\(source): \(total.tokenTotal) token · \(total.turns) 请求 · \(total.sessions) 会话") }
        else { print("\(source): 未检测到有效用量记录") }
    }
    for source in history.totals.keys.filter({ $0.hasPrefix("OpenCode · ") }).sorted() {
        if let total = history.totals[source] { print("\(source): \(total.tokenTotal) token · \(total.turns) 请求 · \(total.sessions) 会话") }
    }
    print("API 上游 \(history.totals.keys.filter { $0.hasPrefix("API · ") }.count) 个 · 累计差口径 \(history.cumulativeTurns) 次 · 跳过不完整记录 \(history.skippedRecords) 条")
    print("API 等价成本: " + (history.hasAnyPricing ? (history.costByCurrency.isEmpty ? "未定价" : Fmt.money(history.costByCurrency)) + (history.unpricedModels > 0 ? " · 未定价：\(history.unpricedNames.prefix(6).joined(separator: ", "))" : "") : "未配置价目表"))
    if let f = history.forecast {
        print(String(format: "预测(%@): 今天 %.2f → 预计 %.2f [%.2f, %.2f] · 近1h %.2f · 本月 %.2f → 预计 %.2f · %@", f.currency, f.todaySoFar, f.todayProjected, f.todayLow, f.todayHigh, f.lastHourCost, f.monthSoFar, f.monthProjected, f.basis))
    }
    for (source, t) in history.todayBySource.sorted(by: { $0.key < $1.key }) {
        print("  今日 \(source): \(t.turns) 次 · \(Fmt.tokens(t.tokenTotal)) token · " + Fmt.money(history.todayCostBySource[source] ?? [:]))
    }
    if let b = history.claudeBlock { print(String(format: "Claude 5h 块: %.2f · %.2f/h · 预计 %.2f · active=%d", b.cost, b.perHour, b.projected, b.isActive ? 1 : 0)) }
    let health = NerfDetector.shared.refreshNow(history: history)
    print("降智检测: \(health.status) · \(health.headline) · 会话 \(health.sessionsScanned) 轮 \(health.turnsScanned) · 当前 \(health.currentModels)")
    for f in health.findings.prefix(8) { print("  [\(f.severity)] \(f.source) \(f.title) · \(f.detail) · \(f.session)") }
    if !history.error.isEmpty { print("汇总说明：\(history.error)") }
    print("新增纯函数、Tab 迁移和增量缓存自测通过")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
