// Standalone UsageHistory harness. No AppDelegate, proxy, notifications or price sync is started.
import Cocoa
import Darwin

enum HistoryProbe {
    static let env = ProcessInfo.processInfo.environment
    static let root = env["VG_HISTORY_FIXTURE"]!
    static let metadata = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/fixture.json"))) as! [String: Any]
    static let logHome = metadata["source_home"] as! String
    static var hourly: [String: [String: [Double]]] = [:]
    static var deviceHourly: [String: [String: [String: [Double]]]] = [:]
    static var queueCPU = 0.0
    static var scans = 0
    static var loadSeconds = 0.0
    static let mutex = NSLock()
    static var peak: UInt64 = 0
    static func physical(_ path: String) -> String {
        if path.hasPrefix(logHome + "/") { return root + "/logs" + path.dropFirst(logHome.count) }
        return path
    }
    static func logical(_ path: String) -> String {
        let prefix = root + "/logs"
        if path.hasPrefix(prefix + "/") { return logHome + path.dropFirst(prefix.count) }
        return path
    }
    static func cpu() -> Double {
        var u = rusage(); precondition(getrusage(RUSAGE_SELF, &u) == 0)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func sample() { let x = footprint(); mutex.lock(); peak = max(peak, x); mutex.unlock() }
    static func noteScan(_ start: Double) { queueCPU += cpu() - start; scans += 1 }
    static func object(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Int64: return v
        case let v as Double: return v
        default: break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional: return mirror.children.first.map { object($0.value) } ?? NSNull()
        case .collection, .set: return mirror.children.map { object($0.value) }
        case .dictionary:
            var d: [String: Any] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                d[String(describing: pair[0].value)] = object(pair[1].value)
            }
            return d
        case .struct, .class:
            return Dictionary(uniqueKeysWithValues: mirror.children.compactMap { c in c.label.map { ($0, object(c.value)) } })
        default: return String(describing: value)
        }
    }
    static func write(_ value: Any, to path: String) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

@main struct HistoryCompare {
    static func main() {
        let env = HistoryProbe.env
        let out = env["VG_HISTORY_OUTPUT"]!
        let seconds = Double(env["VG_HISTORY_SECONDS"] ?? "0")!
        var defaults = ["remoteHosts": HistoryProbe.metadata["remote_hosts"] ?? "", "codexRemoteHost": "", "mountRoots": ""] as [String: Any]
        defaults["AppleLanguages"] = ["en"]
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "history-footprint"))
        monitor.schedule(deadline: .now(), repeating: .milliseconds(20)); monitor.setEventHandler { HistoryProbe.sample() }; monitor.resume()
        let start = ProcessInfo.processInfo.systemUptime
        let firstCPU = HistoryProbe.cpu()
        let collector = UsageHistory(home: HistoryProbe.root + "/logs", cachePath: out + "/usage-daily.json",
                                     opencodeDB: HistoryProbe.metadata["opencode_db"] as? String)
        collector.refreshNow()
        HistoryProbe.sample()
        let first = ProcessInfo.processInfo.systemUptime - start
        HistoryProbe.write(["snapshot": HistoryProbe.object(collector.snapshot()), "hourly": HistoryProbe.hourly,
                            "deviceHourly": HistoryProbe.deviceHourly], to: out + "/snapshot.json")
        HistoryProbe.mutex.lock(); let firstPeak = HistoryProbe.peak; HistoryProbe.mutex.unlock()
        let firstCPUSeconds = HistoryProbe.cpu() - firstCPU
        if seconds > 0 {
            collector.start()
            while ProcessInfo.processInfo.systemUptime - start < seconds { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            // Wait for an in-flight history scan rather than report unfinished CPU.
            while collector.snapshot().isScanning { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        HistoryProbe.sample(); monitor.cancel()
        HistoryProbe.write(["load_seconds": HistoryProbe.loadSeconds, "first_snapshot_seconds": first, "first_snapshot_cpu": firstCPUSeconds,
                            "first_snapshot_peak_phys_footprint": firstPeak, "peak_phys_footprint": HistoryProbe.peak,
                            "queue_cpu_seconds": HistoryProbe.queueCPU, "scans": HistoryProbe.scans,
                            "elapsed_seconds": ProcessInfo.processInfo.systemUptime - start,
                            "cache_bytes": (try! FileManager.default.attributesOfItem(atPath: out + "/usage-daily.json")[.size] as! NSNumber).uint64Value,
                            "error": collector.snapshot().error], to: out + "/metrics.json")
        print("DONE \(out)")
    }
}
