import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One reading of the machine, in the spirit of exelban/stats: CPU per core, GPU, memory
/// composition, network and disk throughput, SMC temperatures and system power.
/// Every field is optional where the hardware may not expose it; the UI shows "—" rather than guessing.
struct SystemSample: Equatable {
    var at: TimeInterval = 0
    var cpu: Double?                 // 0…1, all cores
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cores: [Double] = []         // 0…1 per logical core, in kernel order
    var efficiencyCores = 0          // the first N cores on Apple Silicon are E-cores
    var gpu: Double?                 // 0…1, IOAccelerator device utilization
    var memTotal: Double = 0         // bytes
    var memApp: Double = 0
    var memWired: Double = 0
    var memCompressed: Double = 0
    var memCached: Double = 0
    var memPressure = 1              // 1 normal · 2 warning · 4 critical
    var swapUsed: Double = 0
    var netIn: Double?               // bytes / second, physical interfaces
    var netOut: Double?
    var netTotalIn: Double = 0       // current en* interface counters, not guaranteed since boot
    var netTotalOut: Double = 0
    var netCountersAvailable = false // numeric totals are meaningful only when true
    var netInterfaces: [String] = [] // same scope for rates and totals, independent of default route
    var netInterval: TimeInterval?  // actual continuous-time interval for the rates
    var diskRead: Double?            // bytes / second
    var diskWrite: Double?
    var cpuTemp: Double?             // °C, average of CPU die sensors
    var cpuTempMax: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var power: Double?               // watts, whole system (SMC PSTR)
    var fans: [Int] = []             // RPM
    var battery: Double?             // 0…1
    var charging = false
    var load1: Double = 0

    var memUsed: Double { memApp + memWired + memCompressed }
    var memFraction: Double? { memTotal > 0 ? min(1, memUsed / memTotal) : nil }
}

/// Short rolling series for sparklines. Values are already normalized where noted.
struct SystemSeries: Equatable {
    static let capacity = 72
    var cpu: [Double] = []
    var gpu: [Double] = []
    var mem: [Double] = []
    var netIn: [Double] = []
    var netOut: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []
    var cpuTemp: [Double] = []
    var power: [Double] = []

    mutating func append(_ s: SystemSample) {
        func push(_ list: inout [Double], _ value: Double?) {
            guard let value, value.isFinite else { return }
            list.append(value)
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        }
        push(&cpu, s.cpu); push(&gpu, s.gpu); push(&mem, s.memFraction)
        push(&netIn, s.netIn); push(&netOut, s.netOut)
        push(&diskRead, s.diskRead); push(&diskWrite, s.diskWrite)
        push(&cpuTemp, s.cpuTemp); push(&power, s.power)
    }
}

/// Sampling runs on its own utility queue: fast while the panel is open, slow otherwise,
/// so the sparklines already have recent history when the panel appears.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var latest = SystemSample()
    @Published private(set) var series = SystemSeries()

    private let queue = DispatchQueue(label: "io.github.xixilys.vibedeck.system-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var visible = false
    private var thermostat = false
    private var started = false

    // Previous counters, owned by `queue`.
    private var lastTicks: [[UInt32]] = []
    private var networkCounters = SystemNetworkCounters()
    private var lastDisk: (at: TimeInterval, read: UInt64, write: UInt64)?
    private var sensorKeys: (cpu: [String], gpu: [String], ssd: [String], fans: Int)?
    private var history = SystemSeries()

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.sample()
            self.schedule()
        }
    }

    func setVisible(_ shown: Bool) {
        queue.async { [weak self] in
            guard let self, self.visible != shown else { return }
            self.visible = shown
            if shown { self.sample() }
            if self.started { self.schedule() }
        }
    }

    /// The fan thermostat needs fresh temperatures even with the panel closed.
    func setThermostatActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.thermostat != active else { return }
            self.thermostat = active
            if self.started { self.schedule() }
        }
    }

    private func schedule() {
        timer?.cancel()
        let interval: Double = visible ? 2 : thermostat ? 5 : 10
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(visible ? 200 : 2000))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    private func sample() {
        var s = SystemSample()
        let now = Date().timeIntervalSince1970
        s.at = now
        readCPU(into: &s)
        readMemory(into: &s)
        s.gpu = Self.gpuUtilization()
        readNetwork(into: &s)
        readDisk(into: &s, now: now)
        readSensors(into: &s)
        readBattery(into: &s)
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { s.load1 = load[0] }
        history.append(s)
        let snapshot = history
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.latest != s { self.latest = s }
            self.series = snapshot
            FanThermostat.shared.tick(s)
        }
    }

    // MARK: CPU

    private func readCPU(into s: inout SystemSample) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [[UInt32]] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return }
        var cores: [Double] = []
        var user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for (now, before) in zip(ticks, lastTicks) {
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(now[$0] &- before[$0]) }
            let busyUser = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let busySystem = d[Int(CPU_STATE_SYSTEM)]
            let all = d.reduce(0, +)
            cores.append(all > 0 ? Double(busyUser + busySystem) / Double(all) : 0)
            user += busyUser; system += busySystem; total += all
        }
        guard total > 0 else { return }
        s.cores = cores
        s.cpuUser = Double(user) / Double(total)
        s.cpuSystem = Double(system) / Double(total)
        s.cpu = min(1, s.cpuUser + s.cpuSystem)
        s.efficiencyCores = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    // MARK: Memory

    private func readMemory(into s: inout SystemSample) {
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            s.memApp = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count)) * page
            s.memWired = Double(stats.wire_count) * page
            s.memCompressed = Double(stats.compressor_page_count) * page
            s.memCached = (Double(stats.purgeable_count) + Double(stats.external_page_count)) * page
        }
        s.memPressure = Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swapUsed = Double(swap.xsu_used) }
    }

    // MARK: GPU

    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber else { continue }
            best = max(best ?? 0, min(1, value.doubleValue / 100))
        }
        return best
    }

    // MARK: Network (current en* interfaces; exclude tunnel/bridge/loopback double counting)

    private func readNetwork(into s: inout SystemSample) {
        guard let snapshot = SystemNetworkCounters.read() else {
            networkCounters.invalidate()
            return
        }
        let reading = networkCounters.consume(snapshot)
        s.netCountersAvailable = true
        s.netInterfaces = snapshot.counters.keys.sorted()
        s.netTotalIn = reading.totalIn
        s.netTotalOut = reading.totalOut
        s.netIn = reading.inRate
        s.netOut = reading.outRate
        s.netInterval = reading.interval
    }

    // MARK: Disk

    private func readDisk(into s: inout SystemSample, now: TimeInterval) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        if let last = lastDisk, now > last.at, read >= last.read, write >= last.write {
            let dt = now - last.at
            s.diskRead = Double(read - last.read) / dt
            s.diskWrite = Double(write - last.write) / dt
        }
        lastDisk = (now, read, write)
    }

    // MARK: SMC sensors (read-only; the fan helper alone writes)

    private func readSensors(into s: inout SystemSample) {
        if sensorKeys == nil { sensorKeys = Self.discoverSensorKeys() }
        guard let keys = sensorKeys else { return }
        let cpu = keys.cpu.compactMap(Self.temperature)
        if !cpu.isEmpty { s.cpuTemp = cpu.reduce(0, +) / Double(cpu.count); s.cpuTempMax = cpu.max() }
        let gpu = keys.gpu.compactMap(Self.temperature)
        if !gpu.isEmpty { s.gpuTemp = gpu.reduce(0, +) / Double(gpu.count) }
        let ssd = keys.ssd.compactMap(Self.temperature)
        if !ssd.isEmpty { s.ssdTemp = ssd.max() }
        if let watts = Self.float("PSTR"), watts > 0, watts < 2000 { s.power = watts }
        s.fans = (0..<keys.fans).compactMap { FanSMC.readRPM("F\($0)Ac") }
    }

    private static func discoverSensorKeys() -> (cpu: [String], gpu: [String], ssd: [String], fans: Int) {
        guard FanSMC.open() == 0, let count = FanSMC.read("#KEY") else { return ([], [], [], 0) }
        let total = count.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        var cpu: [String] = [], gpu: [String] = [], ssd: [String] = []
        for index in 0..<min(total, 4096) {
            var code: UInt32 = 0
            guard vg_smc_key_at(UInt32(index), &code) == 0 else { continue }
            let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
            guard name.hasPrefix("T"), temperature(name) != nil else { continue }
            // Apple Silicon: Tp* performance and Te* efficiency clusters; Intel: TC*.
            if name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("TC") { cpu.append(name) }
            else if name.hasPrefix("Tg") || name.hasPrefix("TG") { gpu.append(name) }
            else if name.hasPrefix("TH0") { ssd.append(name) }
        }
        let fans = FanSMC.readByte("FNum").map(Int.init) ?? 0
        return (cpu, gpu, ssd, min(fans, 4))
    }

    private static func float(_ key: String) -> Double? {
        guard let value = FanSMC.read(key), value.size == 4 else { return nil }
        let number = Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        return number.isFinite ? number : nil
    }

    /// Accepts flt (Apple Silicon) and sp78 (Intel) encodings; ignores obviously idle or broken probes.
    private static func temperature(_ key: String) -> Double? {
        guard let value = FanSMC.read(key) else { return nil }
        var number: Double?
        if value.size == 4 { number = Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) }
        else if value.size == 2 { number = Double(Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))) / 256 }
        guard let number, number.isFinite, number > 10, number < 125 else { return nil }
        return number
    }

    // MARK: Battery

    private func readBattery(into s: inout SystemSample) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            s.battery = Double(current) / Double(maximum)
            s.charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

/// Full-width counters and their continuity. A route-interface list is not a safe
/// counter source: on recent macOS its if_data64 byte fields can wrap at 4 GiB.
/// The public interface MIB returns the full counters, as used by netstat.
struct SystemNetworkCounters {
    struct Counter: Equatable {
        var index: UInt32
        var input: UInt64
        var output: UInt64
    }
    struct Snapshot {
        var at: TimeInterval         // mach_continuous_time, including sleep
        var counters: [String: Counter]
    }
    struct Reading {
        var totalIn: Double
        var totalOut: Double
        var inRate: Double?
        var outRate: Double?
        var interval: TimeInterval?
    }

    private var previous: Snapshot?
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    mutating func invalidate() { previous = nil }

    mutating func consume(_ snapshot: Snapshot) -> Reading {
        var result = Reading(totalIn: snapshot.counters.values.reduce(0) { $0 + Double($1.input) },
                             totalOut: snapshot.counters.values.reduce(0) { $0 + Double($1.output) })
        defer { previous = snapshot }
        guard let old = previous, snapshot.at.isFinite, old.at.isFinite,
              snapshot.at > old.at, !snapshot.counters.isEmpty,
              snapshot.counters.keys == old.counters.keys,
              snapshot.counters.allSatisfy({ old.counters[$0.key]?.index == $0.value.index }) else { return result }
        let elapsed = snapshot.at - old.at
        var input: Double = 0, output: Double = 0
        var inputContinuous = true, outputContinuous = true
        for (name, counter) in snapshot.counters {
            guard let before = old.counters[name] else { return result }
            // A decrease is a counter reset (or eventual UInt64 wrap), never a
            // negative speed or a fabricated 2^64-byte transfer. Directions are independent.
            if counter.input >= before.input { input += Double(counter.input - before.input) }
            else { inputContinuous = false }
            if counter.output >= before.output { output += Double(counter.output - before.output) }
            else { outputContinuous = false }
        }
        if inputContinuous { result.inRate = input / elapsed }
        if outputContinuous { result.outRate = output / elapsed }
        if inputContinuous || outputContinuous { result.interval = elapsed }
        return result
    }

    static func read() -> Snapshot? {
        // One name enumeration per sample, not if_indextoname per interface.
        // Indices let the differencer recognize replacement of a same-name interface.
        guard let interfaces = if_nameindex() else { return nil }
        defer { if_freenameindex(interfaces) }
        var indices: [String: UInt32] = [:]
        var item = interfaces
        while item.pointee.if_index != 0, let name = item.pointee.if_name {
            let name = String(cString: name)
            if name.hasPrefix("en") { indices[name] = item.pointee.if_index }
            item = item.advanced(by: 1)
        }
        guard !indices.isEmpty else { return nil }

        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0,
              length > 0, length <= buffer.count,
              length % MemoryLayout<ifmibdata>.stride == 0 else { return nil }
        let timestamp = Double(mach_continuous_time()) * secondsPerTick
        var counters: [String: Counter] = [:]
        var valid = true
        buffer.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: length, by: MemoryLayout<ifmibdata>.stride) {
                var data = raw.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
                // Bound the read even if a malformed kernel record has no NUL.
                let name = withUnsafeBytes(of: &data.ifmd_name) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                guard name.hasPrefix("en") else { continue }
                guard let index = indices[name], counters[name] == nil else { valid = false; break }
                counters[name] = Counter(index: index, input: data.ifmd_data.ifi_ibytes,
                                         output: data.ifmd_data.ifi_obytes)
            }
        }
        // Enumeration may race a hot-plug; publish unknown rather than partial totals.
        guard valid, counters.count == indices.count else { return nil }
        return Snapshot(at: timestamp, counters: counters)
    }

    static func selfTest() {
        func snapshot(_ at: Double, _ input: UInt64, _ output: UInt64, index: UInt32 = 1) -> Snapshot {
            Snapshot(at: at, counters: ["en0": Counter(index: index, input: input, output: output)])
        }
        var counters = Self()
        let first = counters.consume(snapshot(10, 5_000_000_000, 8_000_000_000))
        precondition(first.inRate == nil && first.outRate == nil && first.totalIn == 5_000_000_000)
        var at = 10.0, input: UInt64 = 5_000_000_000, output: UInt64 = 8_000_000_000
        for seconds in [2.0, 5.0, 10.0] {
            at += seconds; input += UInt64(seconds) * 20_000_000; output += UInt64(seconds) * 1_500_000
            let result = counters.consume(snapshot(at, input, output))
            precondition(result.inRate == 20_000_000 && result.outRate == 1_500_000 && result.interval == seconds)
        }
        // Wall-clock time is deliberately absent from the model, so changing it cannot affect rates.
        let reset = counters.consume(snapshot(28, 1, output + 1_500_000))
        precondition(reset.inRate == nil && reset.outRate == 1_500_000)
        let resume = counters.consume(snapshot(30, 40_000_001, output + 4_500_000))
        precondition(resume.inRate == 20_000_000 && resume.outRate == 1_500_000)
        var appeared = snapshot(32, 80_000_001, output + 7_500_000)
        appeared.counters["en1"] = Counter(index: 2, input: 1_000_000_000_000, output: 2_000_000_000_000)
        let joined = counters.consume(appeared)
        precondition(joined.inRate == nil && joined.outRate == nil && joined.totalIn == 1_000_080_000_001)
        let removed = counters.consume(snapshot(34, 120_000_001, output + 10_500_000))
        precondition(removed.inRate == nil && removed.outRate == nil)
        let replaced = counters.consume(snapshot(36, 3_000_000_000_000, 4_000_000_000_000, index: 9))
        precondition(replaced.inRate == nil && replaced.outRate == nil)
        counters.invalidate()
        precondition(counters.consume(snapshot(38, 3_000_040_000_000, 4_000_003_000_000, index: 9)).inRate == nil)
        precondition(counters.consume(snapshot(38, 3_000_080_000_000, 4_000_006_000_000, index: 9)).inRate == nil)
        var at32BitBoundary = Self()
        _ = at32BitBoundary.consume(snapshot(0, 4_290_000_000, 100))
        let crossed32 = at32BitBoundary.consume(snapshot(2, 4_330_000_000, 100))
        precondition(crossed32.inRate == 20_000_000 && crossed32.outRate == 0)
        var idle = Self()
        precondition(idle.consume(snapshot(0, 0, 0)).inRate == nil)
        let zero = idle.consume(snapshot(2, 0, 0))
        precondition(zero.inRate == 0 && zero.outRate == 0)
        var wrapping = Self()
        _ = wrapping.consume(snapshot(100, UInt64.max - 1, UInt64.max - 1))
        let wrapped = wrapping.consume(snapshot(102, 2, 2))
        precondition(wrapped.inRate == nil && wrapped.outRate == nil)
    }
}

enum SystemFormat {
    /// Network units are decimal bytes (MB = 1,000,000 B), not bits or binary MiB.
    static func networkSize(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = bytes, index = 0
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        let digits = value >= 100 || index == 0 ? 0 : value >= 10 ? 1 : 2
        return String(format: "%.\(digits)f %@", value, units[index])
    }

    static func networkRate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return networkSize(bytes) + "/s"
    }

    static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite else { return "—" }
        return size(bytes) + "/s"
    }

    static func size(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(0, bytes), index = 0
        while value >= 1000, index < units.count - 1 { value /= 1024; index += 1 }
        let digits = value >= 100 || index == 0 ? 0 : value >= 10 ? 1 : 2
        return String(format: "%.\(digits)f %@", value, units[index])
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: value < 10 ? "%.1f W" : "%.0f W", value)
    }
}
