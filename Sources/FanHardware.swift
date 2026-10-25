import Foundation

/// Thin wrapper around the AppleSMC transport. The C bridge owns the connection.
enum FanSMC {
    private static var opened = false

    static func keyCode(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    @discardableResult
    static func open() -> Int32 {
        if opened { return 0 }
        let result = vg_smc_open()
        if result == 0 { opened = true }
        return result
    }

    static func close() {
        guard opened else { return }
        vg_smc_close()
        opened = false
    }

    static func read(_ name: String) -> (type: UInt32, size: Int, bytes: [UInt8])? {
        guard open() == 0 else { return nil }
        var type: UInt32 = 0
        var size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard vg_smc_read(keyCode(name), &type, &size, &bytes) == 0 else { return nil }
        return (type, Int(size), bytes)
    }

    static func write(_ name: String, type: UInt32, size: Int, bytes: [UInt8]) -> Int32 {
        let opened = open()
        guard opened == 0 else { return opened }
        var payload = bytes
        if payload.count < 32 { payload += [UInt8](repeating: 0, count: 32 - payload.count) }
        return vg_smc_write(keyCode(name), type, UInt32(size), payload)
    }

    /// Apple Silicon reports RPM as a native Float32; older Intel uses fpe2.
    static func decodeRPM(_ bytes: [UInt8], size: Int) -> Int? {
        if size == 4, bytes.count >= 4 {
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            guard value.isFinite, value >= 0, value <= 100_000 else { return nil }
            return Int(value.rounded())
        }
        if size == 2, bytes.count >= 2 {
            return Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        }
        return nil
    }

    static func readRPM(_ name: String) -> Int? {
        guard let value = read(name) else { return nil }
        return decodeRPM(value.bytes, size: value.size)
    }

    static func readByte(_ name: String) -> UInt8? {
        guard let value = read(name), value.size >= 1 else { return nil }
        return value.bytes[0]
    }

    static func writeByte(_ name: String, _ byte: UInt8) -> Int32 {
        guard let value = read(name), value.size >= 1 else { return -1 }
        return write(name, type: value.type, size: value.size, bytes: [byte])
    }

    static func writeRPM(_ name: String, _ rpm: Float) -> Int32 {
        guard rpm.isFinite, rpm >= 0, rpm <= 100_000, let value = read(name) else { return -1 }
        if value.size == 4 {
            var bytes = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: rpm) { bytes.replaceSubrange(0..<4, with: $0) }
            return write(name, type: value.type, size: 4, bytes: bytes)
        }
        if value.size == 2 {
            let raw = UInt16(max(0, min(16_383, rpm)) * 4)
            return write(name, type: value.type, size: 2, bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)])
        }
        return -1
    }

    /// Apple Silicon exposes per-fan mode keys; older Intel uses a force mask.
    static func modeKey(_ index: Int) -> String? {
        for format in ["F%dmd", "F%dMd"] {
            let key = String(format: format, index)
            if read(key) != nil { return key }
        }
        return nil
    }

    static func fanCount() -> Int? {
        guard let count = readByte("FNum"), (1...8).contains(count) else { return nil }
        return Int(count)
    }

    static func clampRPM(_ rpm: Int, minimum: Int, maximum: Int) -> Int {
        guard maximum > minimum else { return maximum }
        return min(max(rpm, minimum), maximum)
    }
}

/// Injectable transport keeps offline helper tests away from AppleSMC.
struct FanHardwareBackend {
    var open: () -> Int32
    var close: () -> Void
    var fanCount: () -> Int?
    var readRPM: (String) -> Int?
    var modeKey: (Int) -> String?
    var writeByte: (String, UInt8) -> Int32
    var writeRPM: (String, Float) -> Int32

    static let system = FanHardwareBackend(open: FanSMC.open, close: FanSMC.close,
        fanCount: FanSMC.fanCount, readRPM: FanSMC.readRPM, modeKey: FanSMC.modeKey,
        writeByte: FanSMC.writeByte, writeRPM: FanSMC.writeRPM)
}

enum FanHardware {
    private static let notPrivileged: Int32 = -536_870_207

    static func set(rpm: Int, backend: FanHardwareBackend = .system) -> (Int32, String) {
        guard (0...100_000).contains(rpm) else { return failure("invalid-rpm") }
        defer { backend.close() }
        guard backend.open() == 0 else { return failure("smc-unavailable") }
        guard let count = backend.fanCount(), (1...8).contains(count) else { return failure("no-fans") }
        var plans: [(mode: String, target: String, rpm: Int)] = []
        // Validate every fan before the first write; a missing fan must not leave
        // an earlier fan in manual mode.
        for index in 0..<count {
            let targetKey = "F\(index)Tg"
            guard let minimum = backend.readRPM("F\(index)Mn"),
                  let maximum = backend.readRPM("F\(index)Mx"),
                  minimum >= 0, maximum > minimum, maximum <= 100_000,
                  backend.readRPM(targetKey) != nil,
                  let mode = backend.modeKey(index) else {
                return failure("fan-\(index)-unreadable")
            }
            plans.append((mode, targetKey, FanSMC.clampRPM(rpm, minimum: minimum, maximum: maximum)))
        }
        for plan in plans {
            let modeResult = backend.writeByte(plan.mode, 1)
            if modeResult != 0 {
                return failure(writeError("mode", modeResult) + rollback(plans, backend: backend))
            }
            let targetResult = backend.writeRPM(plan.target, Float(plan.rpm))
            if targetResult != 0 {
                return failure(writeError("target", targetResult) + rollback(plans, backend: backend))
            }
        }
        return (0, "VG_FAN_OK " + plans.enumerated().map { "\($0.offset)=\($0.element.rpm)" }.joined(separator: " "))
    }

    static func restoreAutomatic(backend: FanHardwareBackend = .system) -> (Int32, String) {
        defer { backend.close() }
        guard backend.open() == 0 else { return failure("smc-unavailable") }
        guard let count = backend.fanCount(), (1...8).contains(count) else { return failure("no-fans") }
        var errors: [String] = []
        // Continue after errors so that every readable fan gets its chance to
        // return to automatic control, but never report a missing mode as success.
        for index in 0..<count {
            guard let mode = backend.modeKey(index) else {
                errors.append("fan-\(index)-mode-unreadable")
                continue
            }
            let modeResult = backend.writeByte(mode, 0)
            if modeResult != 0 {
                errors.append(writeError("fan-\(index)-mode", modeResult))
                continue
            }
            let targetResult = backend.writeRPM("F\(index)Tg", 0)
            if targetResult != 0 { errors.append(writeError("fan-\(index)-target", targetResult)) }
        }
        return errors.isEmpty ? (0, "VG_FAN_OK auto") : failure(errors.joined(separator: " "))
    }

    private static func rollback(_ plans: [(mode: String, target: String, rpm: Int)],
                                 backend: FanHardwareBackend) -> String {
        var errors: [String] = []
        for plan in plans {
            let modeResult = backend.writeByte(plan.mode, 0)
            if modeResult != 0 {
                errors.append(writeError(plan.mode, modeResult))
                continue
            }
            let targetResult = backend.writeRPM(plan.target, 0)
            if targetResult != 0 { errors.append(writeError(plan.target, targetResult)) }
        }
        return errors.isEmpty ? "" : " rollback-failed: " + errors.joined(separator: " ")
    }

    private static func writeError(_ operation: String, _ code: Int32) -> String {
        code == notPrivileged ? "not-privileged" : "\(operation)-\(code)"
    }

    private static func failure(_ message: String) -> (Int32, String) {
        (2, "VG_FAN_ERROR " + message)
    }
}
