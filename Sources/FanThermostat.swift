import Foundation
import Combine

/// Pure hottest-core PI controller. Gains and slew are expressed in seconds, not sampling ticks.
/// Integral is retained at equilibrium: a CPU at its target may still need substantial cooling.
struct FanThermostatController {
    private(set) var temperature: Double?
    private(set) var output: Double?
    private(set) var integral = 0.0
    private var recent: [Double] = []
    private var previousAt: TimeInterval?
    private var adjustedAt: TimeInterval?

    static let rampUp = 30.0
    static let rampDown = 12.0
    private let kp = 60.0
    private let ki = 2.0

    mutating func observe(_ raw: Double, at: TimeInterval) {
        guard previousAt.map({ at > $0 }) ?? true else { return }
        let dt = previousAt.map { min(10, at - $0) } ?? 0
        previousAt = at
        recent = Array((recent + [raw]).suffix(3))
        let median = recent.sorted()[recent.count / 2]
        let alpha = 1 - exp(-dt / 10)
        temperature = temperature.map { $0 + alpha * (median - $0) } ?? median
    }

    mutating func connect(current: Double, low: Double, high: Double, target: Double) {
        output = max(low, min(high, current))
        // Match the existing actuator rather than resetting an already-hot machine toward the floor.
        integral = max(0, min(high - low, output! - low - kp * ((temperature ?? target) - target)))
        adjustedAt = previousAt
    }

    mutating func disconnect() {
        output = nil
        integral = 0
        adjustedAt = nil
    }

    mutating func advance(raw: Double, at: TimeInterval, target: Double, low: Double, high: Double) -> Double? {
        guard let temperature, let current = output else { return nil }
        let dt = max(0, min(10, at - (adjustedAt ?? at)))
        adjustedAt = at
        let error = temperature - target
        let up = Self.rampUp * dt
        let down = Self.rampDown * dt
        let proposedIntegral = max(0, min(high - low, integral + ki * error * dt))
        let proposed = low + kp * error + proposedIntegral
        // Track the achievable actuator output, so saturation and slew cannot wind up I.
        // Partial integration matters: freezing a -100 RPM correction behind a -60 RPM ramp
        // would otherwise prevent any cooling adjustment once the proportional term settles.
        let achievable = max(max(low, current - down), min(min(high, current + up), proposed))
        integral = max(0, min(high - low, proposedIntegral + achievable - proposed))
        let desired = max(low, min(high, low + kp * error + integral))
        let next = max(low, min(high, current + max(-down, min(up, desired - current))))
        output = next
        return next
    }
}

/// Main-queue state and service recovery around the pure controller. All side effects are injectable.
final class FanThermostat: ObservableObject {
    static let shared = FanThermostat()
    static let enabledKey = "vg.fan.thermostat"
    static let targetKey = "vg.fan.thermostatTarget"

    struct Dependencies {
        typealias ReadingReply = (Result<[FanReading], FanControlError>) -> Void
        typealias CommandReply = (Result<Void, FanControlError>) -> Void
        typealias Cancel = () -> Void
        var read: (@escaping ReadingReply) -> Void
        var manual: (Int, @escaping CommandReply) -> Void
        var automatic: (@escaping CommandReply) -> Void
        var active: (Bool) -> Void
        var saveEnabled: (Bool) -> Void
        var saveTarget: (Double) -> Void
        var now: () -> TimeInterval
        var uptime: () -> TimeInterval
        var schedule: (TimeInterval, @escaping () -> Void) -> Cancel
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var target: Double
    @Published private(set) var commandedRPM: Int?
    @Published private(set) var lastTemperature: Double?
    @Published private(set) var lastError: String?
    @Published private(set) var rawTemperature: Double?
    @Published private(set) var phase: Phase = .waiting

    enum Phase {
        case waiting, reading, rampingUp, holding, rampingDown, restoring, retrying, systemAutomatic
        var label: String {
            switch self {
            case .waiting: return L("等待温度", "Waiting for temperature")
            case .reading: return L("读取风扇", "Reading fans")
            case .rampingUp: return L("升速", "Ramping up")
            case .holding: return L("保持", "Holding")
            case .rampingDown: return L("降速", "Ramping down")
            case .restoring: return L("恢复系统自动", "Restoring Auto")
            case .retrying: return L("等待重试", "Retry pending")
            case .systemAutomatic: return L("系统自动", "System auto")
            }
        }
    }

    /// Includes recovery after disabling. Explicit fixed-RPM takeover releases this ownership.
    var requiresHandback: Bool { enabled || needsAutomatic || quitting }

    private let dependencies: Dependencies
    private var controller = FanThermostatController()
    private var range: (low: Double, high: Double)?
    private var generation = 0
    private var inFlight = false
    private var operationDeadline: TimeInterval?
    private var lastReceipt: TimeInterval = 0
    private var lastSampleAt: TimeInterval?
    private var watchdog: Dependencies.Cancel?
    private var retry: Dependencies.Cancel?
    private var retryAfter: TimeInterval = 0
    private var needsAutomatic = false
    private var usingAutomatic = false
    private var fallbackReason: String?
    private var emergencyLatched = false
    private var resumeNotBefore: TimeInterval = 0
    private var recoverySince: TimeInterval?
    private var quitting = false
    private var quitReplies: [Dependencies.CommandReply] = []

    private convenience init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.targetKey)
        // Offline renders and self-tests start SystemMonitor too; they must never run a second fan loop.
        let offline = CommandLine.arguments.contains("--render-panel") || CommandLine.arguments.contains("--selftest")
        self.init(enabled: !offline && defaults.bool(forKey: Self.enabledKey), target: (55...95).contains(stored) ? stored : 80,
                  dependencies: Dependencies(
                    read: { _ = FanControl.shared.readSnapshot(completion: $0) },
                    manual: { FanControl.shared.applyManualCommand(rpm: $0, completion: $1) },
                    automatic: { FanControl.shared.restoreAutomaticCommand(completion: $0) },
                    active: { SystemMonitor.shared.setThermostatActive($0) },
                    saveEnabled: { defaults.set($0, forKey: Self.enabledKey) },
                    saveTarget: { defaults.set($0, forKey: Self.targetKey) },
                    now: { Date().timeIntervalSince1970 },
                    uptime: { ProcessInfo.processInfo.systemUptime },
                    schedule: { delay, action in
                        let item = DispatchWorkItem(block: action)
                        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
                        return { item.cancel() }
                    }))
    }

    init(enabled: Bool, target: Double, dependencies: Dependencies) {
        self.enabled = enabled
        self.target = target
        self.dependencies = dependencies
        lastReceipt = dependencies.uptime()
        if enabled { armWatchdog() }
    }

    deinit { watchdog?(); retry?() }

    func setEnabled(_ on: Bool) {
        guard on != enabled || quitting else { return }
        abortQuit()
        enabled = on
        dependencies.saveEnabled(on)
        resetMode()
        dependencies.active(on)
        if on { armWatchdog() } else { requestAutomatic(reason: nil) }
    }

    func setTarget(_ celsius: Double) {
        guard celsius.isFinite else { return }
        target = max(55, min(95, celsius.rounded()))
        dependencies.saveTarget(target)
    }

    /// Explicit Manual/Restore Auto owns subsequent commands and cancels old retries/quit intent.
    func yieldToManual() {
        guard enabled || needsAutomatic || quitting else { return }
        abortQuit()
        enabled = false
        dependencies.saveEnabled(false)
        resetMode()
        dependencies.active(false)
    }

    private func invalidateAsync() {
        generation += 1
        watchdog?(); watchdog = nil
        retry?(); retry = nil
        inFlight = false
        operationDeadline = nil
    }

    private func resetMode() {
        invalidateAsync()
        controller = FanThermostatController()
        range = nil
        commandedRPM = nil
        lastTemperature = nil
        rawTemperature = nil
        phase = .waiting
        lastError = nil
        lastReceipt = dependencies.uptime()
        lastSampleAt = nil
        retryAfter = 0
        needsAutomatic = false
        usingAutomatic = false
        fallbackReason = nil
        emergencyLatched = false
        recoverySince = nil
        resumeNotBefore = 0
    }

    /// Monotonic liveness runs on main, independent of both native sampling and telemetry queues.
    private func armWatchdog() {
        watchdog?(); watchdog = nil
        guard !quitting else {
            if let deadline = operationDeadline { scheduleWatchdog(at: deadline) }
            return
        }
        var deadline = operationDeadline
        if enabled, !needsAutomatic {
            let sensorDeadline = lastReceipt + 30
            // Once safe Auto already owns cooling, no repeated wakeups are needed for absent input.
            if !usingAutomatic || sensorDeadline > dependencies.uptime() {
                deadline = deadline.map { min($0, sensorDeadline) } ?? sensorDeadline
            }
        }
        if let deadline { scheduleWatchdog(at: deadline) }
    }

    private func scheduleWatchdog(at deadline: TimeInterval) {
        let epoch = generation
        watchdog = dependencies.schedule(max(0, deadline - dependencies.uptime())) { [weak self] in
            guard let self, epoch == self.generation else { return }
            self.watchdog = nil
            let now = self.dependencies.uptime()
            if let operation = self.operationDeadline, self.inFlight, now >= operation {
                let error = FanControlError.commandFailed(L("风扇操作响应超时", "Fan operation timed out"))
                if self.needsAutomatic { self.automaticFailed(error) }
                else { self.requestAutomatic(reason: error.localizedDescription) }
            } else if self.enabled, !self.quitting, now - self.lastReceipt >= 30 {
                self.lastTemperature = nil
                self.rawTemperature = nil
                self.recoverySince = nil
                self.requestAutomatic(reason: L("CPU 温度已中断 30 秒", "No CPU temperature for 30 seconds"))
            } else { self.armWatchdog() }
        }
    }

    /// Called on main for each sample. A healthy unchanged temperature still renews liveness.
    func tick(_ sample: SystemSample) {
        guard enabled, !quitting else { return }
        let now = dependencies.now(), uptime = dependencies.uptime()
        guard let raw = sample.cpuTempMax, raw.isFinite, (0...125).contains(raw),
              sample.at.isFinite, now - sample.at >= -1, now - sample.at <= 30,
              lastSampleAt.map({ sample.at > $0 }) ?? true else {
            lastTemperature = nil
            rawTemperature = nil
            recoverySince = nil
            requestAutomatic(reason: L("CPU 温度不可用或已过期", "CPU temperature is unavailable or stale"))
            return
        }
        let receiptGap = uptime - lastReceipt
        lastReceipt = uptime
        lastSampleAt = sample.at
        rawTemperature = raw
        controller.observe(raw, at: sample.at)
        lastTemperature = controller.temperature
        armWatchdog()

        // Raw emergency bypasses smoothing. Native Auto, not an unmeasured RPM ramp, owns cooling.
        if raw >= 105 || (lastTemperature ?? raw) >= target + 15 {
            emergencyLatched = true
            recoverySince = nil
            requestAutomatic(reason: L("CPU 温度较高，交给系统自动", "High CPU temperature; handing cooling to macOS"))
            return
        }
        if needsAutomatic { sendAutomaticIfReady(); return }
        if usingAutomatic {
            let safe = !emergencyLatched || (raw <= min(100, target + 10) && (lastTemperature ?? raw) <= target + 10)
            if !safe || receiptGap > 15 { recoverySince = nil }
            if safe, recoverySince == nil { recoverySince = uptime }
            guard safe, uptime >= resumeNotBefore, let since = recoverySince, uptime - since >= 30 else { return }
            usingAutomatic = false
            emergencyLatched = false
            recoverySince = nil
            fallbackReason = nil
            range = nil
            controller.disconnect()
        }
        guard !inFlight else { return }
        guard let range else { loadRange(); return }
        let previous = controller.output
        guard let next = controller.advance(raw: raw, at: sample.at, target: target, low: range.low, high: range.high) else { return }
        phase = previous.map { next > $0 + 0.5 ? .rampingUp : next < $0 - 0.5 ? .rampingDown : .holding } ?? .holding
        let rpm = next <= range.low ? Int(range.low) : next >= range.high ? Int(range.high)
            : max(Int(range.low), min(Int(range.high), Int((next / 50).rounded() * 50)))
        if let sent = commandedRPM {
            if sent == rpm { return }
            if abs(sent - rpm) < 100, rpm != Int(range.low), rpm != Int(range.high) { return }
        }
        send(rpm)
    }

    private func send(_ rpm: Int) {
        let epoch = generation
        inFlight = true
        operationDeadline = dependencies.uptime() + 10
        armWatchdog()
        dependencies.manual(rpm) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, epoch == self.generation, self.enabled, !self.quitting, !self.needsAutomatic else { return }
                self.inFlight = false
                self.operationDeadline = nil
                switch result {
                case .success:
                    self.commandedRPM = rpm
                    self.lastError = nil
                    self.armWatchdog()
                case .failure(let error): self.requestAutomatic(reason: error.localizedDescription)
                }
            }
        }
    }

    private func loadRange() {
        phase = .reading
        let epoch = generation
        inFlight = true
        operationDeadline = dependencies.uptime() + 10
        armWatchdog()
        dependencies.read { [weak self] result in
            DispatchQueue.main.async {
                guard let self, epoch == self.generation, self.enabled, !self.quitting, !self.needsAutomatic else { return }
                self.inFlight = false
                self.operationDeadline = nil
                if case .success(let fans) = result,
                   !fans.isEmpty, fans.allSatisfy({ $0.minimumRPM >= 0 && $0.maximumRPM > $0.minimumRPM }),
                   let minimum = fans.map(\.minimumRPM).max(), let maximum = fans.map(\.maximumRPM).max(), maximum >= max(1000, minimum) {
                    let low = Double(max(1000, minimum)), high = Double(maximum)
                    self.range = (low, high)
                    // Automatic mode can retain a stale manual target register. Match the
                    // actual actuator on takeover, not that previous manual request.
                    let current = fans.map { Double($0.isManual && $0.targetRPM > 0 ? $0.targetRPM : $0.currentRPM) }.max() ?? low
                    self.controller.connect(current: current, low: low, high: high, target: self.target)
                    self.armWatchdog()
                } else {
                    self.requestAutomatic(reason: L("读不到有效的风扇范围", "Cannot read a valid fan range"))
                }
            }
        }
    }

    private func requestAutomatic(reason: String?) {
        if usingAutomatic {
            phase = .systemAutomatic
            if let reason { lastError = reason + L("；系统自动已确认，等待新鲜安全读数", "; system Auto acknowledged; waiting for fresh safe readings") }
            return
        }
        if !needsAutomatic {
            invalidateAsync()
            controller.disconnect()
            range = nil
            commandedRPM = nil
            needsAutomatic = true
            fallbackReason = reason
            retryAfter = 0
        }
        sendAutomaticIfReady()
    }

    private func sendAutomaticIfReady() {
        guard needsAutomatic, !inFlight, dependencies.uptime() >= retryAfter else { return }
        retry?(); retry = nil
        phase = .restoring
        lastError = (fallbackReason.map { $0 + L("；", "; ") } ?? "") + L("正在恢复系统自动…", "Restoring system automatic control…")
        let epoch = generation
        inFlight = true
        operationDeadline = dependencies.uptime() + 10
        armWatchdog()
        dependencies.automatic { [weak self] result in
            DispatchQueue.main.async {
                guard let self, epoch == self.generation, self.needsAutomatic, self.inFlight else { return }
                self.inFlight = false
                self.operationDeadline = nil
                switch result {
                case .success:
                    self.watchdog?(); self.watchdog = nil
                    self.needsAutomatic = false
                    self.usingAutomatic = true
                    self.resumeNotBefore = self.dependencies.uptime() + 30
                    self.recoverySince = nil
                    self.phase = .systemAutomatic
                    self.lastError = self.fallbackReason.map { $0 + L("；系统自动已确认，等待 30 秒新鲜安全读数", "; system Auto acknowledged; waiting for 30 seconds of fresh safe readings") }
                    if self.quitting { self.deliverQuit(.success(())) }
                    else { self.armWatchdog() }
                case .failure(let error): self.automaticFailed(error)
                }
            }
        }
    }

    private func automaticFailed(_ error: FanControlError) {
        invalidateAsync()
        phase = .retrying
        needsAutomatic = true
        lastError = L("恢复系统自动未确认：", "System automatic control not confirmed: ") + error.localizedDescription
        if quitting {
            quitting = false
            deliverQuit(.failure(error))
        }
        retryAfter = dependencies.uptime() + 60
        let epoch = generation
        retry = dependencies.schedule(60) { [weak self] in
            guard let self, epoch == self.generation, self.needsAutomatic, !self.quitting else { return }
            self.retry = nil
            self.sendAutomaticIfReady()
        }
    }

    /// Main-queue asynchronous termination barrier. Preferences and the target are unchanged.
    /// Success is native command acknowledgement; no local fan telemetry is required.
    func prepareForQuit(completion: @escaping Dependencies.CommandReply) {
        if quitting {
            quitReplies.append(completion)
            if !needsAutomatic { deliverQuit(.success(())) }
            return
        }
        guard requiresHandback else {
            let epoch = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, epoch == self.generation, !self.requiresHandback else {
                    completion(.failure(Self.cancelledQuitError))
                    return
                }
                completion(.success(()))
            }
            return
        }
        quitReplies.append(completion)
        quitting = true
        invalidateAsync()
        controller.disconnect()
        range = nil
        commandedRPM = nil
        needsAutomatic = true
        usingAutomatic = false
        fallbackReason = nil
        retryAfter = 0
        sendAutomaticIfReady()
    }

    /// User cancelled termination. If Auto is still uncertain, complete a new ordered handback
    /// before resuming Smart. Manual takeover instead calls yieldToManual and owns the next command.
    func cancelQuit() {
        guard quitting else { return }
        let acknowledged = usingAutomatic && !needsAutomatic
        abortQuit()
        resetMode()
        if acknowledged {
            usingAutomatic = true
            resumeNotBefore = dependencies.uptime() + 30
            phase = .systemAutomatic
            armWatchdog()
        } else {
            requestAutomatic(reason: L("退出已取消，先恢复系统自动", "Quit cancelled; restoring system Auto before resuming"))
        }
    }

    private func abortQuit() {
        guard quitting else { return }
        quitting = false
        deliverQuit(.failure(Self.cancelledQuitError))
    }

    private static var cancelledQuitError: FanControlError {
        .commandFailed(L("退出已取消或已切换风扇模式", "Quit cancelled or fan mode changed"))
    }

    private func deliverQuit(_ result: Result<Void, FanControlError>) {
        let replies = quitReplies
        quitReplies.removeAll()
        let epoch = generation
        DispatchQueue.main.async { [weak self] in
            for reply in replies {
                // Keep the intent fenced until each consumer actually receives success,
                // not merely until the Auto ACK is handled on main. A queued cancellation
                // or a previous consumer can supersede this quit before delivery.
                if case .success = result {
                    guard let self, epoch == self.generation, self.quitting,
                          self.usingAutomatic, !self.needsAutomatic else {
                        reply(.failure(Self.cancelledQuitError))
                        continue
                    }
                }
                reply(result)
            }
        }
    }
}
