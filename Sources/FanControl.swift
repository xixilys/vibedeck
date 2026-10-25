import Foundation
import SwiftUI
import Combine

/// One fan as reported by AppleSMC. Reads need no privileges; writes do.
struct FanReading: Identifiable, Equatable {
    let index: Int
    let currentRPM: Int
    let targetRPM: Int
    let minimumRPM: Int
    let maximumRPM: Int
    let isManual: Bool

    var id: Int { index }
}

enum FanControlError: LocalizedError {
    case smcUnavailable(Int32)
    case noFans
    case invalidData(String)
    case writeDenied
    case authorizationCancelled
    case serviceUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .smcUnavailable(let code):
            return L("无法连接风扇控制器（AppleSMC \(code)）", "Cannot reach the fan controller (AppleSMC \(code))")
        case .noFans:
            return L("这台 Mac 没有可读的风扇数据", "This Mac exposes no readable fans")
        case .invalidData(let key):
            return L("风扇数据无效（\(key)）", "Invalid fan data (\(key))")
        case .writeDenied:
            return L("写入风扇需要管理员权限", "Changing fan speed needs administrator access")
        case .authorizationCancelled:
            return L("已取消管理员授权", "Administrator authorization was cancelled")
        case .serviceUnavailable:
            return L("无法连接风扇服务。请检查服务是否已启用；更换应用版本后需更新服务。",
                     "Cannot connect to the fan service. Check that it is enabled; update the service after replacing the app.")
        case .commandFailed(let message):
            return message.isEmpty ? L("风扇命令失败", "Fan command failed") : message
        }
    }
}

/// Unprivileged telemetry for the panel; writes go to the installed XPC service.
final class FanControl {
    static let shared = FanControl()
    /// kIOReturnNotPrivileged, returned by AppleSMC for writes from a user process.
    static let notPrivileged: Int32 = -536_870_207

    private let lock = NSLock()
    private let telemetryQueue = DispatchQueue(label: "io.github.xixilys.vibedeck.fan-telemetry", qos: .utility)
    private let telemetryLock = NSLock()
    private var telemetryInFlight = false
    private var telemetryReplies: [UUID: (Result<[FanReading], FanControlError>) -> Void] = [:]
    private let commandQueue = DispatchQueue(label: "io.github.xixilys.vibedeck.fan-commands", qos: .utility)
    private var commands: [(String, Int, (Result<Void, FanControlError>) -> Void)] = []
    private let readHardware: (() -> Result<[FanReading], FanControlError>)?
    private let perform: (String, Int, @escaping (Result<String, FanControlError>) -> Void) -> Void

    private init() {
        readHardware = nil
        perform = { FanService.perform($0, rpm: $1, completion: $2) }
    }

    /// Explicitly injected hardware/service doubles keep self-tests entirely off the real fan path.
    init(readHardware: @escaping () -> Result<[FanReading], FanControlError>,
         perform: @escaping (String, Int, @escaping (Result<String, FanControlError>) -> Void) -> Void) {
        self.readHardware = readHardware
        self.perform = perform
    }

    /// Hardware reads may block. Coalesce concurrent readers, but complete every caller.
    /// Returns true for a new hardware read, false when joining an existing one.
    @discardableResult
    func readSnapshot(completion: @escaping (Result<[FanReading], FanControlError>) -> Void) -> Bool {
        let request = UUID()
        telemetryLock.lock()
        telemetryReplies[request] = completion
        let startRead = !telemetryInFlight
        if startRead { telemetryInFlight = true }
        telemetryLock.unlock()
        // Do not clear telemetryInFlight on timeout: a blocked native read must not spawn
        // replacement hardware threads. Only this caller expires; later reads can join it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            telemetryLock.lock()
            let expired = telemetryReplies.removeValue(forKey: request)
            telemetryLock.unlock()
            expired?(.failure(.commandFailed(L("读取风扇状态超时", "Fan telemetry timed out"))))
        }
        guard startRead else { return false }
        telemetryQueue.async { [self] in
            let result = snapshot()
            telemetryLock.lock()
            telemetryInFlight = false
            let replies = Array(telemetryReplies.values)
            telemetryReplies.removeAll()
            telemetryLock.unlock()
            DispatchQueue.main.async { replies.forEach { $0(result) } }
        }
        return true
    }

    func snapshot() -> Result<[FanReading], FanControlError> {
        if let readHardware { return readHardware() }
        lock.lock()
        defer { lock.unlock() }
        let opened = FanSMC.open()
        guard opened == 0 else { return .failure(.smcUnavailable(opened)) }
        guard let count = FanSMC.fanCount() else { return .failure(.noFans) }

        var fans: [FanReading] = []
        for index in 0..<count {
            guard let current = FanSMC.readRPM("F\(index)Ac"),
                  let minimum = FanSMC.readRPM("F\(index)Mn"),
                  let maximum = FanSMC.readRPM("F\(index)Mx") else { continue }
            let target = FanSMC.readRPM("F\(index)Tg") ?? 0
            let manual = FanSMC.modeKey(index).flatMap { FanSMC.readByte($0) == 1 } ?? false
            fans.append(FanReading(index: index, currentRPM: current, targetRPM: target,
                                   minimumRPM: minimum, maximumRPM: maximum, isManual: manual))
        }
        return fans.isEmpty ? .failure(.invalidData("FNum")) : .success(fans)
    }

    /// UI convenience: acknowledge the mutation first, then read telemetry off the command queue.
    /// A telemetry timeout is not a reversal of the acknowledged hardware command.
    func applyManual(rpm: Int, completion: @escaping (Result<[FanReading], FanControlError>) -> Void) {
        applyManualCommand(rpm: rpm) { [self] result in
            switch result {
            case .success: readSnapshot(completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func restoreAutomatic(completion: @escaping (Result<[FanReading], FanControlError>) -> Void) {
        restoreAutomaticCommand { [self] result in
            switch result {
            case .success: readSnapshot(completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    /// Cooling and quit use acknowledgement-only operations. Never wait for local SMC telemetry.
    func applyManualCommand(rpm: Int, completion: @escaping (Result<Void, FanControlError>) -> Void) {
        enqueue("manual", rpm: rpm, completion: completion)
    }

    func restoreAutomaticCommand(completion: @escaping (Result<Void, FanControlError>) -> Void) {
        enqueue("auto", rpm: 0, completion: completion)
    }

    private func enqueue(_ command: String, rpm: Int, completion: @escaping (Result<Void, FanControlError>) -> Void) {
        commandQueue.async { [self] in
            commands.append((command, rpm, completion))
            if commands.count == 1 { performNext() }
        }
    }

    /// Service acknowledgements order writes. A blocked telemetry queue or its SMC lock
    /// cannot stop the following Auto command from reaching the separate privileged helper.
    private func performNext() {
        guard let (command, rpm, completion) = commands.first else { return }
        perform(command, rpm) { [self] result in
            commandQueue.async { [self] in
                let acknowledgement: Result<Void, FanControlError>
                switch result {
                case .success(let output):
                    acknowledgement = output.hasPrefix("VG_FAN_OK") ? .success(()) : .failure(Self.error(from: output))
                case .failure(let error):
                    acknowledgement = .failure(error)
                }
                commands.removeFirst()
                completion(acknowledgement)
                performNext()
            }
        }
    }

    private static func error(from output: String) -> FanControlError {
        let line = output.split(separator: "\n").first { $0.hasPrefix("VG_FAN_ERROR") }
            ?? output.split(separator: "\n").first ?? ""
        let text = line.replacingOccurrences(of: "VG_FAN_ERROR", with: "").trimmingCharacters(in: .whitespaces)
        if text.contains("not-privileged") || text.contains("not privileged") {
            return .writeDenied
        }
        return .commandFailed(text)
    }

}

/// CLI uses the same service as the panel. Only --fan-service-enable requests approval.
enum FanCommandLine {
    static func run(_ arguments: [String]) -> Int32? {
        if let index = arguments.firstIndex(of: "--fan-set") {
            guard index + 1 < arguments.count, let rpm = Int(arguments[index + 1]), (0...100_000).contains(rpm) else {
                print("VG_FAN_ERROR invalid-rpm")
                return 2
            }
            return serviceCommand("manual", rpm: rpm)
        }
        if arguments.contains("--fan-auto") {
            return serviceCommand("auto")
        }
        if arguments.contains("--fan-service-enable") {
            let semaphore = DispatchSemaphore(value: 0)
            var code: Int32 = 1
            FanService.enable { result in
                switch result {
                case .success(let output): print(output); code = 0
                case .failure(let error): print(error.localizedDescription)
                }
                semaphore.signal()
            }
            semaphore.wait()
            return code
        }
        if arguments.contains("--fan-service-status") {
            print("FAN_SERVICE \(FanService.installation())")
            return serviceCommand("ping")
        }
        if arguments.contains("--fan-status") {
            switch FanControl.shared.snapshot() {
            case .success(let fans):
                for fan in fans {
                    print("FAN \(fan.index) current=\(fan.currentRPM) target=\(fan.targetRPM) min=\(fan.minimumRPM) max=\(fan.maximumRPM) manual=\(fan.isManual)")
                }
                return 0
            case .failure(let error):
                print("VG_FAN_ERROR \(error.localizedDescription)")
                return 2
            }
        }
        return nil
    }

    private static func serviceCommand(_ command: String, rpm: Int = 0) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        FanService.perform(command, rpm: rpm) { result in
            switch result {
            case .success(let output): print(output); code = 0
            case .failure(let error): print(error.localizedDescription)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return code
    }
}

/// 系统页风扇卡片：读取无需授权，调速复用首次授权安装的服务。
struct FanControlCard: View {
    var demo: Bool = false
    @State private var fans: [FanReading] = []
    @State private var target: Double = 0
    @State private var touched = false
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var readError: String?
    @State private var lastRead = Date.distantPast
    @State private var installation: FanServiceInstallation = .missing
    @State private var checkingInstallation = true
    @State private var serviceUnavailable = false
    @ObservedObject private var thermostat = FanThermostat.shared
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var range: ClosedRange<Double> {
        let low = fans.map(\.minimumRPM).min() ?? 1000
        let high = fans.map(\.maximumRPM).max() ?? 4900
        return Double(low)...Double(max(low + 1, high))
    }

    private var isManual: Bool { fans.contains(where: \.isManual) }

    /// Presentation only: the card's glow follows the mode already shown in the header; no control state is read beyond it.
    private var shellTint: Color? {
        if fans.isEmpty { return nil }
        if thermostat.enabled { return Glass.thermal(thermostat.lastTemperature) }
        return isManual ? .orange : nil
    }

    private var sample: FanReading {
        FanReading(index: 0, currentRPM: 1100, targetRPM: 1100, minimumRPM: 1000, maximumRPM: 4900, isManual: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "fan").foregroundStyle(shellTint ?? .secondary)
                Text(L("风扇", "Fans")).font(VG.headline)
                VGInfoButton(title: L("风扇控制", "Fan control"),
                             text: L("手动转速保持到恢复自动或重启。预设会立即应用到所有风扇。首次启用或更新服务需管理员授权。",
                                     "Manual speed stays until Auto or restart. Presets apply immediately to all fans. Service setup and updates need administrator approval."))
                Spacer(minLength: 4)
                Text(fans.isEmpty ? "—" : thermostat.enabled ? L("智能温控", "Smart") : isManual ? L("手动", "Manual") : L("系统自动", "System auto"))
                    .font(VG.caption).foregroundStyle(thermostat.enabled ? Glass.memory : isManual ? Color.orange : .secondary)
            }

            if fans.isEmpty {
                Text(readError ?? L("正在读取风扇…", "Reading fans…"))
                    .font(VG.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(fans) { fan in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("风扇 \(fan.index + 1)", "Fan \(fan.index + 1)"))
                            .font(VG.body).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("\(fan.currentRPM)").font(VG.number(20)).monospacedDigit()
                        Text("RPM").font(VG.caption).foregroundStyle(.secondary)
                    }
                    .help(L("范围 \(fan.minimumRPM)–\(fan.maximumRPM) RPM · \(fan.isManual ? "手动" : "自动")", "Range \(fan.minimumRPM)–\(fan.maximumRPM) RPM · \(fan.isManual ? "manual" : "auto")"))
                }
                thermostatRow
                HStack(spacing: 6) {
                    Text(L("目标", "Target")).font(VG.caption).foregroundStyle(.secondary)
                    Slider(value: $target, in: range, step: 50) { editing in
                        if editing { touched = true }
                    }
                    .controlSize(.mini)
                    .disabled(thermostat.enabled)
                    .accessibilityLabel(L("风扇目标转速", "Target fan speed"))
                    Text("\(Int(target))").font(VG.number(13)).monospacedDigit()
                        .frame(width: 48 * VG.scale, alignment: .trailing)
                }
                if installation != .installed || serviceUnavailable {
                    Button { enableService() } label: {
                        Text(checkingInstallation ? L("正在检查服务…", "Checking service…")
                             : installation == .missing ? L("启用风扇控制…", "Enable fan control…")
                             : installation == .needsUpdate ? L("更新风扇服务…", "Update fan service…")
                             : L("重新启用风扇服务…", "Re-enable fan service…"))
                            .font(VG.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .controlSize(.mini)
                    .disabled(busy || demo || checkingInstallation)
                    Text(L("启用或更新需管理员授权。", "Setup or update needs administrator approval."))
                        .font(VG.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { apply(Int(target)) } label: {
                        Text(L("应用", "Apply")).font(VG.caption)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                    .disabled(busy || demo || installation != .installed)
                    Button { restore() } label: {
                        Text(L("恢复自动", "Restore Auto")).font(VG.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .disabled(busy || demo || installation != .installed)
                    if busy { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                    Menu {
                        preset(L("静音", "Quiet"), value: range.lowerBound)
                        preset(L("均衡", "Balanced"), value: range.lowerBound + (range.upperBound - range.lowerBound) * 0.5)
                        preset(L("性能", "Performance"), value: range.lowerBound + (range.upperBound - range.lowerBound) * 0.78)
                        preset(L("全速", "Full speed"), value: range.upperBound)
                    } label: {
                        Text(L("预设", "Presets")).font(VG.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(busy || demo || installation != .installed)
                    .help(L("预设会立即应用到所有风扇", "Presets apply immediately to all fans"))
                }
                if let message {
                    Text(message).font(VG.caption)
                        .foregroundStyle(messageIsError ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .glassTile(tint: shellTint)
        .onAppear { refresh(force: true) }
        .onReceive(ticker) { _ in refresh(force: false) }
    }

    /// Smart mode: VibeDeck steers the fan to hold the CPU near a temperature, instead of macOS's curve.
    private var thermostatRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").font(VG.caption).foregroundStyle(Glass.thermal(thermostat.lastTemperature))
                Text(L("智能温控", "Smart cooling")).font(VG.body)
                VGInfoButton(title: L("智能温控", "Smart cooling"),
                             text: L("根据最高 CPU 核心温度（中值与约 10 秒平滑）调速，不是 CPU 平均温度；默认目标 80°。正常每秒最多升 30 RPM、降 12 RPM。目标不是温度上限；持续负载可能需要高转速或全速。原始温度达到 105°、平滑温度高于目标 15°、温度中断 30 秒或控制失败时请求系统自动；恢复失败会显示错误并重试。高温回退后需降至原始不高于 100° 与目标+10°中较低值，且平滑不高于目标+10°，持续有安全读数 30 秒才重试智能温控。关闭与退出也需确认系统自动；退出失败会保留应用。需要已授权的风扇服务。",
                                     "Uses the hottest CPU core (median plus about 10 seconds of smoothing), not the CPU average; default target 80°. Normal ramps: up to +30 / −12 RPM per second. The target is not a temperature limit; sustained load may need high or full speed. Raw 105°, smoothed target +15°, 30 seconds without temperature, or a control failure requests system Auto; failures are shown and retried. After heat fallback, raw must stay at or below the lower of 100° and target +10°, and smoothed at or below target +10°, with 30 seconds of fresh safe readings before Smart retries. Disabling and quitting also require Auto acknowledgement; failed quit leaves the app running. Requires the authorized fan service."))
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { thermostat.enabled }, set: { thermostat.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(demo || installation != .installed)
                    .accessibilityIdentifier("fan.thermostat")
            }
            if thermostat.enabled {
                HStack(spacing: 6) {
                    Text(L("最高核心目标", "Hottest-core target")).font(VG.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { thermostat.target }, set: { thermostat.setTarget($0) }), in: 55...95, step: 1) {
                        Text(String(format: "%.0f°", thermostat.target)).font(VG.number(13)).monospacedDigit()
                    }
                    .controlSize(.mini).fixedSize()
                    Spacer(minLength: 4)
                    Text(thermostat.phase.label).font(VG.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(L("最高 ", "Max ") + SystemFormat.temperature(thermostat.rawTemperature)
                         + L(" · 平滑 ", " · Smoothed ") + SystemFormat.temperature(thermostat.lastTemperature))
                    Spacer(minLength: 4)
                    Text(thermostat.commandedRPM.map { L("指令 \($0) RPM", "Sent \($0) RPM") } ?? L("指令 —", "Sent —"))
                }
                .font(VG.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = thermostat.lastError {
                Text(error).font(VG.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(thermostat.enabled ? 0.05 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.primary.opacity(thermostat.enabled ? 0.10 : 0.06), lineWidth: 0.6))
    }

    private func preset(_ title: String, value: Double) -> some View {
        Button {
            touched = true
            target = value
            apply(Int(value))
        } label: {
            Text("\(title) · \(Int(value)) RPM")
        }
        .disabled(busy || demo || installation != .installed)
    }

    private func refresh(force: Bool) {
        if demo {
            if fans.isEmpty { fans = [sample]; target = 1100; installation = .installed; checkingInstallation = false }
            return
        }
        guard !busy else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastRead) < 2.5 { return }
        lastRead = now
        if force {
            DispatchQueue.global(qos: .utility).async {
                let status = FanService.installation()
                DispatchQueue.main.async { installation = status; checkingInstallation = false }
            }
        }
        FanControl.shared.readSnapshot { result in
            guard !busy else { return }
            switch result {
            case .success(let readings):
                fans = readings
                readError = nil
                if !touched, let first = readings.first {
                    target = Double(first.targetRPM > 0 ? first.targetRPM : first.currentRPM)
                }
            case .failure(let error):
                if fans.isEmpty { readError = error.localizedDescription }
            }
        }
    }

    private func enableService() {
        guard !busy, !demo, !checkingInstallation else { return }
        busy = true
        message = nil
        FanService.enable { result in
            switch result {
            case .success:
                FanService.perform("ping") { handshake in
                    DispatchQueue.main.async {
                        busy = false
                        installation = FanService.installation()
                        switch handshake {
                        case .success:
                            serviceUnavailable = false
                            message = L("风扇服务已启用，调速无需重复授权", "Fan service enabled; no further approval needed for speed changes")
                            messageIsError = false
                        case .failure(let error):
                            serviceUnavailable = true
                            message = error.localizedDescription
                            messageIsError = true
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    busy = false
                    installation = FanService.installation()
                    message = error.localizedDescription
                    messageIsError = true
                    serviceUnavailable = true
                }
            }
        }
    }

    private func apply(_ rpm: Int) {
        guard !busy, !demo, !fans.isEmpty else { return }
        thermostat.yieldToManual()
        busy = true
        message = nil
        FanControl.shared.applyManual(rpm: rpm) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let readings):
                    fans = readings
                    serviceUnavailable = false
                    message = L("已设为手动 \(rpm) RPM", "Manual \(rpm) RPM applied")
                    messageIsError = false
                case .failure(let error):
                    message = error.localizedDescription
                    messageIsError = true
                    if case .serviceUnavailable = error { serviceUnavailable = true }
                }
                lastRead = Date()
            }
        }
    }

    private func restore() {
        guard !busy, !demo else { return }
        thermostat.yieldToManual()
        busy = true
        message = nil
        FanControl.shared.restoreAutomatic { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let readings):
                    fans = readings
                    serviceUnavailable = false
                    touched = false
                    message = L("已恢复自动", "Automatic control restored")
                    messageIsError = false
                case .failure(let error):
                    message = error.localizedDescription
                    messageIsError = true
                    if case .serviceUnavailable = error { serviceUnavailable = true }
                }
                lastRead = Date()
            }
        }
    }
}
