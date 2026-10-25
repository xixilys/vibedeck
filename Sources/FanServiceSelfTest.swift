import Foundation

/// Exercises service validation without installing a daemon or touching AppleSMC.
enum FanServiceSelfTest {
    static func run() {
        let hash = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        precondition(FanServiceConfiguration.requirement(codeHashes: [hash]) == "cdhash H\"\(hash)\"")
        precondition(FanServiceConfiguration.requirement(codeHashes: [hash.uppercased()]) == "cdhash H\"\(hash)\"")
        for hashes in [[], [""], [String(repeating: "a", count: 39)],
                       [String(repeating: "g", count: 40)], [hash, "\" or anchor apple"],
                       [String(repeating: "é", count: 40)]] {
            precondition(FanServiceConfiguration.requirement(codeHashes: hashes) == nil)
        }
        for (candidateDigest, hashes, uid) in [(digest, [hash], uid_t(0)),
                                               ("bad", [hash], uid_t(501)),
                                               (String(repeating: "g", count: 64), [hash], uid_t(501)),
                                               (digest, ["invalid"], uid_t(501))] {
            do {
                _ = try FanService.installerScript(helper: "/tmp/helper", digest: candidateDigest, hashes: hashes, uid: uid)
                preconditionFailure("Invalid service identity accepted")
            } catch FanControlError.invalidData { }
            catch { preconditionFailure("Unexpected identity error: \(error)") }
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vg-fan-selftest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("must-not-exist").path
            let paths = ["/tmp/helper with spaces", "/tmp/quote'\"helper", "/tmp/line\nbreak",
                         "/tmp/$(touch \(marker))", "/tmp/`touch \(marker)`", "/tmp/风扇🌀"]
            for path in paths {
                let script = try FanService.installerScript(helper: path, digest: digest, hashes: [hash], uid: 501)
                // Syntax check only: never execute the generated privileged installer.
                let syntax = try shell(arguments: ["-n"], input: script)
                precondition(syntax.code == 0, "Invalid installer syntax: \(syntax.output)")
                // Execute only printf and the quoted string to prove substitutions stay literal.
                let quoted = try shell(arguments: ["-c", "/usr/bin/printf '%s' \(FanService.shellQuote(path))"])
                precondition(quoted.code == 0 && quoted.output == path)
                precondition(!FileManager.default.fileExists(atPath: marker))
            }

            let fixture = directory.appendingPathComponent("digest-fixture")
            try Data("abc".utf8).write(to: fixture)
            let actualDigest = try FanServiceIdentity.digest(at: fixture)
            precondition(actualDigest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            do {
                _ = try FanServiceIdentity.codeHashes(at: fixture)
                preconditionFailure("Unsigned data accepted as a service executable")
            } catch { }
            precondition(!FanServiceIdentity.protectedFile(directory.path))
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            precondition(!FanServiceIdentity.protectedFile(link.path))
            if getuid() != 0 { precondition(!FanServiceIdentity.protectedFile(fixture.path)) }
        } catch { preconditionFailure("Fan service offline test failed: \(error)") }

        for output in ["User canceled. (-128)", "用户已取消。", "User canceled"] {
            guard case .failure(.authorizationCancelled) = FanService.authorizationResult(code: 1, output: output) else {
                preconditionFailure("Authorization cancellation reported success")
            }
        }
        for (code, output) in [(Int32(1), "VG_FAN_SERVICE_INSTALLED"), (Int32(1), "bootstrap failed"), (Int32(0), "")] {
            guard case .failure = FanService.authorizationResult(code: code, output: output) else {
                preconditionFailure("Failed/incomplete installation reported success")
            }
        }
        guard case .success = FanService.authorizationResult(code: 0, output: "VG_FAN_SERVICE_INSTALLED\n") else {
            preconditionFailure("Completed installation rejected")
        }
        for (command, rpm) in [("shell", 0), ("manual", -1), ("manual", 100_001)] {
            var completed = false
            FanService.perform(command, rpm: rpm) { result in
                guard case .failure(.invalidData) = result else { preconditionFailure("Invalid command accepted") }
                completed = true
            }
            precondition(completed)
        }

        // Simulate competing XPC reply, error, invalidation and timeout callbacks.
        for _ in 0..<32 {
            let lock = NSLock()
            var completions = 0
            let reply = FanServiceReply { _ in
                lock.lock()
                completions += 1
                lock.unlock()
            }
            DispatchQueue.concurrentPerform(iterations: 128) { index in
                reply.finish(index % 4 == 0 ? .success("VG_FAN_OK") : .failure(.writeDenied))
            }
            precondition(completions == 1, "Fan service completed more than once")
        }
    }

    private static func shell(arguments: [String], input: String = "") throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
