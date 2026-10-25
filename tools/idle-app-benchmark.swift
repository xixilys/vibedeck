// Tool-only closed-menu full-app driver. Production main is excluded.
import Cocoa
import Darwin

private func emit(_ tag: String, _ fields: [String: Any]) {
    var row = fields
    row["uptime"] = ProcessInfo.processInfo.systemUptime
    row["pid"] = ProcessInfo.processInfo.processIdentifier
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print("\(tag) \(String(decoding: data, as: UTF8.self))"); fflush(stdout)
}
enum BenchmarkAudit {
    static func note(_ name: String, _ fields: [String: Any] = [:]) { }
}
enum BenchmarkMetrics {
    static let lock = NSLock()
    static var starts = 0
    static var commands: [String: Int] = [:]
    static func run(_ process: Process) throws {
        try process.run()
        lock.lock(); starts += 1
        // No arguments, host names or command text are recorded.
        let name = process.executableURL?.lastPathComponent ?? "unknown"
        commands[name, default: 0] += 1; lock.unlock()
    }
    static func counters() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return commands }
    final class ScanTiming {
        var last = ProcessInfo.processInfo.systemUptime
        var stage = "setup"
        var durations: [String: Double] = [:]
        func mark(_ next: String) {
            let now = ProcessInfo.processInfo.systemUptime
            durations[stage, default: 0] += (now-last)*1000; last=now; stage=next
        }
        func finish() { mark("done"); emit("VG_SCAN_TIMING", durations) }
    }
    static func report(_ r: ScanReport) {
        emit("VG_REPORT", ["captured_at":r.capturedAt, "free_pct":r.freePercentage,
            "total_gb":r.totalMemoryGB,"used_gb":r.usedMemoryGB,"compressor_gb":r.compressorGB,
            "swap_gb":r.swapUsedGB,"disk_free_gb":r.diskFreeGB,"disk_total_gb":r.diskTotalGB,
            "orphan_count":r.totalOrphanCount,"active_mcp":r.activeMCPProcessCount,
            "today_turns":r.tokens.todayTurns,"today_context":r.tokens.todayContext,"today_output":r.tokens.todayOutput,
            "cli":r.cliUsage.map { ["name":$0.name,"requests":$0.requests,"ctx":$0.ctx,"out":$0.out,"think":$0.think,"cache":$0.cacheRead,"turns":$0.turns] as [String:Any] },
            "quota":r.detectedLLMs.map { ["name":$0.name,"sessions":$0.platformDetail.sessions.count,"five":$0.fiveHour?.usedPct as Any? ?? NSNull(),"week":$0.sevenDay?.usedPct as Any? ?? NSNull()] as [String:Any] },
            "api_providers":r.api.providers.count])
    }
}
private func cpu(_ who: Int32) -> Double {
    var u = rusage(); precondition(getrusage(who, &u)==0)
    return Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1_000_000
}
@main private struct IdleAppBenchmark {
    static func main() {
        signal(SIGPIPE,SIG_IGN)
        UserDefaults.standard.setVolatileDomain(["autoCleanEnabled":false,"thresholdNotifyEnabled":false,
            "exitChangeNotifyEnabled":false,"updateCheckEnabled":false,"AppleLanguages":["zh-Hans"]], forName:UserDefaults.argumentDomain)
        if ProcessInfo.processInfo.environment["VG_COMPARE_ONLY"] == "1" {
            _ = ProcessScanner.shared.scan(refreshRemote: false)
            return
        }
        let app=NSApplication.shared
        let owner=AppDelegate(); app.delegate=owner
        let duration=Double(ProcessInfo.processInfo.environment["VG_IDLE_SECONDS"] ?? "120")!
        let settle=Double(ProcessInfo.processInfo.environment["VG_SETTLE_SECONDS"] ?? "20")!
        var timers:[Timer]=[]
        var start=0.0, own=0.0, child=0.0
        var initial:[String:Int]=[:], samples:[[String:Any]]=[]
        var last=0.0, lastOwn=0.0, lastChild=0.0
        let observer=NotificationCenter.default.addObserver(forName:NSApplication.didFinishLaunchingNotification, object:app, queue:nil) { _ in
            let begin=Timer(timeInterval:settle,repeats:false) { _ in
                start=ProcessInfo.processInfo.systemUptime; own=cpu(RUSAGE_SELF); child=cpu(RUSAGE_CHILDREN)
                last=start; lastOwn=own; lastChild=child; initial=BenchmarkMetrics.counters()
                emit("VG_START",["seconds":duration,"settle":settle,"visible":owner.benchmarkMenuVisible])
                let sample=Timer(timeInterval:1,repeats:true) { _ in
                    let now=ProcessInfo.processInfo.systemUptime, a=cpu(RUSAGE_SELF), b=cpu(RUSAGE_CHILDREN)
                    samples.append(["elapsed":now-last,"self_cpu":a-lastOwn,"children_cpu":b-lastChild,"visible":owner.benchmarkMenuVisible])
                    last=now; lastOwn=a; lastChild=b
                }
                timers.append(sample);RunLoop.main.add(sample,forMode:.common)
                let end=Timer(timeInterval:duration,repeats:false) { _ in
                    sample.invalidate()
                    let elapsed=ProcessInfo.processInfo.systemUptime-start
                    let a=cpu(RUSAGE_SELF)-own,b=cpu(RUSAGE_CHILDREN)-child
                    let counts=BenchmarkMetrics.counters().mapValues { $0 }
                    var delta:[String:Int]=[:];for (k,v) in counts { delta[k]=v-(initial[k] ?? 0) }
                    emit("VG_END",["elapsed":elapsed,"self_cpu":a,"children_cpu":b,"self_pct":a/elapsed*100,"children_pct":b/elapsed*100,
                        "sum_pct":(a+b)/elapsed*100,"starts":delta,"starts_per_min":Double(delta.values.reduce(0,+))/elapsed*60,
                        "valid": !owner.benchmarkMenuVisible && samples.allSatisfy { $0["visible"] as? Bool == false },"samples":samples])
                    app.terminate(nil)
                }
                timers.append(end);RunLoop.main.add(end,forMode:.common)
            }
            timers.append(begin);RunLoop.main.add(begin,forMode:.common)
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+settle+duration+30) { _exit(2) }
        withExtendedLifetime((owner,observer,timers)) { app.run() }
    }
}

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
