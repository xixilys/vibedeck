import Foundation
import Security
import Darwin

private final class FakeFanHardware {
    var values = ["F0Mn": 1_000, "F0Mx": 5_000, "F0Tg": 2_000,
                  "F1Mn": 1_500, "F1Mx": 4_000, "F1Tg": 2_000]
    var missingMode: Int?
    var writes: [(String, Int)] = []
    var failWrite: ((String, Int) -> Bool)?
    var closes = 0

    var backend: FanHardwareBackend {
        FanHardwareBackend(open: { 0 }, close: { self.closes += 1 }, fanCount: { 2 },
            readRPM: { self.values[$0] }, modeKey: { self.missingMode == $0 ? nil : "F\($0)md" },
            writeByte: { self.write($0, Int($1)) }, writeRPM: { self.write($0, Int($1)) })
    }

    private func write(_ key: String, _ value: Int) -> Int32 {
        writes.append((key, value))
        return failWrite?(key, value) == true ? -7 : 0
    }
}

enum FanHelperSelfTest {
    static func run() {
        let hash = String(repeating: "a", count: 40)
        precondition(FanServiceConfiguration.requirement(codeHashes: [hash]) == "cdhash H\"\(hash)\"")
        for hashes in [[], [""], [String(repeating: "f", count: 39)], [hash + "\" or true"], [String(repeating: "z", count: 40)]] {
            precondition(FanServiceConfiguration.requirement(codeHashes: hashes) == nil)
        }
        precondition(FanServiceConfiguration.requirement(codeHashes: [hash, hash.uppercased()]) != nil)
        func manifest(_ uid: Any, version: Any = 1) -> Data {
            try! PropertyListSerialization.data(fromPropertyList: ["ClientUID": uid,
                "ProtocolVersion": version, "ClientCodeHashes": [hash]], format: .xml, options: 0)
        }
        precondition(FanHelperConfiguration.parse(manifest(501))?.clientUID == 501)
        for uid: Any in [0, -1, 1.5, true, "501", 4_294_967_296] {
            precondition(FanHelperConfiguration.parse(manifest(uid)) == nil)
        }
        precondition(FanHelperConfiguration.parse(manifest(501, version: true)) == nil)
        precondition(FanHelperConfiguration.parse(manifest(501, version: 2)) == nil)

        let clamped = FakeFanHardware()
        precondition(FanHardware.set(rpm: 99_000, backend: clamped.backend).0 == 0)
        precondition(clamped.writes.map { "\($0.0)=\($0.1)" } == ["F0md=1", "F0Tg=5000", "F1md=1", "F1Tg=4000"])
        precondition(clamped.closes == 1)
        let unreadable = FakeFanHardware()
        unreadable.values.removeValue(forKey: "F1Mx")
        precondition(FanHardware.set(rpm: 2_000, backend: unreadable.backend).0 != 0)
        precondition(unreadable.writes.isEmpty && unreadable.closes == 1)
        let badBounds = FakeFanHardware()
        badBounds.values["F1Mn"] = 5_000
        precondition(FanHardware.set(rpm: 2_000, backend: badBounds.backend).0 != 0 && badBounds.writes.isEmpty)
        let invalid = FakeFanHardware()
        precondition(FanHardware.set(rpm: -1, backend: invalid.backend).0 != 0 && invalid.writes.isEmpty)
        let partial = FakeFanHardware()
        partial.failWrite = { $0 == "F1Tg" && $1 != 0 }
        precondition(FanHardware.set(rpm: 2_000, backend: partial.backend).0 != 0)
        precondition(partial.writes.suffix(4).map { "\($0.0)=\($0.1)" } == ["F0md=0", "F0Tg=0", "F1md=0", "F1Tg=0"])
        let rollbackFailure = FakeFanHardware()
        rollbackFailure.failWrite = { key, value in key == "F1Tg" || (key == "F0md" && value == 0) }
        precondition(FanHardware.set(rpm: 2_000, backend: rollbackFailure.backend).1.contains("rollback-failed"))
        precondition(!rollbackFailure.writes.contains { $0.0 == "F0Tg" && $0.1 == 0 })
        let missingMode = FakeFanHardware()
        missingMode.missingMode = 0
        precondition(FanHardware.restoreAutomatic(backend: missingMode.backend).0 != 0)
        precondition(missingMode.writes.contains { $0.0 == "F1md" && $0.1 == 0 })
        let automatic = FakeFanHardware()
        precondition(FanHardware.restoreAutomatic(backend: automatic.backend).0 == 0)

        var manualCalls = 0
        var automaticCalls = 0
        let service = FanHelperService(setRPM: { value in manualCalls += 1; return (0, "manual=\(value)") },
                                       automatic: { automaticCalls += 1; return (0, "auto") })
        func request(_ command: String, _ rpm: Int) -> (Int32, String) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: (Int32, String) = (-1, "timeout")
            service.perform(command, rpm: rpm) { code, text in result = (code, text); semaphore.signal() }
            precondition(semaphore.wait(timeout: .now() + 5) == .success)
            return result
        }
        precondition(request("ping", 0).1 == "VG_FAN_OK 1")
        precondition(request("manual", 2_500).1 == "manual=2500")
        precondition(request("auto", 0).0 == 0)
        for (command, rpm) in [("manual", -1), ("manual", 100_001), ("auto", 1), ("ping", 1), ("shell", 0)] {
            precondition(request(command, rpm).0 != 0)
        }
        precondition(manualCalls == 1 && automaticCalls == 1)
        var active = 0
        var maximumActive = 0
        var completed = 0
        let serialService = FanHelperService(setRPM: { _ in
            active += 1
            maximumActive = max(maximumActive, active)
            Thread.sleep(forTimeInterval: 0.001)
            active -= 1
            completed += 1
            return (0, "VG_FAN_OK")
        })
        let group = DispatchGroup()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            group.enter()
            serialService.perform("manual", rpm: 2_000) { _, _ in group.leave() }
        }
        precondition(group.wait(timeout: .now() + 5) == .success)
        precondition(completed == 32 && maximumActive == 1)
        print("Fan helper self-test passed (offline; no SMC access)")
    }

    static func runXPC() {
        var code: SecCode?
        precondition(SecCodeCopySelf([], &code) == errSecSuccess)
        var staticCode: SecStaticCode?
        precondition(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess)
        var info: CFDictionary?
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
        guard let hashData = (info! as NSDictionary)[kSecCodeInfoUnique] as? Data else {
            fatalError("Sign the test helper with codesign before XPC self-test")
        }
        let hash = hashData.map { String(format: "%02x", $0) }.joined()
        func check(_ codeHash: String, expectAllowed: Bool, clientUID: uid_t = geteuid(), serverCodeHash: String? = nil) {
            let configuration = FanHelperConfiguration(clientUID: clientUID,
                requirement: FanServiceConfiguration.requirement(codeHashes: [codeHash])!)
            let delegate = FanHelperListenerDelegate(configuration: configuration,
                service: FanHelperService(setRPM: { _ in fatalError("XPC test must never write hardware") },
                    automatic: { fatalError("XPC test must never write hardware") }))
            let listener = NSXPCListener.anonymous()
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: VGFanServiceProtocol.self)
            connection.setCodeSigningRequirement(FanServiceConfiguration.requirement(codeHashes: [serverCodeHash ?? hash])!)
            connection.resume()
            defer { connection.invalidate() }
            let resultLock = NSLock()
            var response: String?
            func receive(_ value: String) {
                resultLock.lock()
                response = value
                resultLock.unlock()
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in receive("REJECTED") } as! VGFanServiceProtocol
            proxy.perform("ping", rpm: 0) { code, text in
                receive(code == 0 && text == "VG_FAN_OK 1" ? "ALLOWED" : "BAD-REPLY")
            }
            let deadline = Date().addingTimeInterval(5)
            var actual: String?
            while actual == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                resultLock.lock()
                actual = response
                resultLock.unlock()
            }
            precondition(actual == (expectAllowed ? "ALLOWED" : "REJECTED"), "Unexpected XPC response: " + (actual ?? "timeout"))
        }
        check(hash, expectAllowed: true)
        check(String(repeating: "0", count: 40), expectAllowed: false)
        check(hash, expectAllowed: false, clientUID: geteuid() == 501 ? 502 : 501)
        check(hash, expectAllowed: false, serverCodeHash: String(repeating: "0", count: 40))
        print("Fan helper XPC self-test passed (mutual signature checks; wrong client/server signature and UID rejected; no SMC access)")
    }

}
