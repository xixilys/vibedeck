import Foundation

/// All hardware, service, preferences and sampling effects are injected; never touches live cooling.
enum FanThermostatSelfTest {
    private static let fan = FanReading(index: 0, currentRPM: 3000, targetRPM: 3000,
                                        minimumRPM: 1000, maximumRPM: 4900, isManual: true)

    private final class Clock {
        final class Job {
            let at: Double
            let action: () -> Void
            var cancelled = false
            init(at: Double, action: @escaping () -> Void) { self.at = at; self.action = action }
        }
        var now: TimeInterval = 1_000
        var jobs: [Job] = []
        var liveJobs: Int { jobs.filter { !$0.cancelled }.count }
        func schedule(_ delay: Double, _ action: @escaping () -> Void) -> () -> Void {
            let job = Job(at: now + delay, action: action)
            jobs.append(job)
            return { job.cancelled = true }
        }
        func advance(_ seconds: Double) {
            let destination = now + seconds
            var count = 0
            while let job = jobs.filter({ !$0.cancelled && $0.at <= destination }).min(by: { $0.at < $1.at }) {
                count += 1
                precondition(count < 100, "Watchdog/retry must not spin")
                now = job.at
                job.cancelled = true
                job.action()
                FanThermostatSelfTest.drain()
            }
            now = destination
            jobs.removeAll { $0.cancelled }
            FanThermostatSelfTest.drain()
        }
    }

    private final class Fixture {
        let clock = Clock()
        var wallOffset = 0.0
        var reads: [FanThermostat.Dependencies.ReadingReply] = []
        var manuals: [(Int, FanThermostat.Dependencies.CommandReply)] = []
        var autos: [FanThermostat.Dependencies.CommandReply] = []
        var savedEnabled: [Bool] = []
        lazy var thermostat = FanThermostat(enabled: true, target: 75, dependencies: .init(
            read: { self.reads.append($0) }, manual: { self.manuals.append(($0, $1)) },
            automatic: { self.autos.append($0) }, active: { _ in },
            saveEnabled: { self.savedEnabled.append($0) }, saveTarget: { _ in },
            now: { self.clock.now + self.wallOffset }, uptime: { self.clock.now },
            schedule: { self.clock.schedule($0, $1) }))
        func tick(_ temperature: Double? = 75, mean: Double? = 62, age: Double = 0) {
            var sample = SystemSample()
            sample.at = clock.now + wallOffset - age
            sample.cpuTempMax = temperature
            sample.cpuTemp = mean
            thermostat.tick(sample)
            clock.advance(5)
        }
        func connect() {
            tick()
            reads.removeFirst()(.success([fan]))
            FanThermostatSelfTest.drain()
            tick()
        }
        func acknowledgeManual() {
            manuals.removeFirst().1(.success(()))
            FanThermostatSelfTest.drain()
        }
        func acknowledgeAuto() {
            autos.removeFirst()(.success(()))
            FanThermostatSelfTest.drain()
        }
    }

    private static func drain() {
        let until = Date().addingTimeInterval(0.015)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    }

    private static func eventually(_ predicate: () -> Bool) {
        let until = Date().addingTimeInterval(2)
        while !predicate(), Date() < until { drain() }
        precondition(predicate(), "Fan thermostat async test timed out")
    }

    static func run() {
        // Physical-time normal-control rates match at 2, 5 and 10 seconds.
        for interval in [2.0, 5.0, 10.0] {
            var heating = FanThermostatController()
            heating.observe(85, at: 0)
            heating.connect(current: 1000, low: 1000, high: 4900, target: 75)
            for t in stride(from: interval, through: 10.0, by: interval) {
                heating.observe(85, at: t)
                _ = heating.advance(raw: 85, at: t, target: 75, low: 1000, high: 4900)
            }
            precondition(abs(heating.output! - 1300) < 0.001)
            precondition(heating.integral == 0, "A slew-limited rise must not wind up I")

            var cooling = FanThermostatController()
            cooling.observe(65, at: 0)
            cooling.connect(current: 4900, low: 1000, high: 4900, target: 75)
            for t in stride(from: interval, through: 10.0, by: interval) {
                cooling.observe(65, at: t)
                _ = cooling.advance(raw: 65, at: t, target: 75, low: 1000, high: 4900)
            }
            precondition(abs(cooling.output! - 4780) < 0.001)

        }
        var equilibrium = FanThermostatController()
        equilibrium.observe(75, at: 0)
        equilibrium.connect(current: 4900, low: 1000, high: 4900, target: 75)
        for t in stride(from: 5.0, through: 120.0, by: 5.0) {
            equilibrium.observe(75, at: t)
            _ = equilibrium.advance(raw: 75, at: t, target: 75, low: 1000, high: 4900)
        }
        precondition(equilibrium.output == 4900, "Do not force lower RPM when holding the target needs cooling")
        for t in stride(from: 125.0, through: 600.0, by: 5.0) {
            equilibrium.observe(65, at: t)
            _ = equilibrium.advance(raw: 65, at: t, target: 75, low: 1000, high: 4900)
        }
        precondition(equilibrium.output == 1000, "Cooling must eventually return to the floor")

        var slightlyCool = FanThermostatController()
        slightlyCool.observe(75, at: 0)
        slightlyCool.connect(current: 4900, low: 1000, high: 4900, target: 75)
        for t in stride(from: 5.0, through: 600.0, by: 5.0) {
            slightlyCool.observe(74.75, at: t)
            _ = slightlyCool.advance(raw: 74.75, at: t, target: 75, low: 1000, high: 4900)
        }
        precondition(slightlyCool.output! < 4700, "Small negative error must unwind I, not latch full speed in a 0.5° dead band")

        var targetChange = FanThermostatController()
        targetChange.observe(75, at: 0)
        targetChange.connect(current: 3000, low: 1000, high: 4900, target: 75)
        targetChange.observe(75, at: 5)
        precondition(targetChange.advance(raw: 75, at: 5, target: 85, low: 1000, high: 4900)! < 3000)
        targetChange.observe(75, at: 10)
        let before = targetChange.output!
        precondition(targetChange.advance(raw: 75, at: 10, target: 65, low: 1000, high: 4900)! >= before)

        checkModeFences()
        checkRecovery()
        checkWatchdog()
        checkEmergency()
        checkQuit()
        runQuitDeliveryRace()
        checkReadCoalescing()
        checkCommandOrder()
        checkBlockedTelemetry()
        print("Fan thermostat self-tests passed (PI replay, monotonic watchdog/retry, native emergency hold, async quit, read coalescing, ACK ordering independent of blocked telemetry)")
    }

    private static func checkModeFences() {
        let staleRead = Fixture()
        staleRead.tick()
        let oldRead = staleRead.reads.removeFirst()
        staleRead.thermostat.setEnabled(false)
        staleRead.thermostat.setEnabled(true)
        oldRead(.success([fan]))
        drain()
        precondition(staleRead.thermostat.commandedRPM == nil)
        staleRead.tick()
        precondition(staleRead.reads.count == 1 && staleRead.thermostat.lastTemperature == 75)

        let staleAuto = Fixture()
        staleAuto.thermostat.setEnabled(false)
        let oldAuto = staleAuto.autos.removeFirst()
        staleAuto.thermostat.setEnabled(true)
        oldAuto(.failure(.serviceUnavailable))
        drain()
        precondition(staleAuto.thermostat.lastError == nil)
        staleAuto.tick()
        precondition(staleAuto.reads.count == 1)

        let staleWrite = Fixture()
        staleWrite.connect()
        let oldWrite = staleWrite.manuals.removeFirst().1
        staleWrite.thermostat.yieldToManual()
        oldWrite(.failure(.serviceUnavailable))
        drain()
        staleWrite.clock.advance(120)
        precondition(staleWrite.autos.isEmpty && !staleWrite.thermostat.requiresHandback)

        let hardwareLimit = Fixture()
        hardwareLimit.tick()
        let unusual = FanReading(index: 0, currentRPM: 4873, targetRPM: 4873,
                                 minimumRPM: 1037, maximumRPM: 4873, isManual: true)
        hardwareLimit.reads.removeFirst()(.success([unusual]))
        drain()
        hardwareLimit.tick()
        precondition(hardwareLimit.manuals.first?.0 == 4873)
    }

    private static func checkRecovery() {
        let meanOnly = Fixture()
        meanOnly.tick(nil, mean: 62)
        precondition(meanOnly.autos.count == 1 && meanOnly.reads.isEmpty, "Mean temperature must not masquerade as hottest-core input")

        let native = Fixture()
        native.tick()
        let automaticFan = FanReading(index: 0, currentRPM: 1800, targetRPM: 4900,
                                      minimumRPM: 1000, maximumRPM: 4900, isManual: false)
        native.reads.removeFirst()(.success([automaticFan])); drain()
        native.tick()
        precondition(native.manuals.first?.0 == 1800, "Take over actual automatic RPM, not a stale manual target register")

        let missing = Fixture()
        missing.connect(); missing.acknowledgeManual()
        missing.tick(nil, mean: nil)
        precondition(missing.autos.count == 1)
        missing.acknowledgeAuto()
        missing.tick(nil, mean: nil)
        precondition(missing.autos.isEmpty && missing.thermostat.phase == .systemAutomatic)
        missing.tick()
        precondition(missing.reads.isEmpty, "Do not bounce directly from Auto back to Manual")
        for _ in 0..<6 { missing.tick() }
        precondition(missing.reads.count == 1, "Recover only after 30 seconds of fresh observations")

        for invalid in [Double.nan, Double.infinity, -1, 126] {
            let fixture = Fixture()
            fixture.tick(invalid)
            precondition(fixture.autos.count == 1 && fixture.reads.isEmpty)
        }
        let stale = Fixture()
        stale.tick(age: 31)
        precondition(stale.autos.count == 1 && stale.reads.isEmpty)

        let disabled = Fixture()
        disabled.thermostat.setEnabled(false)
        disabled.autos.removeFirst()(.failure(.serviceUnavailable))
        drain()
        precondition(disabled.thermostat.lastError != nil && disabled.thermostat.requiresHandback)
        disabled.clock.advance(59)
        precondition(disabled.autos.isEmpty)
        disabled.clock.advance(1)
        precondition(disabled.autos.count == 1, "Disabled Auto recovery must retry without a sample")
        disabled.acknowledgeAuto()
        precondition(!disabled.thermostat.requiresHandback && disabled.clock.liveJobs == 0)

        let manualWins = Fixture()
        manualWins.thermostat.setEnabled(false)
        manualWins.autos.removeFirst()(.failure(.serviceUnavailable))
        drain()
        let oldJobs = manualWins.clock.jobs
        manualWins.thermostat.yieldToManual()
        manualWins.clock.advance(120)
        oldJobs.forEach { $0.action() } // Cancellation plus epoch, not cancellation alone, protects takeover.
        drain()
        precondition(manualWins.autos.isEmpty && !manualWins.thermostat.requiresHandback)
    }

    private static func checkWatchdog() {
        let noMoreSamples = Fixture()
        _ = noMoreSamples.thermostat
        noMoreSamples.wallOffset = -3600 // Wall-clock changes do not postpone liveness.
        noMoreSamples.clock.advance(30)
        precondition(noMoreSamples.autos.count == 1)
        noMoreSamples.acknowledgeAuto()
        noMoreSamples.clock.advance(120)
        precondition(noMoreSamples.autos.isEmpty && noMoreSamples.clock.liveJobs == 0)

        let stalledRange = Fixture()
        stalledRange.tick()
        let lateRead = stalledRange.reads.removeFirst()
        stalledRange.tick() // Fresh temperature continues, but the separate range deadline expires.
        precondition(stalledRange.autos.count == 1)
        lateRead(.success([fan]))
        drain()
        precondition(stalledRange.manuals.isEmpty && stalledRange.thermostat.commandedRPM == nil)

        let healthy = Fixture()
        healthy.connect(); healthy.acknowledgeManual()
        for _ in 0..<10 { healthy.tick() }
        precondition(healthy.autos.isEmpty, "Unchanged but fresh temperature still renews liveness")

        let timeout = Fixture()
        timeout.thermostat.setEnabled(false)
        let lateAuto = timeout.autos.removeFirst()
        timeout.clock.advance(10)
        precondition(timeout.thermostat.lastError != nil)
        lateAuto(.success(()))
        drain()
        precondition(timeout.thermostat.requiresHandback, "Late ACK after watchdog timeout must not change the newer recovery state")
        timeout.clock.advance(60)
        precondition(timeout.autos.count == 1)
    }

    private static func checkEmergency() {
        let hot = Fixture()
        hot.connect(); hot.acknowledgeManual()
        hot.tick(105)
        precondition(hot.autos.count == 1 && hot.manuals.isEmpty, "Raw emergency bypasses the still-cool filter")
        hot.acknowledgeAuto()
        for _ in 0..<6 { hot.tick(105) }
        precondition(hot.autos.isEmpty && hot.reads.isEmpty, "Repeated hot samples remain on native Auto without command chatter")
        hot.tick(86) // Above the 85° recovery threshold for target75.
        precondition(hot.reads.isEmpty)
        var recovered = false
        for _ in 0..<24 {
            hot.tick(75)
            if !hot.reads.isEmpty { recovered = true; break }
        }
        precondition(recovered && hot.reads.count == 1 && hot.autos.isEmpty)
        precondition(hot.thermostat.target == 75)
    }

    private static func checkQuit() {
        let success = Fixture()
        success.connect()
        let lateManual = success.manuals.removeFirst().1
        var replies = 0
        success.thermostat.prepareForQuit { result in
            if case .success = result { replies += 1 } else { preconditionFailure("Healthy quit should finish") }
        }
        success.thermostat.prepareForQuit { _ in replies += 1 }
        precondition(replies == 0 && success.autos.count == 1, "Quit is asynchronous and coalesced")
        lateManual(.success(())); drain()
        success.tick()
        precondition(success.thermostat.commandedRPM == nil && success.manuals.isEmpty)
        success.acknowledgeAuto()
        precondition(replies == 2 && success.savedEnabled.isEmpty && success.thermostat.enabled)
        success.clock.advance(120)
        precondition(success.autos.isEmpty && success.manuals.isEmpty)

        let failed = Fixture()
        var failedReplies = 0
        failed.thermostat.prepareForQuit { result in if case .failure = result { failedReplies += 1 } }
        failed.autos.removeFirst()(.failure(.serviceUnavailable)); drain()
        precondition(failedReplies == 1 && failed.thermostat.lastError != nil && failed.thermostat.enabled)
        failed.clock.advance(60)
        precondition(failed.autos.count == 1, "Cancelled failed quit retains recovery in the running app")

        let cancelled = Fixture()
        var cancelledReplies = 0
        cancelled.thermostat.prepareForQuit { result in if case .failure = result { cancelledReplies += 1 } }
        let obsoleteAuto = cancelled.autos.removeFirst()
        cancelled.thermostat.cancelQuit(); drain()
        precondition(cancelledReplies == 1 && cancelled.autos.count == 1)
        obsoleteAuto(.success(())); drain()
        precondition(cancelled.thermostat.phase == .restoring)
        cancelled.acknowledgeAuto()

        let manual = Fixture()
        var superseded = 0
        manual.thermostat.prepareForQuit { result in if case .failure = result { superseded += 1 } }
        let obsolete = manual.autos.removeFirst()
        manual.thermostat.yieldToManual(); drain()
        obsolete(.success(())); drain()
        manual.clock.advance(120)
        precondition(superseded == 1 && !manual.thermostat.requiresHandback && manual.autos.isEmpty)

        let timedOut = Fixture()
        var timedOutReplies = 0
        timedOut.thermostat.prepareForQuit { result in if case .failure = result { timedOutReplies += 1 } }
        timedOut.clock.advance(10)
        precondition(timedOutReplies == 1 && timedOut.thermostat.lastError != nil)
    }

    /// Targeted entry also lets the independent reviewer rerun only the changed quit boundary.
    static func runQuitDeliveryRace() {
        for manualTakeover in [false, true] {
            let fixture = Fixture()
            var results: [String] = []
            fixture.thermostat.prepareForQuit { result in
                switch result {
                case .success: results.append("success")
                case .failure: results.append("cancelled")
                }
            }
            // ACK handling is already queued. This action runs after the ACK changes state
            // but before deliverQuit's queued callback can be consumed by AppDelegate.
            fixture.autos.removeFirst()(.success(()))
            DispatchQueue.main.async {
                if manualTakeover { fixture.thermostat.yieldToManual() }
                else { fixture.thermostat.cancelQuit() }
            }
            drain()
            precondition(results == ["cancelled"], "An obsolete queued success must not approve quit after ACK-gap cancellation/takeover")
            precondition(fixture.autos.isEmpty)
            precondition(manualTakeover ? !fixture.thermostat.requiresHandback : fixture.thermostat.enabled)
        }

        let duplicate = Fixture()
        var first = 0, duplicateResults: [String] = []
        duplicate.thermostat.prepareForQuit { result in if case .success = result { first += 1 } }
        duplicate.acknowledgeAuto()
        precondition(first == 1)
        // The already-acknowledged duplicate branch must obey the same delivery fence.
        duplicate.thermostat.prepareForQuit { result in
            if case .success = result { duplicateResults.append("success") }
            else { duplicateResults.append("cancelled") }
        }
        duplicate.thermostat.yieldToManual()
        drain()
        precondition(duplicateResults == ["cancelled"] && first == 1)

        let noHandback = Fixture()
        noHandback.thermostat.yieldToManual()
        var fastResults: [String] = []
        noHandback.thermostat.prepareForQuit { result in
            if case .success = result { fastResults.append("success") }
            else { fastResults.append("cancelled") }
        }
        noHandback.thermostat.setEnabled(true)
        drain()
        precondition(fastResults == ["cancelled"], "The no-handback fast path cannot approve a newly enabled cooling owner")
        print("Quit delivery-intent regression passed (ACK-gap cancel/manual, acknowledged duplicate, no-handback supersession)")
    }

    private static func checkReadCoalescing() {
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var replies = 0
        let control = FanControl(readHardware: {
            began.signal()
            _ = release.wait(timeout: .now() + 2)
            return .success([fan])
        }, perform: { _, _, _ in preconditionFailure("Read-only test attempted a service mutation") })
        precondition(control.readSnapshot { _ in replies += 1 })
        precondition(began.wait(timeout: .now() + 2) == .success)
        precondition(!control.readSnapshot { _ in replies += 1 })
        release.signal()
        eventually { replies == 2 }
    }

    private static func checkCommandOrder() {
        let began = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        var pending: ((Result<String, FanControlError>) -> Void)?
        var completions = 0
        let control = FanControl(readHardware: { .success([fan]) }, perform: { command, _, reply in
            lock.lock()
            events.append(command)
            if command == "manual" { pending = reply }
            lock.unlock()
            if command == "manual" { began.signal() } else { reply(.success("VG_FAN_OK")) }
        })
        control.applyManualCommand(rpm: 3500) { _ in lock.lock(); completions += 1; lock.unlock() }
        precondition(began.wait(timeout: .now() + 2) == .success)
        control.restoreAutomaticCommand { _ in lock.lock(); completions += 1; lock.unlock() }
        drain()
        lock.lock()
        precondition(events == ["manual"], "Auto must wait for the earlier write")
        let reply = pending
        lock.unlock()
        reply?(.success("VG_FAN_OK"))
        eventually { lock.lock(); defer { lock.unlock() }; return completions == 2 }
        lock.lock()
        precondition(events == ["manual", "auto"])
        lock.unlock()
    }
    private static func checkBlockedTelemetry() {
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = [], uiReplies = 0, autoAcknowledged = false
        let control = FanControl(readHardware: {
            began.signal()
            _ = release.wait(timeout: .now() + 2)
            return .success([fan])
        }, perform: { command, _, reply in
            lock.lock(); events.append(command); lock.unlock()
            reply(.success("VG_FAN_OK"))
        })
        control.applyManual(rpm: 3500) { _ in lock.lock(); uiReplies += 1; lock.unlock() }
        precondition(began.wait(timeout: .now() + 2) == .success)
        control.restoreAutomaticCommand { result in
            lock.lock(); if case .success = result { autoAcknowledged = true }; lock.unlock()
        }
        eventually { lock.lock(); defer { lock.unlock() }; return autoAcknowledged }
        lock.lock()
        precondition(events == ["manual", "auto"] && uiReplies == 0, "A blocked post-ACK telemetry read must not block Auto acknowledgement")
        lock.unlock()
        release.signal()
        eventually { lock.lock(); defer { lock.unlock() }; return uiReplies == 1 }
    }

}
