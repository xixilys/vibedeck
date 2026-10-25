import Foundation
import Darwin
import CoreFoundation

struct FanHelperConfiguration {
    let clientUID: uid_t
    let requirement: String

    static func parse(_ data: Data) -> FanHelperConfiguration? {
        guard let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = manifest["ProtocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == FanServiceConfiguration.protocolVersion,
              version.doubleValue == Double(FanServiceConfiguration.protocolVersion),
              let uid = manifest["ClientUID"] as? NSNumber,
              CFGetTypeID(uid) != CFBooleanGetTypeID(),
              uid.doubleValue >= 1, uid.doubleValue <= Double(UInt32.max),
              uid.doubleValue == Double(uid.uint32Value),
              let hashes = manifest["ClientCodeHashes"] as? [String],
              let requirement = FanServiceConfiguration.requirement(codeHashes: hashes) else { return nil }
        return FanHelperConfiguration(clientUID: uid.uint32Value, requirement: requirement)
    }

    static func load() -> FanHelperConfiguration? {
        let path = FanServiceConfiguration.manifestPath
        var before = stat()
        guard lstat(path, &before) == 0, secureFile(before) else { return nil }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, secureFile(opened),
              before.st_dev == opened.st_dev, before.st_ino == opened.st_ino,
              let data = try? handle.readToEnd(), data.count <= 65_536 else { return nil }
        return parse(data)
    }

    private static func secureFile(_ file: stat) -> Bool {
        (file.st_mode & S_IFMT) == S_IFREG && file.st_uid == 0 &&
            (file.st_mode & 0o022) == 0 && file.st_size > 0 && file.st_size <= 65_536
    }
}

final class FanHelperService: NSObject, VGFanServiceProtocol {
    // One queue across all clients: AppleSMC's C bridge owns a global connection.
    private static let queue = DispatchQueue(label: FanServiceConfiguration.serviceName + ".hardware")
    private let setRPM: (Int) -> (Int32, String)
    private let automatic: () -> (Int32, String)

    init(setRPM: @escaping (Int) -> (Int32, String) = { FanHardware.set(rpm: $0) },
         automatic: @escaping () -> (Int32, String) = { FanHardware.restoreAutomatic() }) {
        self.setRPM = setRPM
        self.automatic = automatic
    }

    func perform(_ command: String, rpm: Int, withReply reply: @escaping (Int32, String) -> Void) {
        Self.queue.async {
            switch command {
            case "ping" where rpm == 0:
                reply(0, "VG_FAN_OK \(FanServiceConfiguration.protocolVersion)")
            case "manual" where (0...100_000).contains(rpm):
                let result = self.setRPM(rpm)
                reply(result.0, result.1)
            case "auto" where rpm == 0:
                let result = self.automatic()
                reply(result.0, result.1)
            default:
                reply(2, "VG_FAN_ERROR invalid-command")
            }
        }
    }
}

final class FanHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let configuration: FanHelperConfiguration
    private let service: FanHelperService

    init(configuration: FanHelperConfiguration, service: FanHelperService = FanHelperService()) {
        self.configuration = configuration
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == configuration.clientUID else { return false }
        // Foundation checks this requirement on every incoming message. A PID
        // lookup alone would permit an exec after the initial connection check.
        connection.setCodeSigningRequirement(configuration.requirement)
        connection.exportedInterface = NSXPCInterface(with: VGFanServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--selftest"] {
    FanHelperSelfTest.run()
    exit(0)
}
if CommandLine.arguments == [CommandLine.arguments[0], "--restore-automatic"], geteuid() == 0 {
    let result = FanHardware.restoreAutomatic()
    print(result.1)
    exit(result.0)
}
if CommandLine.arguments == [CommandLine.arguments[0], "--selftest-xpc"] {
    FanHelperSelfTest.runXPC()
    exit(0)
}
guard CommandLine.arguments.count == 1, geteuid() == 0,
      let configuration = FanHelperConfiguration.load() else {
    fputs("VibeDeck fan helper: invalid launch or configuration\n", stderr)
    exit(2)
}
let delegate = FanHelperListenerDelegate(configuration: configuration)
let listener = NSXPCListener(machServiceName: FanServiceConfiguration.serviceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
