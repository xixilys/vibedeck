import Foundation
import Security
import CryptoKit

/// Both ends pin exact code, including locally signed builds without a Team ID.
enum FanServiceIdentity {
    static func codeHashes(at url: URL) throws -> [String] {
        var hashes: [String] = []
        for architecture in [Int32(0x0100_000c), Int32(0x0100_0007)] {
            var code: SecStaticCode?
            let attributes = [kSecCodeAttributeArchitecture as String: NSNumber(value: architecture)] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess,
                  let code else { continue }
            guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
                throw FanControlError.commandFailed(L("应用签名验证失败，请重新构建", "Code signature validation failed; rebuild the app"))
            }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let dictionary = information as? [String: Any],
                  let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { continue }
            hashes.append(hash.map { String(format: "%02x", $0) }.joined())
        }
        hashes = Array(Set(hashes)).sorted()
        guard FanServiceConfiguration.requirement(codeHashes: hashes) != nil else {
            throw FanControlError.commandFailed(L("无法验证风扇服务的代码身份", "Cannot verify the fan service code identity"))
        }
        return hashes
    }

    static func digest(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func protectedFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_uid == 0 && info.st_mode & 0o022 == 0
    }
}

enum FanServiceInstallation: Equatable {
    case missing, needsUpdate, installed
}

/// A separate setup action is the only path that can request administrator access.
/// Sending manual/auto requests never installs, repairs, or reauthorizes anything.
enum FanService {
    static let helperName = "VibeDeckFanHelper"
    static let launchPlistPath = "/Library/LaunchDaemons/\(FanServiceConfiguration.serviceName).plist"
    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(helperName)") }
    private static let identity: Result<([String], [String], String), Error> = Result {
        guard let executable = Bundle.main.executableURL else { throw FanControlError.writeDenied }
        return (try FanServiceIdentity.codeHashes(at: executable),
                try FanServiceIdentity.codeHashes(at: helperURL),
                try FanServiceIdentity.digest(at: helperURL))
    }

    static func installation() -> FanServiceInstallation {
        guard FileManager.default.fileExists(atPath: FanServiceConfiguration.helperPath) else { return .missing }
        guard FanServiceIdentity.protectedFile(FanServiceConfiguration.helperPath),
              FanServiceIdentity.protectedFile(FanServiceConfiguration.manifestPath),
              FanServiceIdentity.protectedFile(launchPlistPath),
              case .success(let (clientHashes, _, digest)) = identity,
              let data = try? Data(contentsOf: URL(fileURLWithPath: FanServiceConfiguration.manifestPath)),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (manifest["ClientUID"] as? Int) == Int(getuid()),
              (manifest["ProtocolVersion"] as? Int) == FanServiceConfiguration.protocolVersion,
              (manifest["ClientCodeHashes"] as? [String]) == clientHashes,
              (try? FanServiceIdentity.digest(at: URL(fileURLWithPath: FanServiceConfiguration.helperPath))) == digest else {
            return .needsUpdate
        }
        return .installed
    }

    static func perform(_ command: String, rpm: Int = 0, completion: @escaping (Result<String, FanControlError>) -> Void) {
        guard (command == "manual" && (0...100_000).contains(rpm)) ||
                (["ping", "auto"].contains(command) && rpm == 0) else {
            completion(.failure(.invalidData("fan-command")))
            return
        }
        let hashes: [String]
        do { hashes = try identity.get().1 }
        catch { completion(.failure(.commandFailed(error.localizedDescription))); return }
        guard let requirement = FanServiceConfiguration.requirement(codeHashes: hashes) else {
            completion(.failure(.writeDenied)); return
        }
        let connection = NSXPCConnection(machServiceName: FanServiceConfiguration.serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VGFanServiceProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        let reply = FanServiceReply { result in
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            completion(result)
        }
        let unavailable = FanControlError.serviceUnavailable
        connection.invalidationHandler = { reply.finish(.failure(unavailable)) }
        connection.interruptionHandler = { reply.finish(.failure(unavailable)) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(unavailable)) }) as? VGFanServiceProtocol else {
            reply.finish(.failure(unavailable)); return
        }
        proxy.perform(command, rpm: rpm) { code, output in
            if code == 0, output.hasPrefix("VG_FAN_OK") {
                reply.finish(.success(output))
            } else {
                reply.finish(.failure(.commandFailed(output)))
            }
        }
        // Do not retry a timed-out write: it may already have reached the hardware.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            reply.finish(.failure(.commandFailed(L("风扇服务响应超时，请检查当前转速后重试", "Fan service timed out; check the current speed before retrying"))))
        }
    }

    static func enable(completion: @escaping (Result<String, FanControlError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (clientHashes, _, digest) = try identity.get()
                let script = try installerScript(helper: helperURL.path, digest: digest, hashes: clientHashes, uid: getuid())
                let prompt = L("VibeDeck 首次安装或更新风扇服务需要管理员权限，之后调速和恢复自动无需重复授权。",
                               "VibeDeck needs administrator access to install or update its fan service. Subsequent fan changes need no approval.")
                let appleScript = "on run argv\n do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)\nend run"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript, "--", script, prompt]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                completion(authorizationResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            } catch {
                completion(.failure(.commandFailed(error.localizedDescription)))
            }
        }
    }

    static func authorizationResult(code: Int32, output: String) -> Result<String, FanControlError> {
        if code != 0 {
            if output.contains("(-128)") || output.contains("User canceled") || output.contains("用户已取消") {
                return .failure(.authorizationCancelled)
            }
            return .failure(.commandFailed(output))
        }
        guard output.contains("VG_FAN_SERVICE_INSTALLED") else {
            return .failure(.commandFailed(L("风扇服务安装未完成", "Fan service installation did not complete")))
        }
        return .success(output)
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func installerScript(helper: String, digest: String, hashes: [String], uid: uid_t) throws -> String {
        guard uid > 0, FanServiceConfiguration.requirement(codeHashes: hashes) != nil,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw FanControlError.invalidData("service-identity")
        }
        let manifest: [String: Any] = ["ClientCodeHashes": hashes, "ClientUID": Int(uid),
                                       "ProtocolVersion": FanServiceConfiguration.protocolVersion]
        let plist: [String: Any] = ["Label": FanServiceConfiguration.serviceName,
                                    "ProgramArguments": [FanServiceConfiguration.helperPath],
                                    "MachServices": [FanServiceConfiguration.serviceName: true],
                                    "ProcessType": "Interactive"]
        let manifestData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // All executable tools and destinations are fixed. Copy first, then validate
        // inside a root-owned directory; never execute code from a writable app path.
        let preparation = """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        umask 077
        safe_dir() {
            [ ! -L "$1" ] && [ -d "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 1
            mode=$(/usr/bin/stat -f %Lp "$1")
            [ "$((0$mode & 0022))" = 0 ] || exit 1
        }
        safe_file() {
            if [ -e "$1" ] || [ -L "$1" ]; then
                [ ! -L "$1" ] && [ -f "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 1
                mode=$(/usr/bin/stat -f %Lp "$1")
                [ "$((0$mode & 0022))" = 0 ] || exit 1
            fi
        }
        safe_dir /Library
        safe_dir /Library/LaunchDaemons
        if [ ! -e /Library/PrivilegedHelperTools ] && [ ! -L /Library/PrivilegedHelperTools ]; then
            /bin/mkdir /Library/PrivilegedHelperTools
            /bin/chmod 755 /Library/PrivilegedHelperTools
        fi
        safe_dir /Library/PrivilegedHelperTools
        helper=\(shellQuote(FanServiceConfiguration.helperPath))
        manifest=\(shellQuote(FanServiceConfiguration.manifestPath))
        plist=\(shellQuote(launchPlistPath))
        safe_file "$helper"
        safe_file "$manifest"
        safe_file "$plist"
        safe_file /Library/PrivilegedHelperTools/.vibedeck-fan-install.lock
        """
        let transaction = """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        umask 077
        helper=\(shellQuote(FanServiceConfiguration.helperPath))
        manifest=\(shellQuote(FanServiceConfiguration.manifestPath))
        plist=\(shellQuote(launchPlistPath))
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.vibedeck-fan.XXXXXX)
        changing=0
        cleanup() {
            result=$?
            trap - EXIT
            if [ "$result" != 0 ] && [ "$changing" = 1 ]; then
                /bin/launchctl bootout system/\(FanServiceConfiguration.serviceName) 2>/dev/null || true
                restored=1
                for name in helper manifest plist; do
                    case "$name" in
                        helper) destination="$helper" ;;
                        manifest) destination="$manifest" ;;
                        plist) destination="$plist" ;;
                    esac
                    if [ -f "$stage/old-$name" ]; then
                        /bin/cp -p "$stage/old-$name" "$destination" || restored=0
                    else
                        /bin/rm -f "$destination" || restored=0
                    fi
                done
                if [ -f "$stage/old-plist" ]; then
                    /bin/launchctl bootstrap system "$plist" || restored=0
                fi
                if [ "$restored" = 0 ]; then
                    /bin/echo "Service recovery failed; backup retained at $stage" >&2
                    exit "$result"
                fi
            fi
            /bin/rm -rf "$stage"
            exit "$result"
        }
        trap cleanup EXIT
        /bin/cp -P \(shellQuote(helper)) "$stage/helper"
        [ ! -L "$stage/helper" ] && [ -f "$stage/helper" ] || exit 1
        actual=$(/usr/bin/shasum -a 256 "$stage/helper")
        [ "${actual%% *}" = \(shellQuote(digest.lowercased())) ] || exit 1
        /usr/bin/codesign --verify --strict --all-architectures "$stage/helper"
        /bin/echo \(shellQuote(manifestData.base64EncodedString())) | /usr/bin/base64 -D > "$stage/manifest"
        /bin/echo \(shellQuote(plistData.base64EncodedString())) | /usr/bin/base64 -D > "$stage/plist"
        /usr/sbin/chown root:wheel "$stage/helper" "$stage/manifest" "$stage/plist"
        /bin/chmod 755 "$stage/helper"
        /bin/chmod 644 "$stage/manifest" "$stage/plist"
        for name in helper manifest plist; do
            case "$name" in
                helper) original="$helper" ;;
                manifest) original="$manifest" ;;
                plist) original="$plist" ;;
            esac
            if [ -f "$original" ]; then /bin/cp -p "$original" "$stage/old-$name"; fi
        done
        changing=1
        if /bin/launchctl print system/\(FanServiceConfiguration.serviceName) >/dev/null 2>&1; then
            /bin/launchctl bootout system/\(FanServiceConfiguration.serviceName)
        fi
        if [ -f "$helper" ]; then "$helper" --restore-automatic; fi
        /bin/mv -f "$stage/helper" "$helper"
        /bin/mv -f "$stage/manifest" "$manifest"
        /bin/mv -f "$stage/plist" "$plist"
        /bin/launchctl bootstrap system "$plist"
        changing=0
        /bin/echo VG_FAN_SERVICE_INSTALLED
        """
        // Keep the lock inode: unlinking a lock file can permit a second installer
        // to lock a new inode while another process still holds the old one.
        return preparation + "\n/usr/bin/lockf -k -t 0 /Library/PrivilegedHelperTools/.vibedeck-fan-install.lock /bin/sh -c " + shellQuote(transaction)
    }
}

/// XPC may report interruption, invalidation, timeout and a reply concurrently.
final class FanServiceReply {
    private let lock = NSLock()
    private var completion: ((Result<String, FanControlError>) -> Void)?
    init(_ completion: @escaping (Result<String, FanControlError>) -> Void) { self.completion = completion }
    func finish(_ result: Result<String, FanControlError>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }
}
