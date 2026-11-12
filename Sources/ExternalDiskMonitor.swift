import Foundation
import Combine

/// One mounted external volume. The System page uses this for the "external storage" tile: capacity,
/// bus, SSD/HDD and the drive's own SMART verdict, without pretending a USB bridge reports temperature.
struct ExternalDisk: Identifiable, Equatable {
    var id: String
    var volumeName: String
    var mountPath: String
    var model: String
    var bsdName: String
    var wholeDisk: String
    var isSolidState: Bool?
    var protocolName: String
    var smartStatus: String
    var removable: Bool
    var totalBytes: Int64
    var freeBytes: Int64

    var usedFraction: Double {
        guard totalBytes > 0, freeBytes >= 0 else { return 0 }
        return max(0, min(1, 1 - Double(freeBytes) / Double(totalBytes)))
    }
    var freeFraction: Double { max(0, 1 - usedFraction) }
    var mediaLabel: String {
        switch isSolidState {
        case .some(true): return L("SSD", "SSD")
        case .some(false): return L("机械盘", "HDD")
        case .none: return L("介质未知", "Media unknown")
        }
    }
    var smartHealthy: Bool { smartStatus.lowercased().contains("verified") || smartStatus.contains("已验证") }
    var smartFailed: Bool {
        let lower = smartStatus.lowercased()
        return lower.contains("fail") || smartStatus.contains("异常") || smartStatus.contains("失败")
    }
    var smartUnsupported: Bool { smartStatus.lowercased().contains("not supported") || smartStatus.contains("不支持") }
}

/// Enumerates mounted external volumes and asks diskutil for the details Foundation does not expose
/// (model, bus, SMART). Refreshes at most once a minute on a utility queue; the System page only reads
/// the published snapshot.
final class ExternalDiskMonitor: ObservableObject {
    static let shared = ExternalDiskMonitor()

    @Published private(set) var disks: [ExternalDisk] = []
    @Published private(set) var refreshedAt: TimeInterval = 0
    @Published private(set) var error = ""

    private let worker = DispatchQueue(label: "vibedeck.external-disks", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private var lastAttempt: TimeInterval = 0
    private var timer: Timer?
    /// Disk models/SMART only feed the System page; while the panel is closed a 10-minute probe is plenty.
    private var panelVisible = false

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshIfNeeded(force: true) }
    }

    func start() {
        guard timer == nil else { return }
        refreshIfNeeded(force: true)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshIfNeeded() }
        timer.tolerance = 8
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let due = !inFlight && (force || now - lastAttempt >= (panelVisible ? 60 : 600))
        if due { inFlight = true; lastAttempt = now }
        lock.unlock()
        guard due else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let result = Self.collect()
            DispatchQueue.main.async {
                self.lock.lock(); self.inFlight = false; self.lock.unlock()
                if let disks = result.disks {
                    if disks != self.disks { self.disks = disks }
                    self.refreshedAt = Date().timeIntervalSince1970
                    self.error = result.error
                } else {
                    self.error = result.error
                }
            }
        }
    }

    /// Used by the offscreen renderer, where the 60-second timer would not have fired yet.
    func refreshSynchronously() {
        let result = Self.collect()
        if let disks = result.disks {
            if disks != self.disks { self.disks = disks }
            self.refreshedAt = Date().timeIntervalSince1970
        }
        error = result.error
    }

    // MARK: - Collection

    private struct Outcome { var disks: [ExternalDisk]?; var error: String }

    /// Only local, non-internal, browsable volumes. A disconnected mount throws while reading resource
    /// values; skip it instead of failing the whole list.
    static func candidateVolumes(fileManager: FileManager = .default) -> [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                      .volumeIsBrowsableKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            let path = url.path
            guard path != "/", !path.hasPrefix("/System/Volumes"), path.hasPrefix("/Volumes/") else { return false }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsInternal != true
        }
    }

    private static func collect() -> Outcome {
        let volumes = candidateVolumes()
        guard !volumes.isEmpty else { return Outcome(disks: [], error: "") }
        var disks: [ExternalDisk] = []
        var errors: [String] = []
        for url in volumes {
            let values = (try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]))
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let important = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
            let plain = Int64(values?.volumeAvailableCapacity ?? 0)
            let free = important > 0 ? important : plain
            var info = diskutilInfo(path: url.path)
            // APFS volume plists omit the drive model and SSD flag; the whole-disk plist has them.
            if let parent = info?["ParentWholeDisk"] as? String, !parent.isEmpty,
               let whole = diskutilInfo(path: "/dev/" + parent) {
                for (key, value) in whole where info?[key] == nil || (info?[key] as? String)?.isEmpty == true {
                    info?[key] = value
                }
            }
            if info == nil { errors.append(url.lastPathComponent) }
            if let disk = parse(info: info, mount: url, totalBytes: total, freeBytes: free) {
                disks.append(disk)
            }
        }
        disks.sort { $0.mountPath.localizedStandardCompare($1.mountPath) == .orderedAscending }
        return Outcome(disks: disks, error: errors.isEmpty ? "" : L("磁盘详情读取失败：", "Cannot read disk details: ") + errors.joined(separator: ", "))
    }

    /// Pure parser for `diskutil info -plist`. Missing keys degrade to "unknown" instead of hiding the volume.
    static func parse(info: [String: Any]?, mount: URL, totalBytes: Int64, freeBytes: Int64) -> ExternalDisk? {
        let row = info ?? [:]
        func string(_ key: String) -> String {
            guard let value = row[key] as? String else { return "" }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func int64(_ key: String) -> Int64? {
            guard let n = row[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.int64Value
        }
        let location = string("DeviceLocation")
        // Mounted external volumes report External. A disk image/virtual volume can say Virtual; skip it.
        if let info {
            if (info["Internal"] as? Bool) == true { return nil }
            if !location.isEmpty, location != "External" { return nil }
        }
        func positive(_ key: String) -> Int64? {
            guard let value = int64(key), value > 0 else { return nil }
            return value
        }
        let total = positive("DiskSize") ?? positive("Size") ?? positive("TotalSize") ?? max(0, totalBytes)
        let containerFree = positive("APFSContainerFree") ?? positive("ContainerFreeSpace")
            ?? positive("VolumeFreeSpace") ?? max(0, freeBytes)
        guard total > 0 else { return nil }
        let solid: Bool? = {
            if let number = row["SolidState"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            switch string("SolidState").lowercased() {
            case "yes", "true": return true
            case "no", "false": return false
            default: return nil
            }
        }()
        let name = string("VolumeName").isEmpty ? mount.lastPathComponent : string("VolumeName")
        let model = string("DeviceMediaName").isEmpty
            ? (string("MediaName").isEmpty ? L("未知型号", "Unknown model") : string("MediaName"))
            : string("DeviceMediaName")
        let bsd = string("DeviceIdentifier")
        let whole = string("ParentWholeDisk")
        let protocolName = string("Protocol").isEmpty ? string("BusProtocol") : string("Protocol")
        let smart = string("SMARTStatus").isEmpty ? L("未知", "Unknown") : string("SMARTStatus")
        let removable = string("RemovableMedia").lowercased() == "yes" || string("RemovableMedia").lowercased() == "removable"
        let id = whole.isEmpty ? (bsd.isEmpty ? mount.path : bsd) : whole + "|" + mount.path
        return ExternalDisk(id: id, volumeName: name, mountPath: mount.path, model: model, bsdName: bsd,
                            wholeDisk: whole, isSolidState: solid, protocolName: protocolName,
                            smartStatus: smart, removable: removable, totalBytes: total, freeBytes: containerFree)
    }

    private static func diskutilInfo(path: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // A failing USB bridge can block diskutil; do not let one drive stall the tile forever.
        if done.wait(timeout: .now() + 6) != .success {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist
    }

    static func selfTest() {
        let mount = URL(fileURLWithPath: "/Volumes/fixture")
        let plist: [String: Any] = [
            "DeviceLocation": "External", "DiskSize": NSNumber(value: 1_000_000),
            "ContainerFreeSpace": NSNumber(value: 250_000), "VolumeName": "fixture",
            "DeviceMediaName": "Samsung SSD 980 1TB", "SolidState": "Yes", "Protocol": "PCI-Express",
            "SMARTStatus": "Verified", "DeviceIdentifier": "disk9s1", "ParentWholeDisk": "disk9",
            "RemovableMedia": "Fixed"
        ]
        let disk = parse(info: plist, mount: mount, totalBytes: 0, freeBytes: 0)!
        precondition(disk.volumeName == "fixture" && disk.isSolidState == true && disk.smartHealthy)
        precondition(disk.totalBytes == 1_000_000 && disk.freeBytes == 250_000)
        precondition(abs(disk.usedFraction - 0.75) < 0.0001)
        precondition(parse(info: ["DeviceLocation": "Internal"], mount: mount, totalBytes: 1, freeBytes: 0) == nil)
        let hdd = parse(info: ["DeviceLocation": "External", "DiskSize": NSNumber(value: 3_000), "SolidState": "No",
                               "SMARTStatus": "Not Supported", "DeviceMediaName": "HUS724030ALE641",
                               "ParentWholeDisk": "disk4"], mount: mount, totalBytes: 0, freeBytes: 0)!
        precondition(hdd.isSolidState == false && hdd.smartUnsupported && !hdd.smartHealthy)
    }
}
